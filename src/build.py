"""產生網站檔案。
用法：python3 src/build.py
  - 輸出 GitHub Pages 用的 index.html 與 assets/（repo 根目錄）
  - 輸出單檔預覽版 src/preview.html（圖片內嵌，給 Artifact 預覽用，不進版控）
"""
import base64, os, shutil
SRC = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SRC)
IMGS = {'LOGO': 'logo.webp', 'HERO': 'hero.webp', 'BAG': 'bag.webp', 'BOWL': 'bowl.webp', 'FAMILY': 'family.webp'}
tpl = open(os.path.join(SRC, 'template.html'), encoding='utf-8').read()

# 單檔預覽版
s = tpl
for k, f in IMGS.items():
    s = s.replace('{{%s}}' % k, 'data:image/webp;base64,' + base64.b64encode(open(os.path.join(SRC, 'img', f), 'rb').read()).decode())
assert '{{' not in s
open(os.path.join(SRC, 'preview.html'), 'w', encoding='utf-8').write(s)

# GitHub Pages 版
os.makedirs(os.path.join(ROOT, 'assets'), exist_ok=True)
t = tpl
for k, f in IMGS.items():
    t = t.replace('{{%s}}' % k, 'assets/' + f)
    shutil.copy(os.path.join(SRC, 'img', f), os.path.join(ROOT, 'assets', f))
head, rest = t.split('<style>', 1)
out = ('<!doctype html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
       '<meta property="og:title" content="舅是好蝦 Uncle’s Shrimp Chips">\n'
       '<meta property="og:description" content="舅舅用心炸的手工香脆蝦餅，LINE 線上訂購。">\n'
       '<meta property="og:image" content="assets/hero.webp">\n<link rel="icon" href="assets/logo.webp">\n'
       '<script src="config.js"></script>\n'
       + head + '<style>\n[hidden]{display:none!important}body{margin:0}\n'
       + rest.replace('</style>', '</style>\n</head>\n<body>', 1) + '\n</body>\n</html>\n')
open(os.path.join(ROOT, 'index.html'), 'w', encoding='utf-8').write(out)
print('ok', len(s), len(out))
