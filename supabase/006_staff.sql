-- =====================================================================
-- 舅是好蝦：後台員工帳號管理
-- 在 005_copy.sql 之後執行。可以重複執行。
--
-- 規則
--  - 只有店長（已通過兩步驟驗證）可以新增、停用、移除員工或改角色，所有動作寫入操作紀錄
--  - 建立登入帳號需要 Supabase 管理金鑰，所以由 Edge Function「shop-staff」在伺服器端處理，
--    管理金鑰永遠不會出現在網頁上
--  - 店長幫員工設定初始密碼；員工第一次登入要先綁兩步驟驗證，再強制改成自己的密碼，
--    改好之前看不到任何訂單資料（資料庫比對密碼是否真的換過，不能跳過）
--  - 停用或移除後立即失效（每次讀資料都會重新檢查名單）
--  - 不能停用、移除或降級自己，避免把自己鎖在外面
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'shop' and table_name = 'products' and column_name = 'sale_price') then
    raise exception '請先依序執行 002、003、004、005，再執行 006';
  end if;
end $$;

alter table shop.admin_users add column if not exists active               boolean not null default true;
alter table shop.admin_users add column if not exists must_change_password boolean not null default false;
alter table shop.admin_users add column if not exists initial_pw_hash      text;
alter table shop.admin_users add column if not exists created_by           uuid;

-- ---------- 權限判斷：停用或還沒改初始密碼的帳號沒有權限 ----------
create or replace function shop.current_admin_role()
returns text
language sql stable security definer set search_path = shop
as $$
  select a.role
    from shop.admin_users a
   where a.user_id = auth.uid()
     and a.active
     and not a.must_change_password
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

create or replace function shop.admin_whoami()
returns jsonb
language sql stable security definer set search_path = shop
as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email',
                            'role', shop.current_admin_role(),
                            'aal', auth.jwt() ->> 'aal',
                            'must_change_password', coalesce((
                               select a.must_change_password and a.active
                                 from shop.admin_users a where a.user_id = auth.uid()), false))
$$;

-- ---------- 員工第一次登入：確認密碼已換掉，解除限制 ----------
create or replace function shop.admin_password_changed()
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare a shop.admin_users; v_hash text;
begin
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from shop.admin_users where user_id = auth.uid() and active;
  if not found then raise exception 'not_authorized' using errcode = '42501'; end if;
  if not a.must_change_password then return shop.admin_whoami(); end if;
  select encrypted_password into v_hash from auth.users where id = auth.uid();
  if v_hash is null or v_hash = a.initial_pw_hash then raise exception 'password_not_changed'; end if;
  update shop.admin_users set must_change_password = false, initial_pw_hash = null where user_id = a.user_id;
  perform shop.write_audit('staff_password_set', null, jsonb_build_object('email', a.email));
  return shop.admin_whoami();
end $$;

-- ---------- 店長：員工名單 ----------
create or replace function shop.admin_list_staff()
returns jsonb
language plpgsql stable security definer set search_path = shop
as $$
begin
  perform shop.require_admin(true);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'user_id', a.user_id, 'email', a.email, 'role', a.role, 'active', a.active,
             'must_change_password', a.must_change_password, 'created_at', a.created_at,
             'last_sign_in_at', u.last_sign_in_at,
             'mfa', exists (select 1 from auth.mfa_factors f where f.user_id = a.user_id and f.status = 'verified'),
             'is_me', a.user_id = auth.uid())
           order by a.role, a.created_at)
      from shop.admin_users a left join auth.users u on u.id = a.user_id), '[]'::jsonb);
end $$;

-- 內部：檢查目標是不是這家店的員工、而且不是自己
create or replace function shop.staff_target(p_user uuid)
returns shop.admin_users
language plpgsql stable security definer set search_path = shop
as $$
declare a shop.admin_users;
begin
  perform shop.require_admin(true);
  select * into a from shop.admin_users where user_id = p_user;
  if not found then raise exception 'staff_not_found'; end if;
  if p_user = auth.uid() then raise exception 'cannot_change_self'; end if;
  return a;
end $$;

-- ---------- 店長：把新建立的登入帳號加入名單（由 Edge Function 呼叫，身分是店長本人） ----------
create or replace function shop.admin_add_staff(p_user uuid, p_role text)
returns jsonb
language plpgsql volatile security definer set search_path = shop
as $$
declare v_email text; v_hash text;
begin
  perform shop.require_admin(true);
  if p_role not in ('owner','staff') then raise exception 'invalid_role'; end if;
  if exists (select 1 from shop.admin_users where user_id = p_user) then raise exception 'staff_exists'; end if;
  select email, encrypted_password into v_email, v_hash from auth.users where id = p_user;
  if v_email is null then raise exception 'staff_not_found'; end if;
  insert into shop.admin_users(user_id, email, role, active, must_change_password, initial_pw_hash, created_by)
  values (p_user, lower(v_email), p_role, true, true, v_hash, auth.uid());
  perform shop.write_audit('create_staff', null, jsonb_build_object('email', lower(v_email), 'role', p_role));
  return jsonb_build_object('user_id', p_user, 'email', lower(v_email), 'role', p_role);
end $$;

-- ---------- 店長：重設密碼前檢查／重設後要求員工再改一次 ----------
create or replace function shop.admin_check_staff(p_user uuid)
returns jsonb
language plpgsql stable security definer set search_path = shop
as $$
declare a shop.admin_users;
begin
  a := shop.staff_target(p_user);
  return jsonb_build_object('user_id', a.user_id, 'email', a.email);
end $$;

create or replace function shop.admin_staff_password_reset(p_user uuid)
returns void
language plpgsql volatile security definer set search_path = shop
as $$
declare a shop.admin_users; v_hash text;
begin
  a := shop.staff_target(p_user);
  select encrypted_password into v_hash from auth.users where id = p_user;
  update shop.admin_users set must_change_password = true, initial_pw_hash = v_hash where user_id = p_user;
  perform shop.write_audit('reset_staff_password', null, jsonb_build_object('email', a.email));
end $$;

-- ---------- 店長：改角色、停用／啟用 ----------
create or replace function shop.admin_update_staff(p_user uuid, p_role text default null, p_active boolean default null)
returns void
language plpgsql volatile security definer set search_path = shop
as $$
declare a shop.admin_users;
begin
  a := shop.staff_target(p_user);
  if p_role is not null and p_role not in ('owner','staff') then raise exception 'invalid_role'; end if;
  update shop.admin_users
     set role = coalesce(p_role, role), active = coalesce(p_active, active)
   where user_id = p_user;
  perform shop.write_audit('update_staff', null, jsonb_build_object(
    'email', a.email, 'role_from', a.role, 'role', coalesce(p_role, a.role),
    'active_from', a.active, 'active', coalesce(p_active, a.active)));
end $$;

-- ---------- 店長：從名單移除（登入帳號保留但完全沒有後台權限） ----------
create or replace function shop.admin_remove_staff(p_user uuid)
returns void
language plpgsql volatile security definer set search_path = shop
as $$
declare a shop.admin_users;
begin
  a := shop.staff_target(p_user);
  delete from shop.admin_users where user_id = p_user;
  perform shop.write_audit('remove_staff', null, jsonb_build_object('email', a.email, 'role', a.role));
end $$;

revoke execute on function shop.staff_target(uuid) from public, anon, authenticated;
revoke execute on function shop.admin_password_changed(), shop.admin_list_staff(), shop.admin_add_staff(uuid, text),
  shop.admin_check_staff(uuid), shop.admin_staff_password_reset(uuid), shop.admin_update_staff(uuid, text, boolean),
  shop.admin_remove_staff(uuid) from public, anon;
grant execute on function shop.admin_password_changed(), shop.admin_list_staff(), shop.admin_add_staff(uuid, text),
  shop.admin_check_staff(uuid), shop.admin_staff_password_reset(uuid), shop.admin_update_staff(uuid, text, boolean),
  shop.admin_remove_staff(uuid) to authenticated;
-- current_admin_role / admin_whoami 原本的授權保留
