#!/usr/bin/env python3
"""Package three sample-only design studies from the existing Zola build."""
from pathlib import Path
import shutil
from zipfile import ZipFile, ZIP_DEFLATED

viewer = Path(__file__).resolve().parents[1]
source = viewer / 'public'
output = viewer / 'artifacts' / 'designs'
output.mkdir(parents=True, exist_ok=True)
variants = [
 ('01-nordisk', '01', 'Nordisk journal', 'Varmt, luftigt och redaktionellt. Stora bilder, naturfärger och tydlig typografi.', '#eee4d2', '#a4412c'),
 ('02-natt', '02', 'Natt på landet', 'Mörkt och omslutande. Sidomeny på datorn, stora kameravyer och lysande klimatvärden.', '#152231', '#8de5d4'),
 ('03-glad', '03', 'Hej, landet!', 'Lekfullt och tydligt. Stora knappar, glada färger och rum som är lätta att skilja åt.', '#e9edff', '#244ee8'),
]
html = (source / 'index.html').read_text()
cards = []
for slug, number, title, description, color, accent in variants:
 target = output / slug
 target.mkdir(exist_ok=True)
 for directory in ['assets', 'processed_images']:
  shutil.copytree(source / directory, target / directory, dirs_exist_ok=True)
 shutil.copyfile(viewer / 'experiments' / (slug + '.css'), target / 'assets' / 'experiment.css')
 page = html.replace('<body>', '<link rel="stylesheet" href="assets/experiment.css"><body>')
 page = page.replace('<body>', '<body><a class="design-back" href="../index.html">← Alla tre förslag</a>')
 (target / 'index.html').write_text(page)
 with (target / 'assets' / 'experiment.css').open('a') as f:
  f.write('\n.design-back{display:block;text-align:center;padding:10px;background:#fff;color:#192b51;font:600 16px system-ui;text-decoration:underline;position:relative;z-index:10;}\n')
 cards.append(f'<a class="card" href="{slug}/index.html" style="--tile:{color};--accent:{accent}"><span class="number">{number}</span><div class="drawing"><i></i><i></i></div><h2>{title}</h2><p>{description}</p><strong>Öppna förslaget →</strong></a>')
(output / 'index.html').write_text('''<!doctype html><html lang="sv"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Landet · Tre designförslag</title><style>
*{box-sizing:border-box}body{margin:0;background:#f5f4ef;color:#26332f;font:18px/1.6 system-ui,sans-serif}main{max-width:1280px;margin:auto;padding:70px 30px}small{font-weight:700;letter-spacing:.14em;color:#657467}h1{font:normal clamp(40px,6vw,76px)/1.1 Georgia,serif;margin:18px 0}header p{max-width:750px;color:#56635c}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:26px;margin-top:45px}.card{background:var(--tile);border:1px solid #aab6ac;border-radius:24px;padding:28px;text-decoration:none;color:var(--accent);transition:transform .15s}.card:hover{transform:translateY(-5px)}.card:focus-visible{outline:4px solid #244ee8;outline-offset:5px}.number{font:48px Georgia,serif;opacity:.8}.drawing{display:flex;gap:10px;padding:25px 0}.drawing i{display:block;width:50%;height:110px;background:var(--accent);border-radius:12px;opacity:.7}.drawing i:nth-child(2){opacity:.35}h2{font-size:26px;line-height:1.2}p{font-size:17px}.card strong{display:block;margin-top:28px}footer{margin-top:45px;color:#56635c}@media(max-width:850px){.grid{grid-template-columns:1fr}main{padding:35px 22px}.drawing i{height:70px}}
</style><main><header><small>LANDET · DESIGNSTUDIO</small><h1>Tre sätt att se landet.</h1><p>Samma innehåll, tre olika personligheter. Prova kameror, exempelklipp och klimat i varje förslag. Du kan också blanda dina favoritdelar.</p></header><div class="grid">''' + ''.join(cards) + '''</div><footer>Alla bilder, klipp och mätvärden är exempel. Ingen anslutning till ditt hem.</footer></main></html>''')
archive = viewer / 'artifacts' / 'landet-three-designs.zip'
with ZipFile(archive,'w',ZIP_DEFLATED) as z:
 for p in output.rglob('*'):
  if p.is_file(): z.write(p,p.relative_to(output))
print(f'Created {archive.name}: {archive.stat().st_size:,} bytes')
