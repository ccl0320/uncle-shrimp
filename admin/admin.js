// 舅是好蝦 訂單後台
// 安全重點：
//  - 登入使用 Supabase Auth（密碼雜湊、重設流程由 Supabase 處理），強制 TOTP 兩步驟驗證
//  - 登入狀態存在 sessionStorage，關閉分頁就登出；15 分鐘沒有操作自動登出
//  - 所有資料都透過資料庫函式取得，權限在資料庫端檢查（前端被改也拿不到資料）
//  - 顧客輸入的文字一律以純文字顯示，避免 XSS
(function () {
  "use strict";
  const CFG = window.USC_CONFIG || {};
  const DEMO = !CFG.supabaseUrl || !CFG.supabaseAnonKey;
  const IDLE_MS = 15 * 60 * 1000;
  const PAGE = 30;

  const STATUS = [
    ["pending", "待確認"], ["confirmed", "已確認"], ["shipped", "已出貨"],
    ["completed", "已完成"], ["cancelled", "已取消"]
  ];
  const STATUS_NAME = Object.fromEntries(STATUS);
  const SHIP_NAME = { home: "宅配", cvs: "超商取貨", pickup: "自取" };
  const ERR = {
    "Invalid login credentials": "Email 或密碼錯誤。",
    "Email not confirmed": "這個帳號還沒完成 Email 驗證。",
    "Invalid TOTP code entered": "驗證碼錯誤或已過期，請輸入 App 上最新的 6 位數。",
    not_authorized: "沒有權限，或尚未完成兩步驟驗證。",
    owner_only: "只有店長帳號可以執行。",
    not_found: "找不到這筆訂單。"
  };

  const $ = (s) => document.querySelector(s);
  const esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const fmt = (n) => "NT$" + Number(n || 0).toLocaleString("zh-TW");
  const when = (t) => new Date(t).toLocaleString("zh-TW", { timeZone: "Asia/Taipei", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  const msg = (e) => { const m = (e && (e.message || e.error_description)) || String(e); for (const k in ERR) if (m.includes(k)) return ERR[k]; return "發生錯誤：" + m; };

  const VIEWS = ["vLogin", "vForgot", "vEnroll", "vMfa", "vNewPw", "vDenied", "vOrders"];
  function show(id) { VIEWS.forEach((v) => ($("#" + v).hidden = v !== id)); const f = $("#" + id + " input"); if (f && id !== "vOrders") setTimeout(() => f.focus(), 50); }
  function busy(form, on) { form.querySelectorAll("button").forEach((b) => (b.disabled = on)); }

  // ------------------------------------------------------------------
  // 資料存取層
  // ------------------------------------------------------------------
  let sb = null, api, me = null, recovering = false, forcePw = false, enrollFactorId = null;

  if (!DEMO) {
    if (!window.supabase) { document.body.textContent = "無法載入登入元件，請檢查網路後重新整理。"; return; }
    sb = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
      db: { schema: "shop" },
      auth: { storage: window.sessionStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    const rpc = async (fn, args) => { const { data, error } = await sb.rpc(fn, args || {}); if (error) throw error; return data; };
    // 建立帳號／重設密碼需要管理金鑰，交給伺服器端的 Edge Function 處理
    const staffFn = async (body) => {
      const { data, error } = await sb.functions.invoke("shop-staff", { body });
      if (!error) return data;
      let code = error.message || "";
      try { const j = await error.context.json(); code = j.error || code; } catch (_) { if (error.context && error.context.status === 404) code = "function_missing"; }
      if (/Failed to send|FunctionsFetchError/i.test(error.name + " " + code)) code = "function_missing";
      throw new Error(code);
    };
    api = {
      whoami: () => rpc("admin_whoami"),
      list: (status, search, offset) => rpc("admin_list_orders", { p_status: status, p_search: search, p_limit: PAGE, p_offset: offset }),
      get: (id) => rpc("admin_get_order", { p_id: id }),
      update: (id, status, note) => rpc("admin_update_order", { p_id: id, p_status: status, p_admin_note: note }),
      audit: () => rpc("admin_audit_log", { p_limit: 200 }),
      purge: (days) => rpc("purge_old_pii", { p_days: days }),
      products: () => rpc("admin_list_products"),
      getPromo: () => rpc("admin_get_promo"),
      setPromo: (p) => rpc("admin_set_promo", { p }),
      passwordChanged: () => rpc("admin_password_changed"),
      listStaff: () => rpc("admin_list_staff"),
      updateStaff: (uid, role, active) => rpc("admin_update_staff", { p_user: uid, p_role: role, p_active: active }),
      removeStaff: (uid) => rpc("admin_remove_staff", { p_user: uid }),
      createStaff: (email, password, role) => staffFn({ action: "create", email, password, role }),
      resetStaffPw: (uid, password) => staffFn({ action: "reset_password", user_id: uid, password }),
      saveProduct: (p) => rpc("admin_upsert_product", { p }),
      uploadImage: async (blob) => {
        const path = "p/" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8) + ".webp";
        const { error } = await sb.storage.from("shop-products").upload(path, blob, { contentType: "image/webp", upsert: false, cacheControl: "31536000" });
        if (error) throw error;
        return sb.storage.from("shop-products").getPublicUrl(path).data.publicUrl;
      }
    };
  } else {
    // 示範資料（完全虛構）
    const now = Date.now(), H = 3600e3;
    const demo = [
      ["王小明", "0912345678", "home", "台北市中山區民生東路一段 1 號 5 樓", [["原味手工蝦餅", "單包 100g", 180, 2], ["原味三入組", "100g × 3 包", 499, 1]], "pending", 1, "下午時段收件"],
      ["林美玲", "0928111222", "cvs", "7-11 民生門市", [["家庭分享包", "大包 250g", 399, 1]], "pending", 3, ""],
      ["陳志豪", "0933444555", "home", "新北市板橋區文化路二段 100 號", [["好蝦送禮盒", "100g × 6 包・附提袋", 990, 2]], "confirmed", 20, "送禮用，請附祝福卡：生日快樂"],
      ["張雅婷", "0955666777", "pickup", null, [["原味手工蝦餅", "單包 100g", 180, 3]], "shipped", 46, ""],
      ["黃建國", "0966777888", "cvs", "全家 板橋文化店", [["原味三入組", "100g × 3 包", 499, 2]], "completed", 120, ""],
      ["李淑芬", "0977888999", "home", "台中市西屯區台灣大道三段 99 號", [["家庭分享包", "大包 250g", 399, 1]], "cancelled", 200, "改期再訂"]
    ].map((d, i) => {
      const sub = d[4].reduce((a, x) => a + x[2] * x[3], 0), fee = sub >= 520 ? 0 : ({ home: 150, cvs: 70, pickup: 0 })[d[2]];
      return { id: "demo-" + i, order_no: "USC2611" + (13 - Math.floor(d[6] / 24)).toString().padStart(2, "0") + "-" + (0xA1B2C + i * 4099).toString(16).toUpperCase().slice(0, 5),
        status: d[5], created_at: new Date(now - d[6] * H).toISOString(), customer_name: d[0], phone: d[1], ship_method: d[2],
        ship_name: { home: "宅配到府（貨到付款）", cvs: "超商取貨付款", pickup: "預約自取（付現）" }[d[2]], address: d[3], note: d[7] || null,
        pay_method: "cod", subtotal: sub, shipping_fee: fee, total: sub + fee, admin_note: null, pii_purged: false,
        items: d[4].map((x) => ({ name: x[0], spec: x[1], unit_price: x[2], qty: x[3] })) };
    });
    const log = [];
    const mask = (n) => n.length <= 1 ? n : n.length === 2 ? n[0] + "○" : n[0] + "○".repeat(n.length - 2) + n.slice(-1);
    const wait = (v) => new Promise((r) => setTimeout(() => r(v), 150));
    api = {
      whoami: () => wait({ email: "owner@example.com", role: "owner", aal: "aal2" }),
      list: (status, search, offset) => {
        let r = demo.filter((o) => (!status || o.status === status) && (!search || o.order_no.includes(search.toUpperCase()) || o.phone === search.replace(/[\s-]/g, "")));
        const total = r.length;
        return wait(r.slice(offset, offset + PAGE).map((o) => ({ id: o.id, order_no: o.order_no, status: o.status, created_at: o.created_at,
          customer_name_masked: mask(o.customer_name), phone_masked: o.phone.slice(0, 4) + "***" + o.phone.slice(-3), ship_method: o.ship_method,
          total: o.total, item_summary: o.items.map((x) => x.name + "×" + x.qty).join("、"), total_count: total })));
      },
      get: (id) => { const o = demo.find((x) => x.id === id); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "view_order", detail: { order_no: o.order_no } }); return wait(JSON.parse(JSON.stringify(o))); },
      update: (id, status, note) => { const o = demo.find((x) => x.id === id); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "update_order", detail: { from: o.status, to: status || o.status } }); if (status) o.status = status; if (note != null) o.admin_note = note; return wait(null); },
      audit: () => wait(log.slice()),
      purge: () => wait(0),
      products: () => wait(demoProducts.map((x) => ({ ...x }))),
      getPromo: () => wait({ ...demoPromo, live: demoLive() }),
      passwordChanged: () => wait({ email: "owner@example.com", role: "owner", aal: "aal2" }),
      listStaff: () => wait(demoStaff.map((x) => ({ ...x }))),
      createStaff: (email, password, role) => { if (demoStaff.some((x) => x.email === email.toLowerCase())) return Promise.reject(new Error("email_exists")); demoStaff.push({ user_id: "demo-" + Date.now(), email: email.toLowerCase(), role, active: true, must_change_password: true, mfa: false, created_at: new Date().toISOString(), last_sign_in_at: null, is_me: false }); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "create_staff", detail: { email, role } }); return wait({}); },
      updateStaff: (uid, role, active) => { const s = demoStaff.find((x) => x.user_id === uid); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "update_staff", detail: { email: s.email, role_from: s.role, role: role || s.role, active_from: s.active, active: active == null ? s.active : active } }); if (role) s.role = role; if (active != null) s.active = active; return wait(null); },
      removeStaff: (uid) => { const i = demoStaff.findIndex((x) => x.user_id === uid); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "remove_staff", detail: { email: demoStaff[i].email } }); demoStaff.splice(i, 1); return wait(null); },
      resetStaffPw: (uid) => { const s = demoStaff.find((x) => x.user_id === uid); s.must_change_password = true; log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "reset_staff_password", detail: { email: s.email } }); return wait({}); },
      setPromo: (p) => { Object.assign(demoPromo, p); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: "update_promo", detail: { enabled: p.enabled, name: p.name, pay_percent: p.pay_percent } }); return wait({ ...demoPromo, live: demoLive() }); },
      saveProduct: (p) => { const i = demoProducts.findIndex((x) => x.id === p.id); const row = { ...p, price: Number(p.price), sale_price: p.sale_price === "" || p.sale_price == null ? null : Number(p.sale_price) }; if (row.sale_price != null && row.sale_price >= row.price) return Promise.reject(new Error("invalid_sale")); if (i >= 0) demoProducts[i] = row; else demoProducts.push(row); log.unshift({ at: new Date().toISOString(), actor_email: "owner@example.com", action: i >= 0 ? "update_product" : "create_product", detail: { product: p.id, name: p.name, price_to: p.price } }); return wait(row); },
      uploadImage: (blob) => wait(URL.createObjectURL(blob))
    };
    var demoStaff = [
      { user_id: "demo-owner", email: "owner@example.com", role: "owner", active: true, must_change_password: false, mfa: true, created_at: new Date(Date.now() - 864e5 * 3).toISOString(), last_sign_in_at: new Date().toISOString(), is_me: true },
      { user_id: "demo-staff", email: "helper@example.com", role: "staff", active: true, must_change_password: true, mfa: false, created_at: new Date(Date.now() - 36e5).toISOString(), last_sign_in_at: null, is_me: false }
    ];
    var demoPromo = { enabled: false, name: "新開張試行 全館 7 折", pay_percent: 70, start_at: null, end_at: new Date(Date.now() + 17 * 864e5).toISOString(), free_shipping_threshold: 520 };
    var demoLive = () => { const n = Date.now(); const on = demoPromo.enabled && demoPromo.pay_percent < 100 && (!demoPromo.start_at || n >= Date.parse(demoPromo.start_at)) && (!demoPromo.end_at || n < Date.parse(demoPromo.end_at)); return on ? { active: true, name: demoPromo.name, pay_percent: demoPromo.pay_percent, end_at: demoPromo.end_at } : { active: false }; };
    var demoProducts = [
      { id: "original", name: "原味手工蝦餅", spec: "單包 100g", price: 100, active: true, sort: 1, tag: "招牌", description: "選用印尼進口蝦餅原料，由舅舅在台灣手工油炸，做出金黃酥脆、讓大人小孩一口接一口的好滋味。", image_url: "../assets/bag.webp" },
      { id: "family", name: "家庭分享包", spec: "大包 250g", price: 399, active: false, sort: 2, tag: "", description: "一家人一起吃剛剛好。", image_url: "../assets/bowl.webp" },
      { id: "trio", name: "原味三入組", spec: "100g × 3 包", price: 260, active: true, sort: 3, tag: "人氣", description: "比單買更划算。", image_url: null },
      { id: "gift", name: "好蝦送禮盒", spec: "100g × 6 包・附提袋", price: 990, active: false, sort: 4, tag: "送禮", description: "伴手禮首選。", image_url: null }
    ];
  }

  // ------------------------------------------------------------------
  // 登入流程
  // ------------------------------------------------------------------
  async function route() {
    if (DEMO) { $("#demoBanner").hidden = false; return enterApp(); }
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return show("vLogin");
    const { data: aal, error } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) return show("vLogin");
    if (aal.currentLevel === "aal2") return recovering ? show("vNewPw") : enterApp();
    // 尚未通過兩步驟驗證
    const { data: f } = await sb.auth.mfa.listFactors();
    const verified = (f && f.totp || []).filter((x) => x.status === "verified");
    if (verified.length) { show("vMfa"); return; }
    await startEnroll(f);
  }

  async function startEnroll(f) {
    // 清掉之前沒完成的綁定
    for (const x of (f && f.all || [])) if (x.status === "unverified") await sb.auth.mfa.unenroll({ factorId: x.id });
    const { data, error } = await sb.auth.mfa.enroll({ factorType: "totp", friendlyName: "舅是好蝦後台 " + new Date().toISOString().slice(0, 10) });
    if (error) { show("vLogin"); $("#loginErr").textContent = msg(error); return; }
    enrollFactorId = data.id;
    $("#qrImg").src = data.totp.qr_code;
    $("#secret").textContent = data.totp.secret;
    show("vEnroll");
  }

  $("#loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = $("#email").value.trim(), password = $("#password").value;
    $("#loginErr").textContent = "";
    if (!email || !password) { $("#loginErr").textContent = "請輸入 Email 和密碼。"; return; }
    busy(e.target, true);
    const { error } = await sb.auth.signInWithPassword({ email, password });
    busy(e.target, false);
    $("#password").value = "";
    if (error) { $("#loginErr").textContent = msg(error); return; }
    route();
  });

  async function verify(code, factorId, errEl, form) {
    errEl.textContent = "";
    if (!/^\d{6}$/.test(code)) { errEl.textContent = "請輸入 6 位數字。"; return; }
    busy(form, true);
    if (!factorId) { const { data: f } = await sb.auth.mfa.listFactors(); factorId = (f.totp.find((x) => x.status === "verified") || {}).id; }
    const { error } = await sb.auth.mfa.challengeAndVerify({ factorId, code });
    busy(form, false);
    if (error) { errEl.textContent = msg(error); return; }
    route();
  }
  $("#mfaForm").addEventListener("submit", (e) => { e.preventDefault(); verify($("#mfaCode").value.trim(), null, $("#mfaErr"), e.target).finally(() => ($("#mfaCode").value = "")); });
  $("#enrollForm").addEventListener("submit", (e) => { e.preventDefault(); verify($("#enrollCode").value.trim(), enrollFactorId, $("#enrollErr"), e.target).finally(() => ($("#enrollCode").value = "")); });

  $("#forgotBtn").addEventListener("click", () => show("vForgot"));
  document.querySelectorAll("[data-go]").forEach((b) => b.addEventListener("click", () => show(b.dataset.go)));
  $("#forgotForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = $("#fEmail").value.trim();
    if (!email) { $("#forgotErr").textContent = "請輸入 Email。"; return; }
    busy(e.target, true);
    await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    busy(e.target, false);
    // 不論帳號是否存在都顯示同樣訊息，避免被用來探測帳號
    $("#forgotErr").textContent = "如果這是管理員帳號，重設連結已寄到信箱。";
  });

  $("#newPwForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const a = $("#newPw").value, b = $("#newPw2").value, err = $("#newPwErr");
    err.textContent = "";
    if (a.length < 12 || !/[a-z]/.test(a) || !/[A-Z]/.test(a) || !/\d/.test(a)) { err.textContent = "密碼至少 12 個字元，且要有英文大寫、小寫和數字。"; return; }
    if (a !== b) { err.textContent = "兩次輸入的密碼不一樣。"; return; }
    busy(e.target, true);
    const { error } = await sb.auth.updateUser({ password: a });
    busy(e.target, false);
    $("#newPw").value = $("#newPw2").value = "";
    if (error) { err.textContent = msg(error); return; }
    recovering = false;
    if (forcePw) {
      try { await api.passwordChanged(); } catch (e2) { err.textContent = /password_not_changed/.test(e2.message || "") ? "新密碼不能和初始密碼一樣。" : msg(e2); return; }
      forcePw = false; $("#newPwHint").hidden = true; $("#newPwTitle").textContent = "設定新密碼";
    }
    enterApp();
  });

  async function logout() {
    if (sb) await sb.auth.signOut();
    me = null; closeSheet();
    $("#who").hidden = $("#logoutBtn").hidden = true;
    $("#orderList").innerHTML = ""; $("#dBody").innerHTML = "";
    if (DEMO) location.reload(); else show("vLogin");
  }
  $("#logoutBtn").addEventListener("click", logout);
  $("#deniedLogout").addEventListener("click", logout);

  if (sb) sb.auth.onAuthStateChange((event) => {
    if (event === "PASSWORD_RECOVERY") { recovering = true; route(); }
    if (event === "SIGNED_OUT" && !$("#vOrders").hidden) show("vLogin");
  });

  // 閒置自動登出
  let idleTimer;
  const bump = () => { clearTimeout(idleTimer); if (me && !DEMO) idleTimer = setTimeout(() => { logout(); $("#loginErr").textContent = "閒置超過 15 分鐘，已自動登出。"; }, IDLE_MS); };
  ["click", "keydown", "touchstart", "scroll"].forEach((ev) => document.addEventListener(ev, bump, { passive: true }));

  // ------------------------------------------------------------------
  // 訂單畫面
  // ------------------------------------------------------------------
  let fStatus = "pending", fSearch = "", offset = 0;

  async function enterApp() {
    try { me = await api.whoami(); } catch (e) { me = null; }
    if (me && me.must_change_password) { forcePw = true; $("#newPwTitle").textContent = "設定你自己的密碼"; $("#newPwHint").hidden = false; show("vNewPw"); return; }
    if (!me || !me.role) { show("vDenied"); return; }
    $("#who").textContent = me.email + (me.role === "owner" ? "（店長）" : "（員工）");
    $("#who").hidden = $("#logoutBtn").hidden = false;
    $("#auditTab").hidden = $("#productsTab").hidden = $("#staffTab").hidden = me.role !== "owner";
    show("vOrders"); bump();
    renderChips(); load(true);
  }

  function renderChips() {
    const all = [["", "全部"]].concat(STATUS);
    $("#statusChips").innerHTML = all.map(([k, n]) => `<button type="button" class="chip${k === fStatus ? " on" : ""}" data-s="${k}">${n}</button>`).join("");
  }
  $("#statusChips").addEventListener("click", (e) => { const b = e.target.closest(".chip"); if (!b) return; fStatus = b.dataset.s; renderChips(); load(true); });
  let st;
  $("#search").addEventListener("input", () => { clearTimeout(st); st = setTimeout(() => { fSearch = $("#search").value.trim(); load(true); }, 350); });

  async function load(reset) {
    if (reset) { offset = 0; $("#orderList").innerHTML = ""; }
    $("#listInfo").textContent = "載入中…";
    try {
      const rows = await api.list(fStatus || null, fSearch || null, offset);
      const total = rows.length ? Number(rows[0].total_count) : (reset ? 0 : null);
      $("#orderList").insertAdjacentHTML("beforeend", rows.map((o) => `
        <li><button type="button" class="order" data-id="${esc(o.id)}">
          <span class="no">${esc(o.order_no)}</span><span class="pill ${esc(o.status)}">${esc(STATUS_NAME[o.status] || o.status)}</span>
          <span class="meta">${esc(when(o.created_at))}・${esc(o.customer_name_masked || "（已清除）")}・${esc(o.phone_masked || "")}・${esc(SHIP_NAME[o.ship_method] || o.ship_method)}</span>
          <span class="items">${esc(o.item_summary || "")}</span><span class="sum">${fmt(o.total)}</span>
        </button></li>`).join(""));
      offset += rows.length;
      if (total === 0) { $("#orderList").innerHTML = `<li class="empty">${fSearch ? "找不到符合的訂單" : "目前沒有這個狀態的訂單"}</li>`; }
      if (total != null) $("#listInfo").textContent = total ? `共 ${total} 筆` : "";
      $("#moreBtn").hidden = total == null || offset >= total;
    } catch (e) { $("#listInfo").textContent = msg(e); }
  }
  $("#moreBtn").addEventListener("click", () => load(false));
  $("#orderList").addEventListener("click", (e) => { const b = e.target.closest(".order"); if (b) openOrder(b.dataset.id); });

  // 明細
  let current = null, lastFocus = null;
  async function openOrder(id) {
    lastFocus = document.activeElement;
    $("#dNo").textContent = "載入中…"; $("#dBody").innerHTML = "";
    $("#sheet").hidden = $("#sheetBg").hidden = false;
    $("#sheetClose").focus();
    try { current = await api.get(id); } catch (e) { $("#dBody").innerHTML = `<p class="err">${esc(msg(e))}</p>`; return; }
    const o = current;
    $("#dNo").textContent = o.order_no;
    const opts = STATUS.map(([k, n]) => `<option value="${k}"${k === o.status ? " selected" : ""}>${n}</option>`).join("");
    $("#dBody").innerHTML = `
      ${o.pii_purged ? `<p class="purged">此訂單的個資已依保存期限清除。</p>` : ""}
      <dl>
        <dt>下單時間</dt><dd>${esc(new Date(o.created_at).toLocaleString("zh-TW", { timeZone: "Asia/Taipei", hour12: false }))}</dd>
        <dt>收件人</dt><dd>${esc(o.customer_name || "—")}</dd>
        <dt>手機</dt><dd>${esc(o.phone || "—")}</dd>
        <dt>取貨方式</dt><dd>${esc(o.ship_name || o.ship_method)}</dd>
        ${o.address ? `<dt>${o.ship_method === "cvs" ? "門市" : "地址"}</dt><dd><span id="dAddr">${esc(o.address)}</span> <button class="btn mini" type="button" id="copyAddr">複製</button></dd>` : ""}
        <dt>付款</dt><dd>貨到付款／取貨付款</dd>
        ${o.note ? `<dt>顧客備註</dt><dd>${esc(o.note)}</dd>` : ""}
      </dl>
      <table class="items-t"><tbody>
        ${o.items.map((it) => `<tr><td>${esc(it.name)}<br><span class="muted small">${esc(it.spec)}・${it.list_price && it.list_price !== it.unit_price ? `<span class="strike">${fmt(it.list_price)}</span>` : ""}${fmt(it.unit_price)} × ${esc(it.qty)}</span></td><td>${fmt(it.unit_price * it.qty)}</td></tr>`).join("")}
        ${o.discount ? `<tr><td>${esc(o.promo_name || "折扣")}（已折抵 ${fmt(o.discount)}）</td><td></td></tr>` : ""}
        <tr><td>運費</td><td>${o.shipping_fee ? fmt(o.shipping_fee) : "免運"}</td></tr>
        <tr class="total"><td>應收金額</td><td>${fmt(o.total)}</td></tr>
      </tbody></table>
      <label for="dStatus">訂單狀態</label>
      <select id="dStatus">${opts}</select>
      <label for="dNote">內部備註（顧客看不到）</label>
      <textarea id="dNote" maxlength="1000" placeholder="例如：已聯繫確認、物流單號">${esc(o.admin_note || "")}</textarea>
      <button class="btn primary" type="button" id="dSave">儲存</button>
      <p class="save-msg" id="dMsg" role="status"></p>`;
    const ca = $("#copyAddr");
    if (ca) ca.addEventListener("click", () => {
      const t = o.address;
      const ok = () => (ca.textContent = "已複製");
      try { navigator.clipboard.writeText(t).then(ok, () => {}); } catch (e) { /* ignore */ }
    });
    $("#dSave").addEventListener("click", saveOrder);
  }
  async function saveOrder() {
    const b = $("#dSave"), m = $("#dMsg");
    const status = $("#dStatus").value, note = $("#dNote").value;
    b.disabled = true; m.textContent = "";
    try {
      await api.update(current.id, status !== current.status ? status : null, note !== (current.admin_note || "") ? note : null);
      current.status = status; current.admin_note = note;
      m.textContent = "已儲存";
      load(true);
    } catch (e) { m.textContent = msg(e); }
    b.disabled = false;
  }
  function closeSheet() { $("#sheet").hidden = $("#sheetBg").hidden = true; current = null; $("#dBody").innerHTML = ""; if (lastFocus) lastFocus.focus(); }
  $("#sheetClose").addEventListener("click", closeSheet);
  $("#sheetBg").addEventListener("click", closeSheet);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("#sheet").hidden) closeSheet(); });

  // 分頁：訂單 / 操作紀錄
  document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((x) => { x.classList.toggle("on", x === t); x.setAttribute("aria-selected", x === t); });
    $("#paneOrders").hidden = t.dataset.tab !== "orders";
    $("#paneAudit").hidden = t.dataset.tab !== "audit";
    $("#paneProducts").hidden = t.dataset.tab !== "products";
    $("#paneStaff").hidden = t.dataset.tab !== "staff";
    if (t.dataset.tab === "staff") loadStaff();
    if (t.dataset.tab === "audit") loadAudit();
    if (t.dataset.tab === "products") { loadProducts(); loadPromo(); }
  }));
  const ACTION = { create_staff: "新增員工", update_staff: "修改員工", remove_staff: "移除員工", reset_staff_password: "重設員工密碼", staff_password_set: "員工設定新密碼", update_promo: "修改促銷活動", view_order: "查看訂單個資", update_order: "更新訂單", purge_pii: "清除舊個資", create_product: "新增商品", update_product: "修改商品" };
  async function loadAudit() {
    $("#auditList").innerHTML = `<li class="muted">載入中…</li>`;
    try {
      const rows = await api.audit();
      $("#auditList").innerHTML = rows.length ? rows.map((r) => {
        const d = r.detail || {};
        const extra = r.action === "update_order" ? `${STATUS_NAME[d.from] || d.from || ""} → ${STATUS_NAME[d.to] || d.to || ""}` : r.action === "purge_pii" ? `清除 ${d.rows} 筆` : /staff/.test(r.action) ? `${d.email || ""}${d.role ? `（${d.role_from && d.role_from !== d.role ? (d.role_from === "owner" ? "店長" : "員工") + " → " : ""}${d.role === "owner" ? "店長" : "員工"}）` : ""}${d.active === false && d.active_from !== false ? " 停用" : d.active === true && d.active_from === false ? " 啟用" : ""}` : r.action === "update_promo" ? `${d.enabled ? "開啟" : "關閉"}・${d.pay_percent ? zhe(d.pay_percent) : ""}${d.name ? "・" + d.name : ""}` : /product/.test(r.action) ? `${d.name || d.product || ""}${d.price_from != null && d.price_from !== d.price_to ? `（${fmt(d.price_from)} → ${fmt(d.price_to)}）` : ""}` : (d.order_no || "");
        return `<li><time>${esc(new Date(r.at).toLocaleString("zh-TW", { timeZone: "Asia/Taipei", hour12: false }))}</time><span><b>${esc(r.actor_email || "系統排程")}</b> ${esc(ACTION[r.action] || r.action)} ${esc(extra)}</span></li>`;
      }).join("") : `<li class="muted">還沒有紀錄</li>`;
    } catch (e) { $("#auditList").innerHTML = `<li class="err">${esc(msg(e))}</li>`; }
  }
  $("#purgeBtn").addEventListener("click", () => { $("#purgeConfirm").hidden = false; });
  $("#purgeNo").addEventListener("click", () => { $("#purgeConfirm").hidden = true; });
  $("#purgeYes").addEventListener("click", async () => {
    const days = Math.max(30, parseInt($("#purgeDays").value, 10) || 180);
    $("#purgeConfirm").hidden = true;
    try { const n = await api.purge(days); $("#purgeMsg").textContent = `已清除 ${n} 筆訂單的個資。`; loadAudit(); }
    catch (e) { $("#purgeMsg").textContent = msg(e); }
  });

  // ------------------------------------------------------------------
  // 商品管理（店長）
  // ------------------------------------------------------------------
  let products = [];
  const PERR = { invalid_id: "商品代號只能用小寫英文、數字、- 或 _（2～40 字）。", invalid_name: "請填寫商品名稱（40 字以內）。", invalid_spec: "請填寫規格（40 字以內）。", invalid_price: "價格請填 0～100000 的整數。", invalid_sale: "特價要低於原價。", invalid_image: "圖片網址不正確，請重新上傳。", owner_only: "只有店長帳號可以修改商品。" };
  const pmsg = (e) => { const m = (e && e.message) || ""; for (const k in PERR) if (m.includes(k)) return PERR[k]; return msg(e); };

  async function loadProducts() {
    $("#productList").innerHTML = `<li class="muted">載入中…</li>`;
    try {
      products = await api.products();
      $("#productList").innerHTML = products.length ? products.map((p) => `
        <li><button type="button" class="prod${p.active ? "" : " off"}" data-pid="${esc(p.id)}">
          ${p.image_url ? `<img src="${esc(p.image_url)}" alt="">` : `<span class="noimg">無圖片</span>`}
          <span><span class="pn">${esc(p.name)}</span><br><span class="ps">${esc(p.spec)}${p.tag ? "・" + esc(p.tag) : ""}</span></span>
          <span class="pp">${p.sale_price != null ? `<span class="strike">${fmt(p.price)}</span>${fmt(p.sale_price)}` : fmt(p.price)}<br><span class="pill ${p.active ? "on" : "off"}">${p.active ? "上架中" : "已下架"}</span></span>
        </button></li>`).join("") : `<li class="empty">還沒有商品</li>`;
    } catch (e) { $("#productList").innerHTML = `<li class="err">${esc(msg(e))}</li>`; }
  }
  $("#productList").addEventListener("click", (e) => { const b = e.target.closest(".prod"); if (b) openProduct(products.find((x) => x.id === b.dataset.pid)); });
  $("#newProductBtn").addEventListener("click", () => openProduct(null));

  // 縮圖並轉成 WebP：檔案變小，也會去掉照片裡的 GPS 等資訊
  function toWebp(file, max) {
    return new Promise((resolve, reject) => {
      const img = new Image(), url = URL.createObjectURL(file);
      img.onload = () => {
        const k = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas");
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        c.toBlob((b) => (b ? resolve(b) : reject(new Error("圖片轉換失敗"))), "image/webp", 0.85);
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("無法讀取這張圖片，請改用 JPG 或 PNG。")); };
      img.src = url;
    });
  }

  function openProduct(p) {
    const isNew = !p;
    p = p || { id: "", name: "", spec: "", price: "", active: true, sort: (products.reduce((a, x) => Math.max(a, x.sort || 0), 0) + 1), tag: "", description: "", image_url: null };
    let imageUrl = p.image_url, pendingBlob = null;
    lastFocus = document.activeElement;
    $("#dNo").textContent = isNew ? "新增商品" : p.name;
    $("#sheet").hidden = $("#sheetBg").hidden = false;
    $("#dBody").innerHTML = `
      <div class="imgbox">
        <span id="pImgWrap"></span>
        <div class="imgbtns">
          <label class="btn mini" for="pFile">選擇圖片</label>
          <input class="vh" id="pFile" type="file" accept="image/jpeg,image/png,image/webp">
          <button class="btn mini" type="button" id="pImgRemove">移除圖片</button>
        </div>
        <p class="muted small">建議正方形照片，會自動縮小到 1200px 並轉成 WebP。</p>
      </div>
      <label for="pName">商品名稱</label><input id="pName" maxlength="40" value="${esc(p.name)}">
      <div class="row2">
        <div><label for="pSpec">規格</label><input id="pSpec" maxlength="40" value="${esc(p.spec)}" placeholder="例：單包 100g"></div>
        <div><label for="pPrice">價格（NT$）</label><input id="pPrice" type="number" inputmode="numeric" min="0" max="100000" step="1" value="${esc(p.price)}"></div>
      </div>
      <label for="pSale">特價（NT$，選填；留空＝不特價。有特價就不再套全館折扣）</label><input id="pSale" type="number" inputmode="numeric" min="0" max="100000" step="1" value="${p.sale_price == null ? "" : esc(p.sale_price)}" placeholder="例：300">
      <div class="row2">
        <div><label for="pTag">標籤（選填）</label><input id="pTag" maxlength="10" value="${esc(p.tag || "")}" placeholder="例：人氣"></div>
        <div><label for="pSort">排序（小的在前）</label><input id="pSort" type="number" inputmode="numeric" value="${esc(p.sort || 0)}"></div>
      </div>
      <label for="pDesc">商品說明（300 字以內）</label><textarea id="pDesc" maxlength="300">${esc(p.description || "")}</textarea>
      ${isNew ? `<label for="pId">商品代號（英文，建立後不能改）</label><input id="pId" maxlength="40" placeholder="例：spicy-100g" autocapitalize="off">` : ""}
      <label class="check"><input type="checkbox" id="pActive"${p.active ? " checked" : ""}> 上架（顧客看得到、可以下單）</label>
      <button class="btn primary" type="button" id="pSave">${isNew ? "建立商品" : "儲存"}</button>
      <p class="save-msg" id="pMsg" role="status"></p>`;
    const renderImg = () => { $("#pImgWrap").innerHTML = imageUrl ? `<img src="${esc(imageUrl)}" alt="商品圖片預覽">` : `<span class="noimg">尚未上傳圖片</span>`; $("#pImgRemove").hidden = !imageUrl; };
    renderImg();
    $("#pFile").addEventListener("change", async (e) => {
      const f = e.target.files[0]; if (!f) return;
      $("#pMsg").textContent = "處理圖片中…";
      try { pendingBlob = await toWebp(f, 1200); if (pendingBlob.size > 2 * 1024 * 1024) throw new Error("圖片太大，請換一張。"); imageUrl = URL.createObjectURL(pendingBlob); renderImg(); $("#pMsg").textContent = "圖片會在按「儲存」時上傳。"; }
      catch (err) { pendingBlob = null; $("#pMsg").textContent = err.message; }
    });
    $("#pImgRemove").addEventListener("click", () => { imageUrl = null; pendingBlob = null; renderImg(); });
    $("#pSave").addEventListener("click", async () => {
      const b = $("#pSave"), m = $("#pMsg");
      const id = isNew ? $("#pId").value.trim().toLowerCase() : p.id;
      const row = { id, name: $("#pName").value.trim(), spec: $("#pSpec").value.trim(), price: $("#pPrice").value, sale_price: $("#pSale").value.trim(), sort: parseInt($("#pSort").value, 10) || 0,
        tag: $("#pTag").value.trim(), description: $("#pDesc").value.trim(), active: $("#pActive").checked, image_url: imageUrl };
      if (isNew && products.some((x) => x.id === id)) { m.textContent = "這個商品代號已經有人用了。"; return; }
      b.disabled = true; m.textContent = "儲存中…";
      try {
        if (pendingBlob) { m.textContent = "上傳圖片中…"; row.image_url = await api.uploadImage(pendingBlob); pendingBlob = null; imageUrl = row.image_url; }
        await api.saveProduct(row);
        m.textContent = "已儲存，前台已更新。";
        $("#dNo").textContent = row.name;
        loadProducts();
        if (isNew) setTimeout(closeSheet, 700);
      } catch (e) { m.textContent = pmsg(e); }
      b.disabled = false;
    });
    setTimeout(() => $("#pName").focus(), 50);
  }

  // ------------------------------------------------------------------
  // 促銷活動（店長）
  // ------------------------------------------------------------------
  function zhe(pct) { return (pct % 10 ? String(pct) : String(pct / 10)) + " 折"; }
  const toLocal = (iso) => { if (!iso) return ""; const d = new Date(iso); const z = (n) => String(n).padStart(2, "0"); return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}T${z(d.getHours())}:${z(d.getMinutes())}`; };
  const PROMO_ERR = { invalid_percent: "折數不正確。", invalid_dates: "結束時間要晚於開始時間。", invalid_promo_name: "標語請在 30 字以內。", owner_only: "只有店長帳號可以修改活動。" };
  $("#promoPct").innerHTML = [95, 90, 88, 85, 80, 75, 70, 65, 60, 50].map((v) => `<option value="${v}">${zhe(v)}（付 ${v}%）</option>`).join("");
  let promoFree = 1200;
  function promoExample() { const v = +$("#promoPct").value; $("#promoEx").textContent = `原價 NT$170 → NT$${Math.round(170 * v / 100)}；折扣後滿 ${fmt(promoFree)} 免運`; }
  $("#promoPct").addEventListener("change", promoExample);
  function showLive(live) { const el = $("#promoLive"); el.className = "pill " + (live && live.active ? "on" : "off"); el.textContent = live && live.active ? "進行中" : "未生效"; }
  async function loadPromo() {
    try {
      const p = await api.getPromo();
      promoFree = p.free_shipping_threshold || 1200;
      $("#promoOn").checked = !!p.enabled;
      $("#promoName").value = p.name || "";
      const pct = +p.pay_percent || 70;
      if (![...$("#promoPct").options].some((o) => +o.value === pct)) $("#promoPct").insertAdjacentHTML("beforeend", `<option value="${pct}">${zhe(pct)}（付 ${pct}%）</option>`);
      $("#promoPct").value = String(pct);
      $("#promoStart").value = toLocal(p.start_at); $("#promoEnd").value = toLocal(p.end_at);
      showLive(p.live); promoExample();
      $("#promoNote").textContent = "折扣在顧客下單時由系統計算；免運門檻以折扣後的商品金額判斷。過了結束時間會自動停止。";
    } catch (e) { $("#promoMsg").textContent = msg(e); }
  }
  $("#promoSave").addEventListener("click", async () => {
    const b = $("#promoSave"), m = $("#promoMsg");
    const s = $("#promoStart").value, e = $("#promoEnd").value;
    const row = { enabled: $("#promoOn").checked, name: $("#promoName").value.trim(), pay_percent: +$("#promoPct").value,
      start_at: s ? new Date(s).toISOString() : null, end_at: e ? new Date(e).toISOString() : null };
    if (row.start_at && row.end_at && row.end_at <= row.start_at) { m.textContent = PROMO_ERR.invalid_dates; return; }
    b.disabled = true; m.textContent = "儲存中…";
    try { const p = await api.setPromo(row); showLive(p.live); m.textContent = p.live && p.live.active ? "已儲存，活動進行中，前台已顯示折扣。" : "已儲存，活動目前未生效。"; }
    catch (err) { const k = Object.keys(PROMO_ERR).find((x) => (err.message || "").includes(x)); m.textContent = k ? PROMO_ERR[k] : msg(err); }
    b.disabled = false;
  });

  // ------------------------------------------------------------------
  // 員工帳號（店長）
  // ------------------------------------------------------------------
  const STAFF_ERR = {
    email_exists: "這個 Email 已經有登入帳號了（可能是同一個 Supabase 專案的其他使用者）。請換一個 Email。",
    invalid_email: "Email 格式不正確。", weak_password: "密碼至少 12 個字元，且要有英文大寫、小寫和數字。",
    staff_exists: "這個帳號已經在員工名單裡。", staff_not_found: "找不到這位員工。",
    cannot_change_self: "不能修改自己的帳號（避免把自己鎖在外面）。", owner_only: "只有店長可以管理員工。",
    forbidden_origin: "請從正式網址開啟後台再操作。", not_authorized: "登入已過期，請重新登入。",
    function_missing: "還沒有部署「shop-staff」Edge Function，請依說明完成設定。"
  };
  const smsg = (e) => { const m = (e && e.message) || String(e); for (const k in STAFF_ERR) if (m.includes(k)) return STAFF_ERR[k]; return msg(e); };
  const ROLE_NAME = { owner: "店長", staff: "員工" };
  function genPassword() {
    const sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789"], all = sets.join("");
    const rnd = (n) => { const a = new Uint32Array(1); crypto.getRandomValues(a); return a[0] % n; };
    const out = sets.map((s) => s[rnd(s.length)]);
    while (out.length < 14) out.push(all[rnd(all.length)]);
    for (let i = out.length - 1; i > 0; i--) { const j = rnd(i + 1); [out[i], out[j]] = [out[j], out[i]]; }
    return out.join("");
  }
  const strong = (p) => p.length >= 12 && /[a-z]/.test(p) && /[A-Z]/.test(p) && /\d/.test(p);
  let staff = [];
  async function loadStaff() {
    const ul = $("#staffList");
    ul.innerHTML = `<li class="muted">載入中…</li>`;
    try {
      staff = await api.listStaff();
      ul.innerHTML = staff.map((s) => {
        const tags = [
          `<span class="pill ${s.role === "owner" ? "confirmed" : "pending"}">${ROLE_NAME[s.role]}</span>`,
          !s.active ? `<span class="pill cancelled">已停用</span>` : "",
          s.must_change_password ? `<span class="pill shipped">等待首次登入改密碼</span>` : "",
          s.active && !s.mfa ? `<span class="pill cancelled">尚未綁兩步驟驗證</span>` : ""
        ].join(" ");
        const acts = s.is_me ? `<p class="muted small">這是你自己的帳號</p>` : `
          <div class="srow">
            <select data-act="role" data-uid="${esc(s.user_id)}" aria-label="角色"><option value="staff"${s.role === "staff" ? " selected" : ""}>員工</option><option value="owner"${s.role === "owner" ? " selected" : ""}>店長</option></select>
            <button class="btn mini" type="button" data-act="toggle" data-uid="${esc(s.user_id)}">${s.active ? "停用" : "啟用"}</button>
            <button class="btn mini" type="button" data-act="reset" data-uid="${esc(s.user_id)}">重設密碼</button>
            <button class="btn mini danger" type="button" data-act="remove" data-uid="${esc(s.user_id)}">移除</button>
          </div>
          <div class="sconfirm" id="sc-${esc(s.user_id)}" hidden></div>`;
        return `<li class="staff${s.active ? "" : " off"}"><div class="sh"><b>${esc(s.email)}</b> ${tags}</div>
          <p class="muted small">建立於 ${esc(when(s.created_at))}${s.last_sign_in_at ? `・最後登入 ${esc(when(s.last_sign_in_at))}` : "・還沒登入過"}</p>${acts}
          <p class="save-msg" id="sm-${esc(s.user_id)}" role="status"></p></li>`;
      }).join("") || `<li class="muted">還沒有員工</li>`;
    } catch (e) { ul.innerHTML = `<li class="err">${esc(smsg(e))}</li>`; }
  }
  $("#sGen").addEventListener("click", () => { $("#sPw").value = genPassword(); $("#sPw").type = "text"; });
  $("#staffForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = $("#sEmail").value.trim(), role = $("#sRole").value, pw = $("#sPw").value, m = $("#sMsg");
    m.className = "save-msg"; m.textContent = "";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { m.className = "err"; m.textContent = STAFF_ERR.invalid_email; return; }
    if (!strong(pw)) { m.className = "err"; m.textContent = STAFF_ERR.weak_password; return; }
    busy(e.target, true); m.textContent = "建立中…";
    try {
      await api.createStaff(email, pw, role);
      $("#staffForm").reset(); $("#sPw").type = "password";
      m.innerHTML = `已建立 <b>${esc(email)}</b>。請把 Email 和初始密碼私下交給對方（不要貼在群組）。對方第一次登入會先綁兩步驟驗證，再改成自己的密碼。`;
      loadStaff();
    } catch (err) { m.className = "err"; m.textContent = smsg(err); }
    busy(e.target, false);
  });
  $("#staffList").addEventListener("change", async (e) => {
    const sel = e.target.closest('select[data-act="role"]'); if (!sel) return;
    const uid = sel.dataset.uid, m = $("#sm-" + uid);
    sel.disabled = true; m.className = "save-msg"; m.textContent = "儲存中…";
    try { await api.updateStaff(uid, sel.value, null); m.textContent = `已改為${ROLE_NAME[sel.value]}。`; setTimeout(loadStaff, 900); }
    catch (err) { m.className = "err"; m.textContent = smsg(err); sel.disabled = false; }
  });
  $("#staffList").addEventListener("click", async (e) => {
    const b = e.target.closest("button[data-act]"); if (!b) return;
    const uid = b.dataset.uid, s = staff.find((x) => x.user_id === uid), m = $("#sm-" + uid), box = $("#sc-" + uid);
    if (!s) return;
    m.className = "save-msg"; m.textContent = "";
    if (b.dataset.act === "toggle") {
      b.disabled = true;
      try { await api.updateStaff(uid, null, !s.active); loadStaff(); } catch (err) { m.className = "err"; m.textContent = smsg(err); b.disabled = false; }
    } else if (b.dataset.act === "remove") {
      box.hidden = false;
      box.innerHTML = `<p>確定要把 ${esc(s.email)} 從員工名單移除嗎？移除後立即無法登入後台。</p><button class="btn danger mini" type="button" data-act="removeYes" data-uid="${esc(uid)}">確定移除</button> <button class="btn mini" type="button" data-act="cancel" data-uid="${esc(uid)}">取消</button>`;
    } else if (b.dataset.act === "removeYes") {
      b.disabled = true;
      try { await api.removeStaff(uid); loadStaff(); } catch (err) { m.className = "err"; m.textContent = smsg(err); b.disabled = false; }
    } else if (b.dataset.act === "reset") {
      const pw = genPassword();
      box.hidden = false;
      box.innerHTML = `<p>新的初始密碼（可修改）：</p><input class="rpw" id="rp-${esc(uid)}" value="${esc(pw)}" autocomplete="off" spellcheck="false"><p class="muted small">對方下次登入後要再改成自己的密碼。</p><button class="btn primary mini" type="button" data-act="resetYes" data-uid="${esc(uid)}">確定重設</button> <button class="btn mini" type="button" data-act="cancel" data-uid="${esc(uid)}">取消</button>`;
    } else if (b.dataset.act === "resetYes") {
      const pw = $("#rp-" + uid).value;
      if (!strong(pw)) { m.className = "err"; m.textContent = STAFF_ERR.weak_password; return; }
      b.disabled = true; m.textContent = "重設中…";
      try { await api.resetStaffPw(uid, pw); box.hidden = true; box.innerHTML = ""; m.innerHTML = `已重設。請把新密碼私下交給 ${esc(s.email)}。`; }
      catch (err) { m.className = "err"; m.textContent = smsg(err); b.disabled = false; }
    } else if (b.dataset.act === "cancel") { box.hidden = true; box.innerHTML = ""; }
  });

  route();
})();
