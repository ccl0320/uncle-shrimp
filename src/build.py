import base64,sys,os
d=os.path.dirname(os.path.abspath(__file__))
s=open(os.path.join(d,'template.html')).read()
for k,f in {'LOGO':'logo.webp','HERO':'hero.webp','BAG':'bag.webp','BOWL':'bowl.webp','FAMILY':'family.webp'}.items():
    s=s.replace('{{%s}}'%k,'data:image/webp;base64,'+base64.b64encode(open(os.path.join(d,'img',f),'rb').read()).decode())
assert '{{' not in s
open(os.path.join(d,'uncle-shrimp.html'),'w').write(s)
head,rest=s.split('<style>',1)
full='<!doctype html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'+head+'<style>\n[hidden]{display:none!important}body{margin:0}\n'+rest.replace('</style>','</style>\n</head>\n<body>',1)+'\n</body>\n</html>\n'
os.makedirs('/mnt/project-files/uncle-shrimp-site/',exist_ok=True)
open('/mnt/project-files/uncle-shrimp-site/index.html','w').write(full)
print(len(s))
# GitHub Pages 版本：圖片放在 assets/
import shutil
R='/mnt/project-files/uncle-shrimp-site/repo/'
os.makedirs(R+'assets',exist_ok=True)
t=open(os.path.join(d,'template.html')).read()
for k,f in {'LOGO':'logo.webp','HERO':'hero.webp','BAG':'bag.webp','BOWL':'bowl.webp','FAMILY':'family.webp'}.items():
    t=t.replace('{{%s}}'%k,'assets/'+f); shutil.copy(os.path.join(d,'img',f),R+'assets/'+f)
head,rest=t.split('<style>',1)
open(R+'index.html','w').write('<!doctype html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n<meta property="og:title" content="舅是好蝦 Uncle’s Shrimp Chips">\n<meta property="og:description" content="舅舅用心炸的手工香脆蝦餅，LINE 線上訂購。">\n<meta property="og:image" content="assets/hero.webp">\n<link rel="icon" href="assets/logo.webp">\n'+head+'<style>\n[hidden]{display:none!important}body{margin:0}\n'+rest.replace('</style>','</style>\n</head>\n<body>',1)+'\n</body>\n</html>\n')
open(R+'.nojekyll','w').write('')
