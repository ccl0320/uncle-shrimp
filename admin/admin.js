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
  let sb = null, api, me = null, recovering = false, enrollFactorId = null;

  if (!DEMO) {
    if (!window.supabase) { document.body.textContent = "無法載入登入元件，請檢查網路後重新整理。"; return; }
    sb = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
      db: { schema: "shop" },
      auth: { storage: window.sessionStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    const rpc = async (fn, args) => { const { data, error } = await sb.rpc(fn, args || {}); if (error) throw error; return data; };
    api = {
      whoami: () => rpc("admin_whoami"),
      list: (status, search, offset) => rpc("admin_list_orders", { p_status: status, p_search: search, p_limit: PAGE, p_offset: offset }),
      get: (id) => rpc("admin_get_order", { p_id: id }),
      update: (id, status, note) => rpc("admin_update_order", { p_id: id, p_status: status, p_admin_note: note }),
      audit: () => rpc("admin_audit_log", { p_limit: 200 }),
      purge: (days) => rpc("purge_old_pii", { p_days: days })
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
      const sub = d[4].reduce((a, x) => a + x[2] * x[3], 0), fee = sub >= 1200 ? 0 : ({ home: 150, cvs: 70, pickup: 0 })[d[2]];
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
      purge: () => wait(0)
    };
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
    if (!me || !me.role) { show("vDenied"); return; }
    $("#who").textContent = me.email + (me.role === "owner" ? "（店長）" : "（員工）");
    $("#who").hidden = $("#logoutBtn").hidden = false;
    $("#auditTab").hidden = me.role !== "owner";
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
        ${o.items.map((it) => `<tr><td>${esc(it.name)}<br><span class="muted small">${esc(it.spec)}・${fmt(it.unit_price)} × ${esc(it.qty)}</span></td><td>${fmt(it.unit_price * it.qty)}</td></tr>`).join("")}
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
    if (t.dataset.tab === "audit") loadAudit();
  }));
  const ACTION = { view_order: "查看訂單個資", update_order: "更新訂單", purge_pii: "清除舊個資" };
  async function loadAudit() {
    $("#auditList").innerHTML = `<li class="muted">載入中…</li>`;
    try {
      const rows = await api.audit();
      $("#auditList").innerHTML = rows.length ? rows.map((r) => {
        const d = r.detail || {};
        const extra = r.action === "update_order" ? `${STATUS_NAME[d.from] || d.from || ""} → ${STATUS_NAME[d.to] || d.to || ""}` : r.action === "purge_pii" ? `清除 ${d.rows} 筆` : (d.order_no || "");
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

  route();
})();
