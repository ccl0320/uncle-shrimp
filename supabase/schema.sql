-- =====================================================================
-- 舅是好蝦 訂單後台資料庫（Supabase / PostgreSQL，schema: shop）
-- 在 Supabase 專案的 SQL Editor 貼上整份執行一次即可。
--
-- 安全設計重點
--  1. 所有資料表開啟 Row Level Security，且收回 anon / authenticated 的直接存取權。
--  2. 顧客（未登入）只能呼叫 place_order() 下單；價格與運費由資料庫計算，前端改價無效。
--  3. 管理員只能透過 admin_* 函式讀寫，函式內檢查：
--       a. 帳號在 admin_users 名單內
--       b. 已完成兩步驟驗證（JWT aal = aal2）
--  4. 列表只顯示遮罩後的個資；查看完整個資、修改訂單都會寫入 audit_log。
--  5. 已完成／取消超過保存期限的訂單，可用 purge_old_pii() 清除個資。
-- =====================================================================

-- 所有物件放在獨立的 shop schema，不會碰到同一個專案裡其他網站（例如 public.island_docs）的資料。
-- 執行後請到 Project Settings → API → Exposed schemas 加入 shop。
create schema if not exists shop;
revoke all on schema shop from public;
grant usage on schema shop to anon, authenticated;

-- ---------- 商品 ----------
create table if not exists shop.products (
  id          text primary key,
  name        text not null,
  spec        text not null,
  price       integer not null check (price >= 0),
  active      boolean not null default true,
  sort        integer not null default 0,
  updated_at  timestamptz not null default now()
);

-- ---------- 取貨方式與運費 ----------
create table if not exists shop.shipping_methods (
  id      text primary key,
  name    text not null,
  fee     integer not null check (fee >= 0),
  active  boolean not null default true
);

create table if not exists shop.shop_settings (
  id                       boolean primary key default true check (id),  -- 只允許一列
  free_shipping_threshold  integer not null default 1200,
  max_orders_per_phone_per_hour integer not null default 5
);

-- ---------- 管理員名單 ----------
-- 帳號本身由 Supabase Auth 管理（密碼雜湊、重設、MFA）。
-- 只有列在這張表的帳號才能進後台。
create table if not exists shop.admin_users (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  role        text not null default 'staff' check (role in ('owner','staff')),
  created_at  timestamptz not null default now()
);

-- ---------- 訂單 ----------
do $$ begin
  create type shop.order_status as enum ('pending','confirmed','shipped','completed','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists shop.orders (
  id             uuid primary key default gen_random_uuid(),
  order_no       text not null unique,
  status         shop.order_status not null default 'pending',
  customer_name  text check (customer_name is null or char_length(customer_name) between 1 and 50),
  phone          text check (phone is null or phone ~ '^09[0-9]{8}$'),
  ship_method    text not null references shop.shipping_methods(id),
  address        text check (address is null or char_length(address) <= 200),
  pay_method     text not null default 'cod' check (pay_method in ('cod')),
  note           text check (note is null or char_length(note) <= 500),
  subtotal       integer not null,
  shipping_fee   integer not null,
  total          integer not null,
  admin_note     text check (admin_note is null or char_length(admin_note) <= 1000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  pii_purged_at  timestamptz
);
create index if not exists orders_created_idx on shop.orders (created_at desc);
create index if not exists orders_status_idx  on shop.orders (status);
create index if not exists orders_phone_idx   on shop.orders (phone);

create table if not exists shop.order_items (
  id          bigserial primary key,
  order_id    uuid not null references shop.orders(id) on delete cascade,
  product_id  text not null references shop.products(id),
  name        text not null,
  spec        text not null,
  unit_price  integer not null,
  qty         integer not null check (qty between 1 and 99)
);
create index if not exists order_items_order_idx on shop.order_items (order_id);

-- ---------- 稽核紀錄 ----------
create table if not exists shop.audit_log (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  actor     uuid,
  actor_email text,
  action    text not null,
  order_id  uuid,
  detail    jsonb
);
create index if not exists audit_log_at_idx on shop.audit_log (at desc);

-- ---------- 開啟 RLS，並收回直接存取 ----------
alter table shop.products          enable row level security;
alter table shop.shipping_methods  enable row level security;
alter table shop.shop_settings     enable row level security;
alter table shop.admin_users       enable row level security;
alter table shop.orders            enable row level security;
alter table shop.order_items       enable row level security;
alter table shop.audit_log         enable row level security;

revoke all on shop.products, shop.shipping_methods, shop.shop_settings,
              shop.admin_users, shop.orders, shop.order_items, shop.audit_log
  from anon, authenticated;
revoke all on all sequences in schema shop from anon, authenticated;

-- 顧客可以讀取上架商品與取貨方式（公開資訊）
grant select on shop.products, shop.shipping_methods to anon, authenticated;
drop policy if exists products_public_read on shop.products;
create policy products_public_read on shop.products for select to anon, authenticated using (active);
drop policy if exists shipping_public_read on shop.shipping_methods;
create policy shipping_public_read on shop.shipping_methods for select to anon, authenticated using (active);
-- 其他資料表沒有任何 policy = 預設全部拒絕

-- =====================================================================
-- 權限檢查
-- =====================================================================
create or replace function shop.current_admin_role()
returns text
language sql stable security definer set search_path = shop
as $$
  select a.role
    from shop.admin_users a
   where a.user_id = auth.uid()
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

create or replace function shop.require_admin(p_owner_only boolean default false)
returns text
language plpgsql stable security definer set search_path = shop
as $$
declare r text;
begin
  r := shop.current_admin_role();
  if r is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_owner_only and r <> 'owner' then
    raise exception 'owner_only' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function shop.mask_name(n text) returns text
language sql immutable as $$
  select case when n is null then null
              when char_length(n) <= 1 then n
              when char_length(n) = 2 then left(n,1) || '○'
              else left(n,1) || repeat('○', char_length(n)-2) || right(n,1) end
$$;

create or replace function shop.mask_phone(p text) returns text
language sql immutable as $$
  select case when p is null then null else left(p,4) || '***' || right(p,3) end
$$;

create or replace function shop.write_audit(p_action text, p_order uuid, p_detail jsonb)
returns void
language sql security definer set search_path = shop
as $$
  insert into shop.audit_log(actor, actor_email, action, order_id, detail)
  values (auth.uid(), auth.jwt() ->> 'email', p_action, p_order, p_detail);
$$;

-- =====================================================================
-- 顧客下單（未登入可呼叫）
-- p 範例：
-- {"name":"王小明","phone":"0912345678","ship":"home","address":"台北市…",
--  "note":"","items":[{"id":"original","qty":2}]}
-- =====================================================================
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
  v_sub    integer := 0;
  v_total  integer;
  v_free   integer;
  v_limit  integer;
  v_recent integer;
  v_order  uuid;
  v_no     text;
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

  -- 簡易防灌單：同一支手機一小時內的訂單數上限
  select count(*) into v_recent from shop.orders
   where phone = v_phone and created_at > now() - interval '1 hour';
  if v_recent >= v_limit then raise exception 'too_many_orders'; end if;

  -- 驗證品項並計價（以資料庫價格為準）
  for it in select * from jsonb_array_elements(v_items) loop
    select * into pr from shop.products where id = it->>'id' and active;
    if not found then raise exception 'invalid_product'; end if;
    if pr.id = any(v_seen) then raise exception 'duplicate_product'; end if;
    v_seen := v_seen || pr.id;
    begin
      v_qty := (it->>'qty')::integer;
    exception when others then raise exception 'invalid_qty'; end;
    if v_qty is null or v_qty not between 1 and 99 then raise exception 'invalid_qty'; end if;
    v_sub := v_sub + pr.price * v_qty;
  end loop;

  if v_sub >= v_free then v_fee := 0; end if;
  v_total := v_sub + v_fee;

  -- 產生訂單編號（重複時重試）
  for i in 1..10 loop
    v_no := 'USC' || to_char(now() at time zone 'Asia/Taipei', 'YYMMDD') || '-'
            || upper(substr(md5(gen_random_uuid()::text), 1, 5));
    exit when not exists (select 1 from shop.orders where order_no = v_no);
  end loop;

  insert into shop.orders(order_no, customer_name, phone, ship_method, address, note,
                            subtotal, shipping_fee, total)
  values (v_no, v_name, v_phone, v_ship, v_addr, v_note, v_sub, v_fee, v_total)
  returning id into v_order;

  insert into shop.order_items(order_id, product_id, name, spec, unit_price, qty)
  select v_order, pr2.id, pr2.name, pr2.spec, pr2.price, (x->>'qty')::integer
    from jsonb_array_elements(v_items) x
    join shop.products pr2 on pr2.id = x->>'id';

  return jsonb_build_object('order_no', v_no, 'subtotal', v_sub,
                            'shipping_fee', v_fee, 'total', v_total);
end $$;

-- =====================================================================
-- 後台函式（需登入＋兩步驟驗證＋在管理員名單）
-- =====================================================================

-- 訂單列表：個資遮罩
create or replace function shop.admin_list_orders(
  p_status text default null, p_search text default null,
  p_limit integer default 50, p_offset integer default 0)
returns table (
  id uuid, order_no text, status shop.order_status, created_at timestamptz,
  customer_name_masked text, phone_masked text, ship_method text,
  total integer, item_summary text, total_count bigint)
language plpgsql stable security definer set search_path = shop
as $$
declare s text := nullif(btrim(coalesce(p_search,'')), '');
begin
  perform shop.require_admin();
  return query
  select o.id, o.order_no, o.status, o.created_at,
         shop.mask_name(o.customer_name), shop.mask_phone(o.phone), o.ship_method,
         o.total,
         (select string_agg(oi.name || '×' || oi.qty, '、' order by oi.id)
            from shop.order_items oi where oi.order_id = o.id),
         count(*) over ()
    from shop.orders o
   where (p_status is null or o.status::text = p_status)
     and (s is null or o.order_no ilike '%' || s || '%' or o.phone = regexp_replace(s, '[\s-]', '', 'g'))
   order by o.created_at desc
   limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0);
end $$;

-- 查看單筆完整資料（會記錄誰在何時看了個資）
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
                        'name', oi.name, 'spec', oi.spec, 'unit_price', oi.unit_price, 'qty', oi.qty)
                        order by oi.id) from shop.order_items oi where oi.order_id = o.id), '[]'::jsonb))
    into r
    from shop.orders o join shop.shipping_methods sm on sm.id = o.ship_method
   where o.id = p_id;
  if r is null then raise exception 'not_found'; end if;
  perform shop.write_audit('view_order', p_id, null);
  return r;
end $$;

-- 更新狀態／內部備註
create or replace function shop.admin_update_order(
  p_id uuid, p_status text default null, p_admin_note text default null)
returns void
language plpgsql volatile security definer set search_path = shop
as $$
declare old_status shop.order_status;
begin
  perform shop.require_admin();
  select status into old_status from shop.orders where id = p_id for update;
  if old_status is null then raise exception 'not_found'; end if;
  if p_admin_note is not null and char_length(p_admin_note) > 1000 then raise exception 'invalid_note'; end if;
  update shop.orders
     set status = coalesce(p_status::shop.order_status, status),
         admin_note = coalesce(p_admin_note, admin_note),
         updated_at = now()
   where id = p_id;
  perform shop.write_audit('update_order', p_id,
    jsonb_build_object('from', old_status, 'to', coalesce(p_status, old_status::text),
                       'note_changed', p_admin_note is not null));
end $$;

-- 稽核紀錄（只有 owner 能看）
create or replace function shop.admin_audit_log(p_limit integer default 100)
returns setof shop.audit_log
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin(true);
  return query select * from shop.audit_log order by at desc limit least(greatest(coalesce(p_limit,100),1),500);
end $$;

-- 目前登入者的身分（後台用來顯示/判斷）
create or replace function shop.admin_whoami()
returns jsonb
language sql stable security definer set search_path = shop
as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email',
                            'role', shop.current_admin_role(),
                            'aal', auth.jwt() ->> 'aal')
$$;

-- 清除舊訂單個資（只處理已完成或已取消，且超過 p_days 天未異動的訂單）
create or replace function shop.purge_old_pii(p_days integer default 180)
returns integer
language plpgsql volatile security definer set search_path = shop
as $$
declare n integer;
begin
  -- 由 owner 從後台呼叫，或由 pg_cron 以資料庫身分執行（auth.uid() 為 null）
  if auth.uid() is not null then perform shop.require_admin(true); end if;
  update shop.orders
     set customer_name = null, phone = null, address = null, note = null,
         pii_purged_at = now()
   where pii_purged_at is null
     and status in ('completed','cancelled')
     and updated_at < now() - make_interval(days => greatest(p_days, 30));
  get diagnostics n = row_count;
  insert into shop.audit_log(actor, actor_email, action, detail)
  values (auth.uid(), auth.jwt() ->> 'email', 'purge_pii', jsonb_build_object('rows', n, 'days', p_days));
  return n;
end $$;

-- ---------- 函式執行權限 ----------
revoke execute on all functions in schema shop from public, anon, authenticated;
grant execute on function shop.place_order(jsonb) to anon, authenticated;
grant execute on function shop.admin_list_orders(text, text, integer, integer) to authenticated;
grant execute on function shop.admin_get_order(uuid)                        to authenticated;
grant execute on function shop.admin_update_order(uuid, text, text)         to authenticated;
grant execute on function shop.admin_audit_log(integer)                      to authenticated;
grant execute on function shop.admin_whoami()                                to authenticated;
grant execute on function shop.purge_old_pii(integer)                        to authenticated;

-- =====================================================================
-- 初始資料（價格為暫定，可在 Table Editor 直接修改）
-- =====================================================================
insert into shop.shop_settings(id) values (true) on conflict do nothing;

insert into shop.shipping_methods(id, name, fee) values
  ('home',   '宅配到府（貨到付款）', 150),
  ('cvs',    '超商取貨付款',          70),
  ('pickup', '預約自取（付現）',       0)
on conflict (id) do nothing;

insert into shop.products(id, name, spec, price, sort) values
  ('original', '原味手工蝦餅', '單包 100g',            180, 1),
  ('family',   '家庭分享包',   '大包 250g',            399, 2),
  ('trio',     '原味三入組',   '100g × 3 包',          499, 3),
  ('gift',     '好蝦送禮盒',   '100g × 6 包・附提袋',  990, 4)
on conflict (id) do nothing;

-- =====================================================================
-- （選用）每天凌晨自動清除 180 天前已完成訂單的個資
-- 需先在 Database → Extensions 啟用 pg_cron，再執行：
-- select cron.schedule('purge-old-pii', '0 19 * * *', $$select shop.purge_old_pii(180)$$);
-- =====================================================================
