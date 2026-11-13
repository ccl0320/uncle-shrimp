-- =====================================================================
-- 舅是好蝦：後台設定運費
-- 在 007_qty_limit.sql 之後執行。可以重複執行。
--
-- 規則
--  - 店長可在後台調整各取貨方式的運費、名稱、說明、開放／關閉，以及免運門檻
--  - 至少要保留一種開放的取貨方式
--  - 運費仍由資料庫在下單時計算（place_order 讀這張表），前端改價無效
--  - 每次修改寫入操作紀錄
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'shop' and table_name = 'shop_settings' and column_name = 'weekly_pack_limit') then
    raise exception '請先依序執行 002～007，再執行 008';
  end if;
end $$;

alter table shop.shipping_methods add column if not exists note text check (note is null or char_length(note) <= 60);
alter table shop.shipping_methods add column if not exists sort integer not null default 0;

update shop.shipping_methods set
  name = case id when 'home' then '宅配到府' when 'cvs' then '超商取貨' when 'pickup' then '預約自取' else name end,
  note = coalesce(note, case id when 'home'   then '黑貓或郵局宅配，約 3–5 個工作天出貨'
                                when 'cvs'    then '7-11 / 全家，填寫取貨門市名稱'
                                when 'pickup' then '自取地點與時間，將由我們另行聯繫確認' end),
  sort = case id when 'home' then 1 when 'cvs' then 2 when 'pickup' then 3 else sort end
 where note is null;

-- ---------- 前台：運費與免運門檻（公開） ----------
create or replace function shop.public_settings()
returns jsonb
language sql stable security definer set search_path = shop
as $$
  select jsonb_build_object(
    'free_shipping_threshold', (select free_shipping_threshold from shop.shop_settings where id),
    'shipping', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'note', coalesce(note, ''), 'fee', fee) order by sort, id)
                            from shop.shipping_methods where active), '[]'::jsonb))
$$;

-- ---------- 後台：讀取／設定運費（店長） ----------
create or replace function shop.admin_get_shipping()
returns jsonb
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin();
  return jsonb_build_object(
    'free_shipping_threshold', (select free_shipping_threshold from shop.shop_settings where id),
    'methods', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'note', coalesce(note, ''), 'fee', fee, 'active', active) order by sort, id)
                           from shop.shipping_methods), '[]'::jsonb));
end $$;

create or replace function shop.admin_set_shipping(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare
  v_free  integer;
  m       jsonb;
  v_fee   integer;
  v_name  text;
  v_note  text;
  v_act   boolean;
  old     jsonb;
  v_oldfree integer;
begin
  perform shop.require_admin(true);
  begin
    v_free := (p->>'free_shipping_threshold')::integer;
  exception when others then raise exception 'invalid_free'; end;
  if v_free is null or v_free not between 0 and 1000000 then raise exception 'invalid_free'; end if;
  if jsonb_typeof(p->'methods') <> 'array' then raise exception 'invalid_shipping'; end if;

  select jsonb_object_agg(id, jsonb_build_object('fee', fee, 'active', active, 'name', name)) into old from shop.shipping_methods;
  select free_shipping_threshold into v_oldfree from shop.shop_settings where id;

  for m in select * from jsonb_array_elements(p->'methods') loop
    if not exists (select 1 from shop.shipping_methods where id = m->>'id') then raise exception 'invalid_shipping'; end if;
    begin
      v_fee := (m->>'fee')::integer;
      v_act := coalesce((m->>'active')::boolean, true);
    exception when others then raise exception 'invalid_fee'; end;
    v_name := btrim(coalesce(m->>'name', ''));
    v_note := nullif(btrim(coalesce(m->>'note', '')), '');
    if v_fee is null or v_fee not between 0 and 10000 then raise exception 'invalid_fee'; end if;
    if char_length(v_name) not between 1 and 20 then raise exception 'invalid_ship_name'; end if;
    if v_note is not null and char_length(v_note) > 60 then raise exception 'invalid_ship_note'; end if;
    update shop.shipping_methods set fee = v_fee, active = v_act, name = v_name, note = v_note where id = m->>'id';
  end loop;

  if not exists (select 1 from shop.shipping_methods where active) then raise exception 'need_one_shipping'; end if;
  update shop.shop_settings set free_shipping_threshold = v_free where id;

  perform shop.write_audit('update_shipping', null, jsonb_build_object(
    'free_from', v_oldfree, 'free', v_free, 'before', old,
    'after', (select jsonb_object_agg(id, jsonb_build_object('fee', fee, 'active', active, 'name', name)) from shop.shipping_methods)));
  return shop.admin_get_shipping();
end $$;

revoke execute on function shop.public_settings(), shop.admin_get_shipping(), shop.admin_set_shipping(jsonb) from public;
grant execute on function shop.public_settings() to anon, authenticated;
grant execute on function shop.admin_get_shipping(), shop.admin_set_shipping(jsonb) to authenticated;
