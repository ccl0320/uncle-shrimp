-- =====================================================================
-- 舅是好蝦：後台商品管理（圖片、價格、說明、上下架）
-- 在 schema.sql 之後執行。可以重複執行。
--
-- 安全設計
--  - 只有「店長 owner＋已完成兩步驟驗證」可以新增／修改商品、上傳圖片
--  - 商品圖片放在公開讀取的 storage bucket（顧客看得到圖片），但只有店長能寫入
--  - 圖片限制 2MB、只接受 JPG / PNG / WebP
--  - 每次修改都寫入操作紀錄
-- =====================================================================

alter table shop.products add column if not exists description text check (description is null or char_length(description) <= 300);
alter table shop.products add column if not exists tag         text check (tag is null or char_length(tag) <= 10);
alter table shop.products add column if not exists image_url   text check (image_url is null or image_url ~ '^https://');

update shop.products set description = case id
    when 'original' then '最經典的鮮蝦原味，酥脆不油膩，配茶、配啤酒都對味。'
    when 'family'   then '一家人一起吃剛剛好，追劇、聚會的最佳零嘴。'
    when 'trio'     then '自己吃、分朋友都方便，比單買更划算。'
    when 'gift'     then '過年過節、伴手禮首選，可加購手寫祝福卡。' end
  where description is null and id in ('original','family','trio','gift');
update shop.products set tag = case id when 'original' then '招牌' when 'trio' then '人氣' when 'gift' then '送禮' end
  where tag is null and id in ('original','trio','gift');

-- 給 storage 權限規則使用：只回傳「自己」的角色，不洩漏其他資訊
grant execute on function shop.current_admin_role() to authenticated;

-- ---------- 後台：商品列表（含已下架） ----------
create or replace function shop.admin_list_products()
returns setof shop.products
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin();
  return query select * from shop.products order by sort, id;
end $$;

-- ---------- 後台：新增或修改商品（店長） ----------
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
  exception when others then raise exception 'invalid_price'; end;
  if v_price is null or v_price not between 0 and 100000 then raise exception 'invalid_price'; end if;
  if v_img is not null and v_img !~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/shop-products/' then
    raise exception 'invalid_image';
  end if;

  select * into old from shop.products where id = v_id;

  insert into shop.products(id, name, spec, price, active, sort, description, tag, image_url, updated_at)
  values (v_id, v_name, v_spec, v_price, coalesce((p->>'active')::boolean, true), v_sort,
          nullif(btrim(coalesce(p->>'description','')), ''), nullif(btrim(coalesce(p->>'tag','')), ''), v_img, now())
  on conflict (id) do update set
    name = excluded.name, spec = excluded.spec, price = excluded.price, active = excluded.active,
    sort = excluded.sort, description = excluded.description, tag = excluded.tag,
    image_url = excluded.image_url, updated_at = now()
  returning * into r;

  perform shop.write_audit(case when old.id is null then 'create_product' else 'update_product' end, null,
    jsonb_build_object('product', v_id, 'name', v_name,
                       'price_from', old.price, 'price_to', v_price,
                       'active', r.active, 'image_changed', old.image_url is distinct from v_img));
  return r;
end $$;

revoke execute on function shop.admin_list_products() from public, anon;
revoke execute on function shop.admin_upsert_product(jsonb) from public, anon;
grant execute on function shop.admin_list_products() to authenticated;
grant execute on function shop.admin_upsert_product(jsonb) to authenticated;

-- ---------- 商品圖片儲存空間 ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shop-products', 'shop-products', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "shop products owner insert" on storage.objects;
create policy "shop products owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'shop-products' and shop.current_admin_role() = 'owner');

drop policy if exists "shop products owner update" on storage.objects;
create policy "shop products owner update" on storage.objects for update to authenticated
  using (bucket_id = 'shop-products' and shop.current_admin_role() = 'owner')
  with check (bucket_id = 'shop-products' and shop.current_admin_role() = 'owner');

drop policy if exists "shop products owner delete" on storage.objects;
create policy "shop products owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'shop-products' and shop.current_admin_role() = 'owner');
-- 公開 bucket 的圖片透過公開網址讀取，不需要 select 權限規則
