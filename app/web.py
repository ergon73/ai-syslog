import asyncio

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, PlainTextResponse

from . import analyzer, db, hosts

app = FastAPI(title="ai-syslog")

PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>ai-syslog</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; background:#10141c; color:#d7dde8; margin:0; }
  header { padding:12px 20px; background:#181f2c; display:flex; gap:16px; align-items:center; }
  h1 { font-size:16px; margin:0; color:#7fb4ff; }
  button { background:#2a3245; color:#d7dde8; border:1px solid #3a4560;
           border-radius:6px; padding:6px 14px; cursor:pointer; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  td { padding:4px 10px; border-bottom:1px solid #1d2433; vertical-align:top; }
  .sev-3, .sev-2, .sev-1, .sev-0 { color:#ff7b72; }
  .sev-4 { color:#e3b341; }
  .sev-5, .sev-6 { color:#8b949e; }
  .ai { background:#16202e; color:#9ecbff; font-size:12px; }
  .ai b { color:#e3b341; }
  .ts { white-space:nowrap; color:#6e7681; }
  .vendors { color:#6e7681; font-size:11px; margin-top:2px; }
  #digest { white-space:pre-wrap; padding:16px 20px; background:#141a26; margin:0; display:none; }
</style></head>
<body>
<header>
  <h1>ai-syslog</h1>
  <span id="stat"></span>
  <button onclick="loadDigest()">Дайджест за 24 ч</button>
</header>
<pre id="digest"></pre>
<table id="logs"></table>
<script>
async function refresh() {
  const r = await fetch('/api/logs'); const rows = await r.json();
  document.getElementById('stat').textContent = rows.length + ' последних строк';
  const t = document.getElementById('logs');
  let lastSummary = null;
  t.innerHTML = rows.map(x => {
    const vendors = (x.macs||[]).map(m =>
      m.token + (m.name ? ` = ${m.name}` : '') + (m.vendor ? ` (${m.vendor})` : '')
    ).join(' · ');
    let html = `<tr class="sev-${x.severity}">`
      + `<td class="ts">${(x.received_at||'').replace('T',' ').slice(0,19)}</td>`
      + `<td>${x.tag||''}</td><td>${esc(x.message)}`
      + (vendors ? `<div class="vendors">${esc(vendors)}</div>` : '')
      + `</td></tr>`;
    if (x.summary && x.summary !== lastSummary) {
      html += `<tr><td></td><td class="ai">AI [${x.severity_assessment}]</td>`
        + `<td class="ai"><b>${esc(x.summary)}</b><br>Причина: ${esc(x.probable_cause||'')}`
        + `<br>Рекомендация: ${esc(x.recommendation||'')}</td></tr>`;
    }
    lastSummary = x.summary || null;
    return html;
  }).join('');
}
function esc(s){const d=document.createElement('div');d.textContent=s??'';return d.innerHTML;}
async function loadDigest() {
  const el = document.getElementById('digest');
  el.style.display='block'; el.textContent='Думаю...';
  const r = await fetch('/api/digest'); el.textContent = await r.text();
}
refresh(); setInterval(refresh, 5000);
</script>
</body></html>"""


@app.get("/", response_class=HTMLResponse)
def index():
    return PAGE


@app.get("/api/logs")
def api_logs():
    rows = db.fetch_recent_logs()
    result = []
    for r in rows:
        d = dict(r)
        d["macs"] = hosts.enrich(d["message"])
        result.append(d)
    return result


@app.get("/api/digest", response_class=PlainTextResponse)
async def api_digest():
    return await asyncio.to_thread(analyzer.build_digest, 24)
