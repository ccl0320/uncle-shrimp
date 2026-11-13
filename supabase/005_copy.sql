-- =====================================================================
-- 舅是好蝦：商品說明更新（品牌重新定位：舅舅手工現炸、香酥爽脆、大人小孩都愛）
-- 在 004_sale_price.sql 之後執行。可以重複執行。
-- 只改還是預設文字的說明；你在後台改過的不會被覆蓋。
-- =====================================================================

update shop.products
   set description = '選用印尼進口蝦餅原料，由舅舅在台灣手工油炸，做出金黃酥脆、讓大人小孩一口接一口的好滋味。'
 where id = 'original'
   and (description is null or description like '經典原味蝦餅%' or description like '最經典的鮮蝦原味%' or description like '%Melissa%');
