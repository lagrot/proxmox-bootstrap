#!/usr/bin/env python3
"""Build three structurally different offline sample interfaces."""
from pathlib import Path
import json,re,shutil
from zipfile import ZipFile,ZIP_DEFLATED
root=Path(__file__).resolve().parents[2]
source=root/'public'
out=root/'artifacts'/'designs-v2'
out.mkdir(parents=True,exist_ok=True)
match=re.search(r'<script id=\"?demo-config\"?[^>]*>(.*?)</script>',(source/'index.html').read_text())
if not match: raise SystemExit('Build Zola first: demo configuration is missing')
data=json.loads(match.group(1))
variants=[('huset','Huset','Utforska en schematisk huskarta. Rummen visar klimat och öppnar historik. Kamerorna och inspelningarna ligger runt huset.'),('tv','TV-fönstret','En kamera i taget i ett stort bildfönster. Byt kanal, bläddra i filmremsan eller öppna klimatpanelen.'),('dagboken','Dagboken','En redaktionell tidslinje över de senaste inspelningarna. Kamerorna ligger överst och klimatet följer med i marginalen.')]
for mode,title,desc in variants:
 target=out/mode
 target.mkdir(exist_ok=True)
 for directory in ['assets','processed_images']:
  shutil.copytree(source/directory,target/directory,dirs_exist_ok=True)
 for filename in ['study.css','study.js']:
  shutil.copyfile(Path(__file__).parent/filename,target/'assets'/filename)
 (target/'index.html').write_text('''<!doctype html><html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Landet · '''+title+'''</title><link rel="stylesheet" href="assets/study.css"><script src="assets/demo-core.js" defer></script><script src="assets/study.js" defer></script></head><body class="'''+mode+'''"><div class="demo-bar"><a href="../index.html">← Byt design</a><span>DESIGNSTUDIE · Alla bilder och värden är exempel</span></div><main id="app"></main><dialog id="detail"><div id="detail-content"></div><button class="close-detail" autofocus>Stäng ×</button></dialog><script id="study-data" type="application/json">'''+json.dumps(dict(data,mode=mode),ensure_ascii=False)+'''</script></body></html>''')
cards=''.join(f'<a href="{mode}/index.html"><span>0{i+1}</span><h2>{title}</h2><p>{desc}</p><strong>Prova →</strong></a>' for i,(mode,title,desc) in enumerate(variants))
(out/'index.html').write_text('''<!doctype html><html lang="sv"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tre nya sätt att se Landet</title><style>*{box-sizing:border-box}body{margin:0;background:#eeeae1;color:#21382f;font:18px/1.6 system-ui}main{max-width:1240px;margin:auto;padding:60px 26px}h1{font:normal clamp(44px,7vw,84px)/1.05 Georgia;margin:20px 0}header p{max-width:750px}.choices{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;margin-top:42px}a{display:block;color:inherit;text-decoration:none;background:#fbfaf5;padding:30px;border:2px solid #21382f;box-shadow:6px 6px 0 #21382f}a:nth-child(2){background:#11221c;color:#e6f3dc}a:nth-child(3){background:#f7d8b7;color:#663b28}a span{font:60px Georgia}a h2{font-size:30px}a:focus-visible{outline:5px solid #cb532d;outline-offset:5px}strong{display:block;margin-top:30px}@media(max-width:850px){.choices{grid-template-columns:1fr}}</style><main><header><small>LANDET / DESIGNSTUDIO / OMGÅNG 2</small><h1>Tre olika upplevelser.</h1><p>En karta. En TV. En dagbok. Samma kameror, tolv inspelningar och fyra termometrar – med tre olika sätt att hitta och använda informationen.</p></header><div class="choices">'''+cards+'''</div><p>Helt offline med påhittade bilder, simulerade klipp och exempelvärden. Huset är schematiskt och visar inte din riktiga planlösning.</p></main>''')
archive=root/'artifacts'/'landet-three-designs-v2.zip'
with ZipFile(archive,'w',ZIP_DEFLATED) as z:
 for p in out.rglob('*'):
  if p.is_file(): z.write(p,p.relative_to(out))
print(archive,archive.stat().st_size,'bytes')
