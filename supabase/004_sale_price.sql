-- =====================================================================
-- 舅是好蝦：單品特價功能 ＋ 新定價（單包 $100、三入組 $260）＋ 家庭分享包下架 ＋ 商品說明更正
-- 在 003_promotions.sql 之後執行。可以重複執行。
--
-- 規則
--  - 商品可設「特價」（要低於原價），留空＝沒有特價
--  - 有特價的商品以特價計算，不再疊加全館折扣；沒特價的商品照全館折扣
--  - 免運門檻一樣以折扣後的商品金額判斷
-- =====================================================================

alter table shop.products add column if not exists sale_price integer
  check (sale_price is null or sale_price >= 0);

-- 家庭分享包下架（資料保留，之後可在後台重新上架）
update shop.products set active = false where id = 'family';

-- 商品說明改成符合事實（印尼進口原料、台灣手工油炸）；只改沒被修改過的預設文字
update shop.products set description = '經典原味蝦餅，小鍋現炸、酥脆不油膩，配茶、配啤酒都對味。'
 where id = 'original' and description like '最經典的鮮蝦原味%';

-- 2026-11-13 Jerry 定價：直接定價、不顯示原價。原味單包 $100、三入組 $260，不開全館折扣
-- （之後可在後台商品頁修改價格或特價、在促銷活動開關折扣）
update shop.products set price = 100, sale_price = null where id = 'original';
update shop.products set price = 260, sale_price = null where id = 'trio';
update shop.shop_settings set promo_enabled = false where id;

-- ---------- 下單（特價優先，其餘套全館折扣） ----------
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
    v_sub  := v_sub  + coalesce(pr.sale_price, round(pr.price * v_pct / 100.0)::integer) * v_qty;
  end loop;

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

  insert into shop.order_items(order_id, product_id, name, spec, list_price, unit_price, qty)
  select v_order, pr2.id, pr2.name, pr2.spec, pr2.price,
         coalesce(pr2.sale_price, round(pr2.price * v_pct / 100.0)::integer), (x->>'qty')::integer
    from jsonb_array_elements(v_items) x
    join shop.products pr2 on pr2.id = x->>'id';

  return jsonb_build_object('order_no', v_no, 'list_subtotal', v_list, 'discount', v_list - v_sub,
                            'promo_name', v_pname, 'subtotal', v_sub,
                            'shipping_fee', v_fee, 'total', v_total);
end $$;


-- ---------- 後台：新增／修改商品（加上特價） ----------
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
  exception when others then raise exception 'invalid_price'; end;
  if v_price is null or v_price not between 0 and 100000 then raise exception 'invalid_price'; end if;
  if v_sale is not null and (v_sale < 0 or v_sale >= v_price) then raise exception 'invalid_sale'; end if;
  if v_img is not null and v_img !~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/shop-products/' then
    raise exception 'invalid_image';
  end if;

  select * into old from shop.products where id = v_id;

  insert into shop.products(id, name, spec, price, sale_price, active, sort, description, tag, image_url, updated_at)
  values (v_id, v_name, v_spec, v_price, v_sale, coalesce((p->>'active')::boolean, true), v_sort,
          nullif(btrim(coalesce(p->>'description','')), ''), nullif(btrim(coalesce(p->>'tag','')), ''), v_img, now())
  on conflict (id) do update set
    name = excluded.name, spec = excluded.spec, price = excluded.price, sale_price = excluded.sale_price, active = excluded.active,
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
-- 權限沿用（create or replace 會保留原本的授權）
