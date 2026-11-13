# 舅是好蝦 Uncle’s Shrimp Chips

手工炸蝦餅品牌與 LINE 訂購網站（純靜態網頁，可放在 GitHub Pages）。

## 修改商品、運費、付款方式
都在 `index.html` 的 `<script>` 開頭：

- `PRODUCTS`：品項、規格、價格、說明
- `SHIP`：取貨方式與運費；`FREE`：免運門檻
- `PAY`：付款方式
- `LINE_OA`：LINE 官方帳號 ID（例：`"@unclesshrimp"`）
- `LIFF_ID`：LIFF App ID

## 訂單怎麼送到店家
1. **在 LINE 裡開啟（LIFF）**：填好 `LIFF_ID` 後，顧客從官方帳號圖文選單打開此頁，按「確認並送出訂單」會用 `liff.sendMessages` 把訂單直接傳到官方帳號聊天室，並自動帶入 LINE 名稱。
2. **一般瀏覽器開啟**：送出後按「開啟 LINE 傳送訂單」，訂單內容會帶入 LINE。有填 `LINE_OA` 時會直接開啟官方帳號聊天室；沒填的話會開啟 LINE 分享畫面。
3. 打不開 LINE 時，可以按「複製訂單」再自己貼上。

## LINE 官方帳號＋LIFF 設定步驟
1. 到 LINE Official Account Manager 建立官方帳號，記下帳號 ID（@開頭）。
2. 到 LINE Developers Console 建立 Provider，再建立一個 **LINE Login channel**。
3. 在該 channel 的 LIFF 分頁新增 LIFF app：
   - Size：Full（或 Tall）
   - Endpoint URL：GitHub Pages 網址，例如 `https://ccl0320.github.io/<repo>/`
   - Scopes：勾選 `chat_message.write`、`profile`
4. 把 LIFF ID 填到 `index.html` 的 `LIFF_ID`，官方帳號 ID 填到 `LINE_OA`。
5. LINE Login channel 的「Linked LINE Official Account」選擇你的官方帳號（加好友提示用）。
6. 在官方帳號後台設定圖文選單，按鈕連結填 `https://liff.line.me/<LIFF_ID>`。

## 注意
目前訂單只會變成一則 LINE 訊息，沒有後台資料庫，也還沒串接線上金流。
