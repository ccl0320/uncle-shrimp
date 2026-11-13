"""產生網站檔案。
用法：python3 src/build.py
  - 輸出網站用的 index.html、assets/ 與 Cloudflare 安全標頭 _headers（repo 根目錄）
  - python3 src/build.py --dist：另外把要公開的檔案複製到 dist/（Cloudflare Pages 的建置指令）
  - 輸出單檔預覽版 src/preview.html（圖片內嵌，給 Artifact 預覽用，不進版控）
"""
import base64, hashlib, os, re, shutil, sys
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
       '<script src="config.js?v=20261113b"></script>\n'
       + head + '<style>\n[hidden]{display:none!important}body{margin:0}\n'
       + rest.replace('</style>', '</style>\n</head>\n<body>', 1) + '\n</body>\n</html>\n')
open(os.path.join(ROOT, 'index.html'), 'w', encoding='utf-8').write(out)

# ---------- Cloudflare Pages 安全標頭 ----------
# 前台的內嵌 script 用 SHA-256 雜湊放行，其他來源一律擋掉
inline = re.findall(r'<script>(.*?)</script>', out, re.S)
hashes = ' '.join("'sha256-%s'" % base64.b64encode(hashlib.sha256(x.encode('utf-8')).digest()).decode() for x in inline)
SUPA = 'https://*.supabase.co'
LINE = 'https://*.line.me https://*.line-scdn.net https://*.line-apps.com'
csp_site = '; '.join([
    "default-src 'self'",
    f"script-src 'self' {hashes} https://static.line-scdn.net",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com",
    f"img-src 'self' data: blob: {SUPA} https://*.line-scdn.net",
    f"connect-src 'self' {SUPA} {LINE}",
    f"frame-src {LINE}",
    "base-uri 'none'", "form-action 'none'", "object-src 'none'", "frame-ancestors 'none'",
])
headers = f"""# 由 src/build.py 自動產生，請勿手動修改
/*
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
  Cross-Origin-Opener-Policy: same-origin

/
  Content-Security-Policy: {csp_site}
/index.html
  Content-Security-Policy: {csp_site}

/admin/*
  Cache-Control: no-store
  X-Robots-Tag: noindex, nofollow, noarchive
  Referrer-Policy: no-referrer

/config.js
  Cache-Control: no-cache

/assets/*
  Cache-Control: public, max-age=604800
"""
open(os.path.join(ROOT, '_headers'), 'w', encoding='utf-8').write(headers)

# ---------- Cloudflare Pages 輸出（只放要公開的檔案，原始碼、SQL、README 不會被公開） ----------
if '--dist' in sys.argv:
    dist = os.path.join(ROOT, 'dist')
    shutil.rmtree(dist, ignore_errors=True)
    os.makedirs(dist)
    for f in ['index.html', 'config.js', '_headers', 'robots.txt']:
        shutil.copy(os.path.join(ROOT, f), os.path.join(dist, f))
    for d in ['assets', 'admin']:
        shutil.copytree(os.path.join(ROOT, d), os.path.join(dist, d))
    print('dist ready:', sorted(os.listdir(dist)))

print('ok', len(s), len(out))
