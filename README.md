# 舅是好蝦 Uncle’s Shrimp Chips

手工炸蝦餅品牌網站、LINE 訂購與訂單後台。前台放在 GitHub Pages，訂單存在 Supabase（PostgreSQL）。

| 頁面 | 網址 |
|---|---|
| 前台（顧客下單） | `https://ccl0320.github.io/uncle-shrimp/` |
| 訂單後台 | `https://ccl0320.github.io/uncle-shrimp/admin/` |

還沒設定 Supabase 時：前台只走 LINE 傳送，後台會以「示範模式」顯示假資料。

## 檔案
- `index.html`：前台（由 `src/template.html` 產生，改內容請改 template 後執行 `python3 src/build.py`）
- `config.js`：Supabase 網址與公開金鑰
- `admin/`：訂單後台
- `supabase/schema.sql`：資料表、權限規則、下單與後台函式

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
   - Site URL：`https://ccl0320.github.io/uncle-shrimp/admin/`
   - Redirect URLs 加入：`https://ccl0320.github.io/uncle-shrimp/admin/`
4. **Rate Limits**：保留預設即可（登入失敗過多會被限制）。
5. 付費方案另有「Leaked password protection（擋掉外洩過的密碼）」與「Session 閒置逾時」，營運後可考慮開啟。

## 三、新增管理員帳號
1. **Authentication → Users → Add user → Send invitation**，輸入管理員 Email。對方會收到信，點連結設定密碼。
2. 到 **SQL Editor** 執行（把 Email 換成實際的）：
   ```sql
   insert into public.admin_users (user_id, email, role)
   select id, email, 'owner' from auth.users where email = 'owner@example.com';
   -- 員工帳號把 'owner' 改成 'staff'
   ```
3. 管理員第一次登入後台時，會要求用 Google Authenticator 等 App 掃 QR Code 綁定兩步驟驗證。

**停用帳號**：`delete from public.admin_users where email = '…';`，並在 Authentication → Users 刪除該使用者。
**手機遺失**：在 Authentication → Users 點該使用者 → 移除 MFA factor，對方下次登入會重新綁定。

### 權限
| | 店長 owner | 員工 staff |
|---|---|---|
| 看訂單列表（姓名、電話遮罩） | ✓ | ✓ |
| 看單筆完整個資（會被記錄） | ✓ | ✓ |
| 改訂單狀態、內部備註（會被記錄） | ✓ | ✓ |
| 看操作紀錄 | ✓ | |
| 清除舊訂單個資 | ✓ | |

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

## 修改商品與運費
- 價格以資料庫為準：Supabase **Table Editor → products / shipping_methods / shop_settings** 直接改，前台會自動顯示新價格。
- 新增商品時，`src/template.html` 的 `PRODUCTS` 也要加上同樣的 `id`（用來顯示圖片與說明）。

## 付款
目前只開放貨到付款／取貨付款／自取付現，線上金流之後再串接。
