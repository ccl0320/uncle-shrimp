-- =====================================================================
-- 舅是好蝦：安全補強（2026-11 安全檢查後）
-- 在 008_shipping.sql 之後執行。可以重複執行。
--
-- 修補內容
--  1) 防灌單：原本只限制「同一支手機每小時 5 筆」，換手機號碼就能無限下單，
--     幾秒內就能把每週 200 包的名額塞滿，讓真正的客人買不到。現在加上：
--       - 同一個連線來源（IP，只存雜湊、不存原始 IP）每小時／每天的下單上限
--       - 同一支手機每天的下單上限
--       - 同一支手機／同一個來源 24 小時內最多訂 60 包（三入組算 3 包）
--       - 全店每小時的下單總量上限（超過就暫停接單，防止大量灌單）
--     所有計數在同一把鎖內檢查，同時送出也無法繞過。
--  2) 修正：items 欄位不給時會建立一張「沒有商品、只收運費」的空訂單。
--  3) 姓名、地址去掉換行與控制字元，避免在 LINE 訂單訊息裡偽造「應付總額」等假資訊。
--  4) 店長後台：可以一鍵取消「同一來源」的所有待確認訂單，把被灌單佔掉的名額還回來。
--  5) admin_add_staff 只接受剛由 Edge Function 建立的新帳號（10 分鐘內），
--     不能把同一個 Supabase 專案裡其他網站（例如小島）的使用者拉進後台。
--
-- 上限預設值（可在 SQL Editor 調整 shop.shop_settings）：
--   max_orders_per_phone_per_hour 5（原本就有）、max_orders_per_phone_per_day 8、
--   max_orders_per_ip_per_hour 5、max_orders_per_ip_per_day 12、max_orders_per_hour 60、
--   max_packs_per_source_per_day 60
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'shop' and table_name = 'shipping_methods' and column_name = 'note') then
    raise exception '請先依序執行 002～008，再執行 009';
  end if;
end $$;

alter table shop.shop_settings add column if not exists max_orders_per_phone_per_day integer not null default 8
  check (max_orders_per_phone_per_day between 1 and 1000);
alter table shop.shop_settings add column if not exists max_orders_per_ip_per_hour   integer not null default 5
  check (max_orders_per_ip_per_hour between 1 and 1000);
alter table shop.shop_settings add column if not exists max_orders_per_ip_per_day    integer not null default 12
  check (max_orders_per_ip_per_day between 1 and 10000);
alter table shop.shop_settings add column if not exists max_orders_per_hour          integer not null default 60
  check (max_orders_per_hour between 1 and 100000);
alter table shop.shop_settings add column if not exists max_packs_per_source_per_day integer not null default 60
  check (max_packs_per_source_per_day between 1 and 100000);
-- IP 雜湊用的隨機鹽（只在資料庫內使用，不會傳到前端）
alter table shop.shop_settings add column if not exists ip_salt text;
update shop.shop_settings set ip_salt = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
 where id and ip_salt is null;

alter table shop.orders add column if not exists client_ip_hash text;
create index if not exists orders_ip_idx on shop.orders (client_ip_hash, created_at desc);

-- ---------- 取得下單者連線來源的雜湊（內部用） ----------
-- Supabase 前面是 Cloudflare：cf-connecting-ip 由 Cloudflare 填入，客戶端無法偽造。
create or replace function shop.client_ip_hash()
returns text
language plpgsql stable security definer set search_path = shop
as $$
declare h json; ip text; s text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then h := null; end;
  if h is null then return null; end if;
  ip := coalesce(nullif(btrim(h->>'cf-connecting-ip'), ''),
                 nullif(btrim(split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1)), ''),
                 nullif(btrim(h->>'x-real-ip'), ''));
  if ip is null then return null; end if;
  select ip_salt into s from shop.shop_settings where id;
  return encode(sha256(convert_to(coalesce(s, '') || '|' || ip, 'UTF8')), 'hex');
end $$;

-- ---------- 下單（加上防灌單、空訂單修正、文字清理） ----------
create or replace function shop.place_order(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare
  -- 姓名、地址：去掉換行與控制字元；備註：保留換行，去掉其他控制字元
  v_name   text := btrim(regexp_replace(coalesce(p->>'name',''), '[[:cntrl:]]+', ' ', 'g'));
  v_phone  text := regexp_replace(coalesce(p->>'phone',''), '[\s-]', '', 'g');
  v_ship   text := coalesce(p->>'ship','');
  v_addr   text := nullif(btrim(regexp_replace(coalesce(p->>'address',''), '[[:cntrl:]]+', ' ', 'g')), '');
  v_note   text := nullif(btrim(regexp_replace(coalesce(p->>'note',''), '[\x01-\x09\x0b-\x1f\x7f]+', ' ', 'g')), '');
  v_items  jsonb := p->'items';
  v_ip     text := shop.client_ip_hash();
  s        shop.shop_settings;
  v_fee    integer;
  v_list   integer := 0;
  v_sub    integer := 0;
  v_total  integer;
  v_free   integer;
  v_maxq   integer;
  v_cap    integer;
  v_packs  integer := 0;
  v_used   integer;
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
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) not between 1 and 20 then
    raise exception 'invalid_items';
  end if;

  select * into s from shop.shop_settings where id;
  v_free := coalesce(s.free_shipping_threshold, 1200);
  v_maxq := coalesce(s.max_qty_per_item, 10);
  v_cap  := s.weekly_pack_limit;

  select pay_percent, name into v_pct, v_pname from shop.promo_now();
  v_pct := coalesce(v_pct, 100);
  if v_pct >= 100 then v_pname := null; end if;

  -- 所有下單排隊檢查（同時送出也無法繞過上限）
  perform pg_advisory_xact_lock(hashtext('shop.place_order'));

  -- 防灌單：全店每小時總量、同一支手機、同一個連線來源
  if (select count(*) from shop.orders where created_at > now() - interval '1 hour')
       >= coalesce(s.max_orders_per_hour, 60) then
    raise exception 'too_many_orders';
  end if;
  if (select count(*) from shop.orders where phone = v_phone and created_at > now() - interval '1 hour')
       >= coalesce(s.max_orders_per_phone_per_hour, 5)
     or (select count(*) from shop.orders where phone = v_phone and created_at > now() - interval '1 day')
       >= coalesce(s.max_orders_per_phone_per_day, 8) then
    raise exception 'too_many_orders';
  end if;
  if v_ip is not null and (
       (select count(*) from shop.orders where client_ip_hash = v_ip and created_at > now() - interval '1 hour')
         >= coalesce(s.max_orders_per_ip_per_hour, 5)
       or (select count(*) from shop.orders where client_ip_hash = v_ip and created_at > now() - interval '1 day')
         >= coalesce(s.max_orders_per_ip_per_day, 12)) then
    raise exception 'too_many_orders';
  end if;

  for it in select * from jsonb_array_elements(v_items) loop
    if jsonb_typeof(it) <> 'object' then raise exception 'invalid_items'; end if;
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

  -- 同一支手機／同一個來源 24 小時內最多訂幾包（未取消的訂單），避免少數人一次吃光每週名額
  if (select coalesce(sum(oi.qty * coalesce(oi.packs, 1)), 0) from shop.orders o join shop.order_items oi on oi.order_id = o.id
       where o.phone = v_phone and o.status <> 'cancelled' and o.created_at > now() - interval '1 day') + v_packs
       > coalesce(s.max_packs_per_source_per_day, 60)
     or (v_ip is not null and
         (select coalesce(sum(oi.qty * coalesce(oi.packs, 1)), 0) from shop.orders o join shop.order_items oi on oi.order_id = o.id
           where o.client_ip_hash = v_ip and o.status <> 'cancelled' and o.created_at > now() - interval '1 day') + v_packs
         > coalesce(s.max_packs_per_source_per_day, 60)) then
    raise exception 'too_many_orders';
  end if;

  -- 每週接單包數上限（週一 00:00 台北時間起算）
  if v_cap is not null then
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
                          list_subtotal, discount, promo_name, subtotal, shipping_fee, total, client_ip_hash)
  values (v_no, v_name, v_phone, v_ship, v_addr, v_note,
          v_list, v_list - v_sub, v_pname, v_sub, v_fee, v_total, v_ip)
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

-- ---------- 後台：訂單明細（加上「同一來源的待確認訂單數」，不回傳 IP 雜湊本身） ----------
create or replace function shop.admin_get_order(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare r jsonb;
begin
  perform shop.require_admin();
  select to_jsonb(o) - 'pii_purged_at' - 'client_ip_hash' || jsonb_build_object(
           'pii_purged', o.pii_purged_at is not null,
           'ship_name', sm.name,
           'same_source_pending', case when o.client_ip_hash is null then 0 else (
              select count(*) from shop.orders x
               where x.client_ip_hash = o.client_ip_hash and x.status = 'pending'
                 and x.created_at > now() - interval '7 days') end,
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

-- ---------- 店長：取消同一來源 7 天內所有待確認訂單（處理灌單） ----------
create or replace function shop.admin_cancel_same_source(p_id uuid)
returns integer
language plpgsql volatile security definer set search_path = shop
as $$
declare v_ip text; n integer;
begin
  perform shop.require_admin(true);
  select client_ip_hash into v_ip from shop.orders where id = p_id;
  if v_ip is null then raise exception 'no_source'; end if;
  update shop.orders
     set status = 'cancelled',
         admin_note = left(coalesce(admin_note || E'\n', '') || '［疑似灌單，批次取消］', 1000),
         updated_at = now()
   where client_ip_hash = v_ip and status = 'pending' and created_at > now() - interval '7 days';
  get diagnostics n = row_count;
  perform shop.write_audit('cancel_same_source', p_id, jsonb_build_object('rows', n));
  return n;
end $$;

-- ---------- 店長：加入員工名單只接受剛建立的新帳號 ----------
create or replace function shop.admin_add_staff(p_user uuid, p_role text)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare v_email text; v_hash text; v_created timestamptz;
begin
  perform shop.require_admin(true);
  if p_role not in ('owner','staff') then raise exception 'invalid_role'; end if;
  if exists (select 1 from shop.admin_users where user_id = p_user) then raise exception 'staff_exists'; end if;
  select email, encrypted_password, created_at into v_email, v_hash, v_created from auth.users where id = p_user;
  if v_email is null then raise exception 'staff_not_found'; end if;
  if v_created is null or v_created < now() - interval '10 minutes' then raise exception 'staff_not_new'; end if;
  insert into shop.admin_users(user_id, email, role, active, must_change_password, initial_pw_hash, created_by)
  values (p_user, lower(v_email), p_role, true, true, v_hash, auth.uid());
  perform shop.write_audit('create_staff', null, jsonb_build_object('email', lower(v_email), 'role', p_role));
  return jsonb_build_object('user_id', p_user, 'email', lower(v_email), 'role', p_role);
end $$;

revoke execute on function shop.client_ip_hash() from public, anon, authenticated;
revoke execute on function shop.admin_cancel_same_source(uuid) from public, anon;
grant execute on function shop.admin_cancel_same_source(uuid) to authenticated;
-- place_order / admin_get_order / admin_add_staff 原本的授權保留

-- ---------- 檢查：shop schema 裡 anon 能執行的函式只能是這四個 ----------
do $$
declare bad text;
begin
  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'shop' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('place_order', 'current_promo', 'week_capacity', 'public_settings');
  if bad is not null then raise warning '注意：anon 可以執行這些函式，請檢查：%', bad; end if;
end $$;
