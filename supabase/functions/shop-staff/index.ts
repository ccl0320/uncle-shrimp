// 舅是好蝦：員工帳號 Edge Function（名稱：shop-staff）
//
// 只做兩件需要 Supabase 管理金鑰的事：建立員工登入帳號、重設員工密碼。
// 管理金鑰（SUPABASE_SERVICE_ROLE_KEY）由 Supabase 自動提供給這個函式，不會出現在網頁上。
//
// 安全檢查：
//  - 每次呼叫都用「呼叫者自己的登入憑證」到資料庫確認是店長、且已通過兩步驟驗證
//  - 寫入員工名單與操作紀錄也用呼叫者的身分，紀錄會記在店長名下
//  - 重設密碼只能對這家店員工名單裡的帳號，不能動到同一個 Supabase 專案的其他使用者
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// 允許呼叫的後台網址。換網域時：在 Supabase → Edge Functions → Secrets 新增 ALLOWED_ORIGINS
// （多個用逗號分隔，例如 https://uncle-shrimp.pages.dev,https://www.example.com），不用改程式
const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") || "https://uncle-shrimp.pages.dev,https://ccl0320.github.io")
  .split(",").map((x) => x.trim().replace(/\/$/, "")).filter(Boolean);

function cors(origin: string): Record<string, string> {
  const ok = ALLOWED_ORIGINS.includes(origin || "");
  return {
    "Access-Control-Allow-Origin": ok ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function reply(origin: string, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(origin), "Content-Type": "application/json" },
  });
}

function strongPassword(pw: unknown): boolean {
  return typeof pw === "string" && pw.length >= 12 && pw.length <= 72 &&
    /[a-z]/.test(pw) && /[A-Z]/.test(pw) && /[0-9]/.test(pw);
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin") || "";
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(origin) });
  if (req.method !== "POST") return reply(origin, 405, { error: "method_not_allowed" });
  if (!ALLOWED_ORIGINS.includes(origin)) return reply(origin, 403, { error: "forbidden_origin" });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return reply(origin, 401, { error: "not_authorized" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 以呼叫者身分連資料庫（權限由資料庫函式檢查）
  const asCaller = createClient(url, anon, {
    db: { schema: "shop" },
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // 管理用（只用來建立帳號、改密碼）
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return reply(origin, 400, { error: "bad_request" }); }

  // 確認呼叫者是店長且已通過兩步驟驗證
  const who = await asCaller.rpc("admin_whoami");
  if (who.error || !who.data || who.data.role !== "owner") return reply(origin, 403, { error: "owner_only" });

  try {
    if (body.action === "create") {
      const email = String(body.email || "").trim().toLowerCase();
      const role = body.role === "owner" ? "owner" : "staff";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 200) return reply(origin, 400, { error: "invalid_email" });
      if (!strongPassword(body.password)) return reply(origin, 400, { error: "weak_password" });

      const created = await admin.auth.admin.createUser({ email, password: body.password, email_confirm: true });
      if (created.error) {
        const m = created.error.message || "";
        return reply(origin, 409, { error: /already|registered|exists/i.test(m) ? "email_exists" : "create_failed" });
      }
      const uid = created.data.user.id;
      const added = await asCaller.rpc("admin_add_staff", { p_user: uid, p_role: role });
      if (added.error) {
        await admin.auth.admin.deleteUser(uid); // 加入名單失敗就把剛建立的帳號刪掉
        return reply(origin, 400, { error: added.error.message || "create_failed" });
      }
      return reply(origin, 200, added.data);
    }

    if (body.action === "reset_password") {
      const uid = String(body.user_id || "");
      if (!UUID.test(uid)) return reply(origin, 400, { error: "staff_not_found" });
      if (!strongPassword(body.password)) return reply(origin, 400, { error: "weak_password" });
      // 先確認是這家店的員工、而且不是自己
      const chk = await asCaller.rpc("admin_check_staff", { p_user: uid });
      if (chk.error) return reply(origin, 400, { error: chk.error.message });
      const upd = await admin.auth.admin.updateUserById(uid, { password: body.password });
      if (upd.error) return reply(origin, 400, { error: "reset_failed" });
      const mark = await asCaller.rpc("admin_staff_password_reset", { p_user: uid });
      if (mark.error) return reply(origin, 400, { error: mark.error.message });
      return reply(origin, 200, { ok: true });
    }

    return reply(origin, 400, { error: "bad_request" });
  } catch (_e) {
    return reply(origin, 500, { error: "server_error" });
  }
});
