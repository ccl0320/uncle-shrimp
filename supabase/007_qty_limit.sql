-- =====================================================================
-- 舅是好蝦：接單上限
--  1) 每個品項一次最多訂 10 件
--  2) 每週最多接 200 包（三入組算 3 包），週一 00:00（台北時間）起算，已取消的訂單不計
-- 在 006_staff.sql 之後執行。可以重複執行。
-- 兩個上限都可以在後台「商品」分頁的「接單上限」由店長調整。
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'shop' and table_name = 'admin_users' and column_name = 'must_change_password') then
    raise exception '請先依序執行 002～006，再執行 007';
  end if;
end $$;

alter table shop.shop_settings add column if not exists max_qty_per_item  integer not null default 10
  check (max_qty_per_item between 1 and 99);
alter table shop.shop_settings add column if not exists weekly_pack_limit integer default 200
  check (weekly_pack_limit is null or weekly_pack_limit between 0 and 100000);
alter table shop.products      add column if not exists packs integer not null default 1 check (packs between 1 and 50);
alter table shop.order_items   add column if not exists packs integer;

-- 每件商品算幾包（三入組 3 包；之後可在後台商品頁修改）
update shop.products set packs = 3 where id = 'trio'  and packs = 1;
update shop.products set packs = 6 where id = 'gift'  and packs = 1;

-- ---------- 本週已接包數（內部用） ----------
create or replace function shop.week_start()
returns timestamptz
language sql stable set search_path = shop
as $$ select date_trunc('week', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei' $$;

create or replace function shop.week_packs_used()
returns integer
language sql stable security definer set search_path = shop
as $$
  select coalesce(sum(oi.qty * coalesce(oi.packs, p.packs, 1)), 0)::integer
    from shop.orders o
    join shop.order_items oi on oi.order_id = o.id
    left join shop.products p on p.id = oi.product_id
   where o.created_at >= shop.week_start()
     and o.status <> 'cancelled'
$$;

-- ---------- 前台：本週剩餘可訂包數（公開，只回傳數字） ----------
create or replace function shop.week_capacity()
returns jsonb
language sql stable security definer set search_path = shop
as $$
  select jsonb_build_object(
           'limit', s.weekly_pack_limit,
           'remaining', case when s.weekly_pack_limit is null then null
                             else greatest(s.weekly_pack_limit - shop.week_packs_used(), 0) end,
           'max_qty', s.max_qty_per_item,
           'week_start', shop.week_start())
    from shop.shop_settings s where s.id
$$;

-- ---------- 後台：讀取／設定接單上限（店長） ----------
create or replace function shop.admin_get_capacity()
returns jsonb
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin();
  return (select jsonb_build_object('weekly_pack_limit', s.weekly_pack_limit, 'max_qty_per_item', s.max_qty_per_item,
                                    'used', shop.week_packs_used(), 'week_start', shop.week_start())
            from shop.shop_settings s where s.id);
end $$;

create or replace function shop.admin_set_capacity(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare v_week integer; v_max integer; old shop.shop_settings;
begin
  perform shop.require_admin(true);
  begin
    v_week := nullif(p->>'weekly_pack_limit','')::integer;
    v_max  := (p->>'max_qty_per_item')::integer;
  exception when others then raise exception 'invalid_capacity'; end;
  if v_week is not null and v_week not between 0 and 100000 then raise exception 'invalid_capacity'; end if;
  if v_max is null or v_max not between 1 and 99 then raise exception 'invalid_capacity'; end if;
  select * into old from shop.shop_settings where id;
  update shop.shop_settings set weekly_pack_limit = v_week, max_qty_per_item = v_max where id;
  perform shop.write_audit('update_capacity', null, jsonb_build_object(
    'weekly_from', old.weekly_pack_limit, 'weekly', v_week, 'max_qty_from', old.max_qty_per_item, 'max_qty', v_max));
  return shop.admin_get_capacity();
end $$;

-- ---------- 下單（加上數量上限與每週包數上限） ----------
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
  v_maxq   integer;
  v_cap    integer;
  v_packs  integer := 0;
  v_used   integer;
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

  select free_shipping_threshold, max_orders_per_phone_per_hour, max_qty_per_item, weekly_pack_limit
    into v_free, v_limit, v_maxq, v_cap
    from shop.shop_settings where id;
  v_free := coalesce(v_free, 1200); v_limit := coalesce(v_limit, 5); v_maxq := coalesce(v_maxq, 10);

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
    if v_qty is null or v_qty not between 1 and v_maxq then raise exception 'invalid_qty'; end if;
    v_list := v_list + pr.price * v_qty;
    v_packs := v_packs + coalesce(pr.packs, 1) * v_qty;
    v_sub  := v_sub  + coalesce(pr.sale_price, round(pr.price * v_pct / 100.0)::integer) * v_qty;
  end loop;

  -- 每週接單包數上限（週一 00:00 台北時間起算；同時下單時排隊檢查，避免超賣）
  if v_cap is not null then
    perform pg_advisory_xact_lock(hashtext('shop.weekly_pack_limit'));
    v_used := shop.week_packs_used();
    if v_used + v_packs > v_cap then
      raise exception 'weekly_limit:%', greatest(v_cap - v_used, 0);
    end if;
  end if;

  if v_pname is null and v_sub < v_list then v_pname := '特價優惠'; end if;
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

  insert into shop.order_items(order_id, product_id, name, spec, list_price, unit_price, qty, packs)
  select v_order, pr2.id, pr2.name, pr2.spec, pr2.price,
         coalesce(pr2.sale_price, round(pr2.price * v_pct / 100.0)::integer), (x->>'qty')::integer,
         coalesce(pr2.packs, 1)
    from jsonb_array_elements(v_items) x
    join shop.products pr2 on pr2.id = x->>'id';

  return jsonb_build_object('order_no', v_no, 'list_subtotal', v_list, 'discount', v_list - v_sub,
                            'promo_name', v_pname, 'subtotal', v_sub,
                            'shipping_fee', v_fee, 'total', v_total);
end $$;

-- ---------- 後台：新增／修改商品（加上包數） ----------
create or replace function shop.admin_upsert_product(p jsonb)
returns shop.products
language plpgsql volatile security definer set search_path = shop
as $$
declare
  v_id    text := btrim(coalesce(p->>'id',''));
  v_name  text := btrim(coalesce(p->>'name',''));
  v_spec  text := btrim(coalesce(p->>'spec',''));
  v_price integer;
  v_sort  integer;
  v_sale  integer;
  v_packs integer;
  v_img   text := nullif(btrim(coalesce(p->>'image_url','')), '');
  old     shop.products;
  r       shop.products;
begin
  perform shop.require_admin(true);
  if v_id !~ '^[a-z0-9_-]{2,40}$' then raise exception 'invalid_id'; end if;
  if char_length(v_name) not between 1 and 40 then raise exception 'invalid_name'; end if;
  if char_length(v_spec) not between 1 and 40 then raise exception 'invalid_spec'; end if;
  begin
    v_price := (p->>'price')::integer;
    v_sort  := coalesce((p->>'sort')::integer, 0);
    v_sale  := nullif(p->>'sale_price','')::integer;
    v_packs := coalesce(nullif(p->>'packs','')::integer, 1);
  exception when others then raise exception 'invalid_price'; end;
  if v_price is null or v_price not between 0 and 100000 then raise exception 'invalid_price'; end if;
  if v_packs not between 1 and 50 then raise exception 'invalid_packs'; end if;
  if v_sale is not null and (v_sale < 0 or v_sale >= v_price) then raise exception 'invalid_sale'; end if;
  if v_img is not null and v_img !~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/shop-products/' then
    raise exception 'invalid_image';
  end if;

  select * into old from shop.products where id = v_id;

  insert into shop.products(id, name, spec, price, sale_price, packs, active, sort, description, tag, image_url, updated_at)
  values (v_id, v_name, v_spec, v_price, v_sale, v_packs, coalesce((p->>'active')::boolean, true), v_sort,
          nullif(btrim(coalesce(p->>'description','')), ''), nullif(btrim(coalesce(p->>'tag','')), ''), v_img, now())
  on conflict (id) do update set
    name = excluded.name, spec = excluded.spec, price = excluded.price, sale_price = excluded.sale_price, packs = excluded.packs, active = excluded.active,
    sort = excluded.sort, description = excluded.description, tag = excluded.tag,
    image_url = excluded.image_url, updated_at = now()
  returning * into r;

  perform shop.write_audit(case when old.id is null then 'create_product' else 'update_product' end, null,
    jsonb_build_object('product', v_id, 'name', v_name,
                       'price_from', old.price, 'price_to', v_price,
                       'sale_from', old.sale_price, 'sale_to', v_sale,
                       'active', r.active, 'image_changed', old.image_url is distinct from v_img));
  return r;
end $$;

revoke execute on function shop.week_start(), shop.week_packs_used() from public, anon, authenticated;
revoke execute on function shop.week_capacity(), shop.admin_get_capacity(), shop.admin_set_capacity(jsonb) from public;
grant execute on function shop.week_capacity() to anon, authenticated;
grant execute on function shop.admin_get_capacity(), shop.admin_set_capacity(jsonb) to authenticated;
-- place_order / admin_upsert_product 原本的授權保留
