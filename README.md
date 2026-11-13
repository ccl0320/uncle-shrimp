# 舅是好蝦 Uncle’s Shrimp Chips

手工炸蝦餅品牌網站、LINE 訂購與訂單後台。正式網站放在 Cloudflare Pages（GitHub repo 只當原始碼），訂單存在 Supabase（PostgreSQL）。

| 頁面 | 網址 |
|---|---|
| 前台（顧客下單） | `https://uncle-shrimp.pages.dev/` |
| 訂單後台 | `https://uncle-shrimp.pages.dev/admin/` |

還沒設定 Supabase 時：前台只走 LINE 傳送，後台會以「示範模式」顯示假資料。

## 檔案
- `index.html`：前台（由 `src/template.html` 產生，改內容請改 template 後執行 `python3 src/build.py`）
- `config.js`：Supabase 網址與公開金鑰
- `admin/`：訂單後台
- `supabase/schema.sql`：資料表、權限規則、下單與後台函式
- `supabase/002_products_admin.sql`、`003_promotions.sql`、`004_sale_price.sql`、`005_copy.sql`、`006_staff.sql`、`007_qty_limit.sql`、`008_shipping.sql`：之後加上的功能，依序在 SQL Editor 執行（可重複執行）

## 部署：Cloudflare Pages
1. Cloudflare → **Workers & Pages → Create → Pages → Connect to Git**，授權 GitHub 後選 `uncle-shrimp` repo。
2. 建置設定：
   - Production branch：`main`
   - Framework preset：None
   - Build command：`python3 src/build.py --dist`
   - Build output directory：`dist`
3. 按 **Save and Deploy**。之後每次推到 main 都會自動部署。網址是 `https://uncle-shrimp.pages.dev`（名稱被用走的話會不同，以畫面為準）。
4. `dist/` 只放公開需要的檔案（前台、後台、圖片、config.js），原始碼、SQL、README 不會被放上網站。
5. 安全標頭在 `_headers`（由 build.py 自動產生，含前台的 Content-Security-Policy）。

換網址後要一起改：
- Supabase → Authentication → URL Configuration：Site URL、Redirect URLs 改成新網址的 `/admin/`
- Edge Function `shop-staff`：若不是 `uncle-shrimp.pages.dev`，在 Edge Functions → Secrets 新增 `ALLOWED_ORIGINS`
- LINE LIFF 的 Endpoint URL
- 停用 GitHub Pages：repo → Settings → Pages → Source 選 None（或 Unpublish）。之後 repo 也可以改成 Private，Cloudflare 照樣能部署。

## 一、建立 Supabase 訂單資料庫
目前和 melissa-island 共用同一個 Supabase 專案。訂單資料全部放在獨立的 `shop` schema，和小島的 `public.island_docs` 互不影響。

1. 打開 melissa-island 用的 Supabase 專案，左側 **SQL Editor** → New query → 貼上 `supabase/schema.sql` 全部內容 → Run（重複執行也安全）。
2. **Project Settings → Data API**（或 API）→ **Exposed schemas** 加入 `shop` → Save。
3. **Project Settings → API Keys**：複製 `Project URL` 和 **Legacy anon key**（`eyJ` 開頭），填到 `config.js`。
   - ⚠️ `service_role` / secret key 絕對不能放進網站或傳給別人。

> 營運正式上線、訂單量變多後，建議把 `shop` 搬到獨立的 Supabase 專案：個資和其他網站分開備份、分開管理權限。搬移時只要在新專案執行同一份 schema.sql，再改 `config.js`。

## 二、帳號安全設定（Authentication）
1. **Sign In / Providers → Email**：
   - 關閉 **Allow new users to sign up**（只能由店長邀請，外人無法自己註冊）
   - 開啟 **Confirm email**
   - Minimum password length 設 **12**，Password requirements 選「小寫、大寫、數字」
2. **Multi-Factor**：確認 **TOTP** 為啟用（後台會強制每個管理員綁定驗證 App）。
3. **URL Configuration**：
   - Site URL：`https://uncle-shrimp.pages.dev/admin/`
   - Redirect URLs 加入：`https://uncle-shrimp.pages.dev/admin/`
4. **Rate Limits**：保留預設即可（登入失敗過多會被限制）。
5. 付費方案另有「Leaked password protection（擋掉外洩過的密碼）」與「Session 閒置逾時」，營運後可考慮開啟。

## 三、管理員與員工帳號
**第一個店長帳號**（只需做一次，已完成）：Authentication → Users 建立使用者後，到 SQL Editor 執行
```sql
insert into shop.admin_users (user_id, email, role)
select id, email, 'owner' from auth.users where email = 'owner@example.com';
```

**之後新增員工：直接在後台「員工」分頁操作**（只有店長看得到）。需要先完成一次設定：
1. SQL Editor 執行 `supabase/006_staff.sql`。
2. 部署 Edge Function：Supabase 左側 **Edge Functions → Deploy a new function → Via Editor**，名稱填 `shop-staff`，把 `supabase/functions/shop-staff/index.ts` 的內容整份貼上取代範例程式，按 **Deploy**。「Verify JWT」保持開啟。
   - 不需要另外設定任何金鑰：函式會自動取得 Supabase 管理金鑰，金鑰只存在伺服器端，不會出現在網頁上。

使用方式：
- 店長在「員工」分頁輸入 Email、選角色、按「產生安全密碼」→「建立帳號」，再把帳密**私下**交給對方。
- 員工第一次登入：先用驗證 App 綁兩步驟驗證，再強制改成自己的密碼（資料庫會檢查密碼真的換過），改好之前看不到任何資料。
- 可以改角色、停用／啟用、重設密碼、移除，全部立即生效並寫入操作紀錄。不能修改自己的帳號，避免把自己鎖在外面。
- 不寄任何信，不受 Supabase 免費寄信額度限制。
- 因為和 melissa-island 共用 Supabase 專案，如果 Email 已經是該專案的使用者，會提示「已經有登入帳號」，請換一個 Email。

**手機遺失**：Authentication → Users 點該使用者 → 移除 MFA factor，對方下次登入會重新綁定。

### 權限
| | 店長 owner | 員工 staff |
|---|---|---|
| 看訂單列表（姓名、電話遮罩） | ✓ | ✓ |
| 看單筆完整個資（會被記錄） | ✓ | ✓ |
| 改訂單狀態、內部備註（會被記錄） | ✓ | ✓ |
| 看操作紀錄 | ✓ | |
| 清除舊訂單個資 | ✓ | |
| 管理商品、上傳圖片 | ✓ | |
| 管理促銷活動 | ✓ | |
| 新增／停用／移除員工 | ✓ | |

## 四、資安設計
- **顧客端只能下單**：未登入只能呼叫 `place_order`，不能讀任何訂單；價格與運費由資料庫計算，前端改價無效；同一支手機每小時最多 5 筆，防止灌單。
- **後台三道關卡**：登入密碼 → 兩步驟驗證（TOTP）→ 必須在 `admin_users` 名單內。三者缺一，資料庫就拒絕回傳資料（不是只靠前端擋）。
- **最小揭露**：列表的姓名、電話會遮罩，點進單筆才看得到完整資料，而且每次查看都寫入操作紀錄。
- **Session**：登入狀態存在 sessionStorage（關掉分頁就登出），15 分鐘沒操作自動登出。
- **防 XSS**：顧客輸入的內容一律以純文字顯示；後台頁面設定 CSP、noindex、no-referrer。
- **個資保存期限**：已完成／取消的訂單，可在後台「操作紀錄」頁清除超過 N 天的個資（預設 180 天，最少 30 天）；也可用 pg_cron 每日自動執行（見 schema.sql 最後）。
- **備份**：Supabase 免費方案每日備份保留 7 天；營運量大時建議升級或定期匯出。

## 五、LINE 官方帳號＋LIFF
`index.html` 的 `<script>` 開頭：
- `LINE_OA`：LINE 官方帳號 ID（例：`"@unclesshrimp"`）
- `LIFF_ID`：LIFF App ID

設定步驟：
1. 到 LINE Official Account Manager 建立官方帳號，記下帳號 ID（@開頭）。
2. 到 LINE Developers Console 建立 Provider，再建立一個 **LINE Login channel**。
3. 在該 channel 的 LIFF 分頁新增 LIFF app：Size 選 Full，Endpoint URL 填前台網址，Scopes 勾 `chat_message.write`、`profile`。
4. 把 LIFF ID 與官方帳號 ID 填進 `src/template.html`，執行 `python3 src/build.py`。
5. 在官方帳號後台設定圖文選單，按鈕連結填 `https://liff.line.me/<LIFF_ID>`。

訂單流程：顧客送出 → 寫入資料庫（取得正式訂單編號）→ 在 LINE 內直接把訂單傳到官方帳號聊天室（或在一般瀏覽器開啟 LINE 帶入訂單）。

## 修改商品
- 店長登入後台 → **商品** 分頁：可改名稱、規格、價格、標籤、說明、排序、上下架，上傳商品圖片，或新增商品。存檔後前台立即更新。
- 需先在 Supabase SQL Editor 執行 `supabase/002_products_admin.sql`（建立圖片儲存空間與權限，只有店長能上傳）。
- 運費與免運門檻：後台 **商品 → 運費設定**（需先執行 `supabase/008_shipping.sql`）。可改各取貨方式的名稱、運費、說明、開放／關閉與免運門檻，修改會記在操作紀錄。

## 促銷活動
- 需先在 Supabase SQL Editor 執行 `supabase/003_promotions.sql`。
- 店長登入後台 → **商品** 分頁最上方的「促銷活動」：開關活動、設定折數（例如 7 折＝付 70%）、活動標語、開始與結束時間。結束時間一到自動停止。
- 前台會顯示活動橫幅、原價劃線與折扣價；購物車與 LINE 訂單會列出原價小計與折抵金額。
- 實際金額一律由資料庫在下單時計算（每件單價＝原價×折數，四捨五入到元），前端改價無效。
- **免運門檻以折扣後的商品金額判斷**。
- 每次修改都會記在「操作紀錄」。

## 單品特價
- 需先在 Supabase SQL Editor 執行 `supabase/004_sale_price.sql`（同時套用新定價：單包 $100、三入組 $260，滿 $520 免運，關閉全館折扣，家庭分享包下架）。
- 後台 → 商品 → 點商品 → 「特價」欄填金額（要低於原價），留空＝不特價。
- 有特價的商品以特價計算，**不再疊加全館折扣**；其他商品照全館折扣。

## 接單上限
- 需先在 SQL Editor 執行 `supabase/007_qty_limit.sql`。
- 每個品項一次最多 10 件；每週最多接 200 包（三入組算 3 包），**每週一 00:00（台北時間）起算**，已取消的訂單不計。
- 前台會顯示「本週還可接單 N 包」，額滿時無法加入購物車；資料庫下單時再檢查一次（同時下單會排隊，不會超賣）。
- 店長在後台 **商品 → 接單上限** 調整；每個商品算幾包在商品編輯的「包數」設定。

## 付款
目前只開放貨到付款／取貨付款／自取付現，線上金流之後再串接。
