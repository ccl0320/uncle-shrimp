-- =====================================================================
-- 舅是好蝦：促銷活動（例：新開張試行全館 7 折）＋ 禮盒先下架
-- 在 002_products_admin.sql 之後執行。可以重複執行。
--
-- 規則
--  - 折扣由資料庫在下單時計算，前端改價無效
--  - 每件商品單價 = 原價 × 折數%（四捨五入到整數元）
--  - 免運門檻以「折扣後」的商品金額判斷
--  - 活動只在「開啟」且在起訖時間內才生效，過期自動失效
--  - 只有店長（已通過兩步驟驗證）可以修改活動，修改會寫入操作紀錄
-- =====================================================================

alter table shop.shop_settings add column if not exists promo_enabled     boolean not null default false;
alter table shop.shop_settings add column if not exists promo_name        text check (promo_name is null or char_length(promo_name) <= 30);
alter table shop.shop_settings add column if not exists promo_pay_percent integer not null default 70 check (promo_pay_percent between 1 and 100);
alter table shop.shop_settings add column if not exists promo_start       timestamptz;
alter table shop.shop_settings add column if not exists promo_end         timestamptz;

alter table shop.orders      add column if not exists list_subtotal integer;
alter table shop.orders      add column if not exists discount      integer not null default 0;
alter table shop.orders      add column if not exists promo_name    text;
alter table shop.order_items add column if not exists list_price    integer;

-- 禮盒先下架（資料保留，之後可在後台重新上架）
update shop.products set active = false where id = 'gift';

-- ---------- 目前生效的活動（內部用） ----------
create or replace function shop.promo_now(out pay_percent integer, out name text, out end_at timestamptz)
language sql stable security definer set search_path = shop
as $$
  select s.promo_pay_percent, coalesce(nullif(s.promo_name,''), '限時優惠'), s.promo_end
    from shop.shop_settings s
   where s.id and s.promo_enabled and s.promo_pay_percent < 100
     and (s.promo_start is null or now() >= s.promo_start)
     and (s.promo_end   is null or now() <  s.promo_end)
$$;

-- ---------- 前台讀取活動（公開） ----------
create or replace function shop.current_promo()
returns jsonb
language sql stable security definer set search_path = shop
as $$
  select coalesce((select jsonb_build_object('active', true, 'name', name, 'pay_percent', pay_percent, 'end_at', end_at)
                     from shop.promo_now() where pay_percent is not null),
                  '{"active": false}'::jsonb)
$$;

-- ---------- 下單（加入折扣） ----------
create or replace function shop.place_order(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare
  v_name   text := btrim(coalesce(p->>'name',''));
  v_phone  text := regexp_replace(coalesce(p->>'phone',''), '[\s-]', '', 'g');
  v_ship   text := coalesce(p->>'ship','');
  v_addr   text := nullif(btrim(coalesce(p->>'address','')), '');
  v_note   text := nullif(btrim(coalesce(p->>'note','')), '');
  v_items  jsonb := p->'items';
  v_fee    integer;
  v_list   integer := 0;
  v_sub    integer := 0;
  v_total  integer;
  v_free   integer;
  v_limit  integer;
  v_recent integer;
  v_order  uuid;
  v_no     text;
  v_pct    integer;
  v_pname  text;
  it       jsonb;
  pr       shop.products%rowtype;
  v_qty    integer;
  v_seen   text[] := '{}';
begin
  if char_length(v_name) not between 1 and 50 then raise exception 'invalid_name'; end if;
  if v_phone !~ '^09[0-9]{8}$' then raise exception 'invalid_phone'; end if;
  select fee into v_fee from shop.shipping_methods where id = v_ship and active;
  if v_fee is null then raise exception 'invalid_ship'; end if;
  if v_ship <> 'pickup' and (v_addr is null or char_length(v_addr) > 200) then raise exception 'invalid_address'; end if;
  if v_ship = 'pickup' then v_addr := null; end if;
  if v_note is not null and char_length(v_note) > 500 then raise exception 'invalid_note'; end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) not between 1 and 20 then
    raise exception 'invalid_items';
  end if;

  select free_shipping_threshold, max_orders_per_phone_per_hour into v_free, v_limit
    from shop.shop_settings where id;
  v_free := coalesce(v_free, 1200); v_limit := coalesce(v_limit, 5);

  select pay_percent, name into v_pct, v_pname from shop.promo_now();
  v_pct := coalesce(v_pct, 100);
  if v_pct >= 100 then v_pname := null; end if;

  select count(*) into v_recent from shop.orders
   where phone = v_phone and created_at > now() - interval '1 hour';
  if v_recent >= v_limit then raise exception 'too_many_orders'; end if;

  for it in select * from jsonb_array_elements(v_items) loop
    select * into pr from shop.products where id = it->>'id' and active;
    if not found then raise exception 'invalid_product'; end if;
    if pr.id = any(v_seen) then raise exception 'duplicate_product'; end if;
    v_seen := v_seen || pr.id;
    begin
      v_qty := (it->>'qty')::integer;
    exception when others then raise exception 'invalid_qty'; end;
    if v_qty is null or v_qty not between 1 and 99 then raise exception 'invalid_qty'; end if;
    v_list := v_list + pr.price * v_qty;
    v_sub  := v_sub  + round(pr.price * v_pct / 100.0)::integer * v_qty;
  end loop;

  if v_sub >= v_free then v_fee := 0; end if;
  v_total := v_sub + v_fee;

  for i in 1..10 loop
    v_no := 'USC' || to_char(now() at time zone 'Asia/Taipei', 'YYMMDD') || '-'
            || upper(substr(md5(gen_random_uuid()::text), 1, 5));
    exit when not exists (select 1 from shop.orders where order_no = v_no);
  end loop;

  insert into shop.orders(order_no, customer_name, phone, ship_method, address, note,
                          list_subtotal, discount, promo_name, subtotal, shipping_fee, total)
  values (v_no, v_name, v_phone, v_ship, v_addr, v_note,
          v_list, v_list - v_sub, v_pname, v_sub, v_fee, v_total)
  returning id into v_order;

  insert into shop.order_items(order_id, product_id, name, spec, list_price, unit_price, qty)
  select v_order, pr2.id, pr2.name, pr2.spec, pr2.price,
         round(pr2.price * v_pct / 100.0)::integer, (x->>'qty')::integer
    from jsonb_array_elements(v_items) x
    join shop.products pr2 on pr2.id = x->>'id';

  return jsonb_build_object('order_no', v_no, 'list_subtotal', v_list, 'discount', v_list - v_sub,
                            'promo_name', v_pname, 'subtotal', v_sub,
                            'shipping_fee', v_fee, 'total', v_total);
end $$;

-- ---------- 後台：訂單明細（加上原價） ----------
create or replace function shop.admin_get_order(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare r jsonb;
begin
  perform shop.require_admin();
  select to_jsonb(o) - 'pii_purged_at' || jsonb_build_object(
           'pii_purged', o.pii_purged_at is not null,
           'ship_name', sm.name,
           'items', coalesce((select jsonb_agg(jsonb_build_object(
                        'name', oi.name, 'spec', oi.spec, 'list_price', oi.list_price,
                        'unit_price', oi.unit_price, 'qty', oi.qty)
                        order by oi.id) from shop.order_items oi where oi.order_id = o.id), '[]'::jsonb))
    into r
    from shop.orders o join shop.shipping_methods sm on sm.id = o.ship_method
   where o.id = p_id;
  if r is null then raise exception 'not_found'; end if;
  perform shop.write_audit('view_order', p_id, null);
  return r;
end $$;

-- ---------- 後台：讀取／設定活動（店長） ----------
create or replace function shop.admin_get_promo()
returns jsonb
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin(true);
  return (select jsonb_build_object('enabled', promo_enabled, 'name', promo_name, 'pay_percent', promo_pay_percent,
                                    'start_at', promo_start, 'end_at', promo_end,
                                    'free_shipping_threshold', free_shipping_threshold,
                                    'live', shop.current_promo())
            from shop.shop_settings where id);
end $$;

create or replace function shop.admin_set_promo(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare
  v_pct   integer;
  v_start timestamptz;
  v_end   timestamptz;
  v_name  text := nullif(btrim(coalesce(p->>'name','')), '');
  old     shop.shop_settings;
begin
  perform shop.require_admin(true);
  begin
    v_pct   := (p->>'pay_percent')::integer;
    v_start := nullif(p->>'start_at','')::timestamptz;
    v_end   := nullif(p->>'end_at','')::timestamptz;
  exception when others then raise exception 'invalid_promo'; end;
  if v_pct is null or v_pct not between 1 and 100 then raise exception 'invalid_percent'; end if;
  if v_start is not null and v_end is not null and v_end <= v_start then raise exception 'invalid_dates'; end if;
  if v_name is not null and char_length(v_name) > 30 then raise exception 'invalid_promo_name'; end if;

  select * into old from shop.shop_settings where id;
  update shop.shop_settings
     set promo_enabled = coalesce((p->>'enabled')::boolean, false),
         promo_name = v_name, promo_pay_percent = v_pct,
         promo_start = v_start, promo_end = v_end
   where id;
  perform shop.write_audit('update_promo', null, jsonb_build_object(
    'enabled', coalesce((p->>'enabled')::boolean, false), 'name', v_name,
    'pay_percent_from', old.promo_pay_percent, 'pay_percent', v_pct,
    'start_at', v_start, 'end_at', v_end));
  return shop.admin_get_promo();
end $$;

revoke execute on function shop.promo_now() from public, anon, authenticated;
revoke execute on function shop.current_promo(), shop.admin_get_promo(), shop.admin_set_promo(jsonb) from public;
grant execute on function shop.current_promo() to anon, authenticated;
grant execute on function shop.admin_get_promo(), shop.admin_set_promo(jsonb) to authenticated;
-- place_order / admin_get_order 已在 schema.sql 授權，重新建立後權限保留
