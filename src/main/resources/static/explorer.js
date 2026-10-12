const BASE = window.location.origin;
document.getElementById('base-url-label').textContent = BASE;

// ── Helpers ──────────────────────────────────────────────────────────────────

function timingClass(ms) {
  return ms < 300 ? 't-green' : ms < 1000 ? 't-amber' : 't-red';
}

function statusClass(s) {
  const k = (s||'').toLowerCase();
  if (k.includes('complet')) return 's-complete';
  if (k.includes('pend'))    return 's-pending';
  if (k.includes('cancel'))  return 's-cancel';
  if (k.includes('process')) return 's-process';
  return 's-default';
}

function monoParam(label, val) {
  return `<span class="mono-param">${label}=<span>${val}</span></span>`;
}

async function fetchTimed(path) {
  const t0 = performance.now();
  const res = await fetch(path);
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const json = await res.json();
  return { json, ms: Math.round(performance.now() - t0) };
}

function renderMetaBar(ms, label) {
  return `<div class="meta-bar">
    <span class="timing-pill ${timingClass(ms)}">⚡ ${ms}ms</span>
    <span class="meta-label">${label}</span>
  </div>`;
}

function renderRawJson(id, data) {
  return `<button class="raw-toggle-btn" onclick="toggleRaw('${id}')">
    <span class="raw-arrow" id="arr-${id}">▶</span> View raw JSON
  </button>
  <pre class="raw-pre" id="raw-${id}">${JSON.stringify(data, null, 2)}</pre>`;
}

function toggleRaw(id) {
  document.getElementById('raw-' + id).classList.toggle('open');
  document.getElementById('arr-' + id).classList.toggle('open');
}

function renderOrderTable(rows) {
  const trs = rows.map((o, i) => {
    const c = o.customer || {};
    const r = o.region   || {};
    const name = c.name || [c.firstName, c.lastName].filter(Boolean).join(' ') || '—';
    return `<tr>
      <td class="mono c-muted">${i+1}</td>
      <td class="mono">${o.id ?? '—'}</td>
      <td><span class="status-pill ${statusClass(o.status)}">${o.status||'—'}</span></td>
      <td class="mono"><span class="c-green">${o.currency||'$'}${Number(o.total||0).toFixed(2)}</span></td>
      <td>${name}</td>
      <td class="c-muted">${r.name||r.code||'—'}</td>
      <td class="mono c-muted">${String(o.placedAt||'—').slice(0,10)}</td>
    </tr>`;
  }).join('');
  return `<div class="table-wrap"><table>
    <thead><tr><th>#</th><th>ID</th><th>Status</th><th>Total</th><th>Customer</th><th>Region</th><th>Placed</th></tr></thead>
    <tbody>${trs}</tbody>
  </table></div>`;
}

function renderCustomerTable(rows) {
  const trs = rows.map((c, i) => {
    const r = c.region || {};
    const name = c.name || [c.firstName, c.lastName].filter(Boolean).join(' ') || '—';
    return `<tr>
      <td class="c-muted">${i+1}</td>
      <td>${name}</td>
      <td class="mono" style="color:#a1a1aa;font-size:0.7rem">${c.email||'—'}</td>
      <td class="c-muted">${r.name||r.code||c.regionCode||'—'}</td>
    </tr>`;
  }).join('');
  return `<div class="table-wrap"><table>
    <thead><tr><th>#</th><th>Name</th><th>Email</th><th>Region</th></tr></thead>
    <tbody>${trs}</tbody>
  </table></div>`;
}

function renderStatGrid(stats) {
  return `<div class="stat-grid">${stats.map(s =>
    `<div class="stat-card">
      <div class="stat-label">${s.label}</div>
      <div class="stat-val" style="color:${s.color||'#f4f4f5'}">${s.value}</div>
    </div>`
  ).join('')}</div>`;
}

function renderAggTable(rows) {
  const trs = rows.slice(0,10).map((day, i) => {
    const cats = Object.values(day.categories||{});
    const dOrders  = cats.reduce((s,c) => s+(c.totalOrders||0), 0);
    const dRevenue = cats.reduce((s,c) => s+(c.totalRevenue||0), 0);
    const catNames = Object.keys(day.categories||{}).slice(0,3).join(', ');
    return `<tr>
      <td class="mono" style="color:#a1a1aa">${day.date||'—'}</td>
      <td>${dOrders.toLocaleString()}</td>
      <td class="mono"><span class="c-green">$${dRevenue.toLocaleString(undefined,{maximumFractionDigits:0})}</span></td>
      <td style="color:#52525b;font-size:0.7rem">${catNames}</td>
    </tr>`;
  }).join('');
  return `<div class="table-wrap"><table>
    <thead><tr><th>Date</th><th>Orders</th><th>Revenue</th><th>Categories</th></tr></thead>
    <tbody>${trs}</tbody>
  </table></div>`;
}

// ── Card builder ──────────────────────────────────────────────────────────────

let cardCount = 0;
function buildCard({ method = 'GET', path, subtitle, bodyFn }) {
  const id = 'card-' + (++cardCount);
  const methodClass = method === 'POST' ? 'method-post' : '';
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `
    <button class="card-header" onclick="toggleCard('${id}')">
      <div class="card-header-left">
        <span class="method-badge ${methodClass}">${method}</span>
        <span class="card-path">${path}</span>
        <span class="card-sub">${subtitle}</span>
      </div>
      <svg class="chevron" id="chev-${id}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 9l6 6 6-6"/></svg>
    </button>
    <div class="card-body" id="body-${id}"></div>`;
  document.getElementById('cards').appendChild(el);
  const bodyEl = document.getElementById('body-' + id);
  bodyFn(bodyEl, id);
}

function toggleCard(id) {
  document.getElementById('body-' + id).classList.toggle('open');
  document.getElementById('chev-' + id).classList.toggle('open');
}

function setResult(el, html) { el.innerHTML = html; }

// ── Cards ─────────────────────────────────────────────────────────────────────

buildCard({
  path: '/api/orders',
  subtitle: 'Latest orders — paginated, sorted by date descending',
  bodyFn(body, id) {
    body.innerHTML = `<div class="card-row">
      <div class="params">${monoParam('pageSize','10')} ${monoParam('sort','placedAt')} ${monoParam('dir','desc')}</div>
      <button class="run-btn" id="btn-${id}" onclick="runOrders('${id}')">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
      </button>
    </div><div id="res-${id}"></div>`;
  }
});

async function runOrders(id) {
  const btn = document.getElementById('btn-' + id);
  const res = document.getElementById('res-' + id);
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Running…';
  res.innerHTML = `<div class="loading"><span class="spinner"></span>Sending request…</div>`;
  try {
    const { json, ms } = await fetchTimed('/api/orders?pageSize=10&sort=placedAt&dir=desc');
    const rows  = json.data || [];
    const total = json.total ?? rows.length;
    res.innerHTML = renderMetaBar(ms, `${Number(total).toLocaleString()} total orders · showing first 10`) +
      (rows.length ? renderOrderTable(rows) : '') + renderRawJson(id, json);
  } catch(e) {
    res.innerHTML = `<div class="err-box">${e.message}</div>`;
  }
  btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
}

// ── Search card ───────────────────────────────────────────────────────────────
buildCard({
  path: '/api/orders?q=…',
  subtitle: 'Full-text search via GIN pg_bigm index — 2-char minimum',
  bodyFn(body, id) {
    body.innerHTML = `<div class="card-row">
      <div class="params" style="align-items:center">
        <input class="dark-input" id="q-${id}" placeholder="e.g. gupta, sara, east…" style="width:220px"
          onkeydown="if(event.key==='Enter') runSearch('${id}')">
        ${monoParam('pageSize','10')}
      </div>
      <button class="run-btn" id="btn-${id}" onclick="runSearch('${id}')">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
      </button>
    </div><div id="res-${id}"></div>`;
  }
});

async function runSearch(id) {
  const q = document.getElementById('q-' + id).value.trim();
  if (!q) return;
  const btn = document.getElementById('btn-' + id);
  const res = document.getElementById('res-' + id);
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Running…';
  res.innerHTML = `<div class="loading"><span class="spinner"></span>Sending request…</div>`;
  try {
    const { json, ms } = await fetchTimed('/api/orders?q=' + encodeURIComponent(q) + '&pageSize=10');
    const rows  = json.data || [];
    const total = json.total ?? rows.length;
    res.innerHTML = renderMetaBar(ms, `${Number(total).toLocaleString()} match${Number(total)!==1?'es':''} for "${q}"`) +
      (rows.length ? renderOrderTable(rows) : '<p style="font-size:.75rem;color:#71717a">No results.</p>') +
      renderRawJson(id, json);
  } catch(e) {
    res.innerHTML = `<div class="err-box">${e.message}</div>`;
  }
  btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
}

// ── Aggregates card ───────────────────────────────────────────────────────────
buildCard({
  path: '/api/aggregates',
  subtitle: 'Pre-aggregated daily totals by category — millisecond response',
  bodyFn(body, id) {
    const today = new Date().toISOString().slice(0,10);
    const ago60 = new Date(Date.now()-60*864e5).toISOString().slice(0,10);
    body.innerHTML = `<div class="card-row">
      <div class="params" style="align-items:center">
        <span class="mono-param">from</span>
        <input type="date" class="dark-input" id="from-${id}" value="${ago60}" style="width:150px">
        <span class="mono-param">to</span>
        <input type="date" class="dark-input" id="to-${id}" value="${today}" style="width:150px">
        ${monoParam('topCategories','3')}
      </div>
      <button class="run-btn" id="btn-${id}" onclick="runAgg('${id}')">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
      </button>
    </div><div id="res-${id}"></div>`;
  }
});

async function runAgg(id) {
  const from = document.getElementById('from-' + id).value;
  const to   = document.getElementById('to-'   + id).value;
  if (!from || !to) return;
  const btn = document.getElementById('btn-' + id);
  const res = document.getElementById('res-' + id);
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Running…';
  res.innerHTML = `<div class="loading"><span class="spinner"></span>Sending request…</div>`;
  try {
    const { json, ms } = await fetchTimed(`/api/aggregates?from=${from}&to=${to}&topCategories=3`);
    const raw  = json.data ?? json;
    const rows = Array.isArray(raw) ? raw : [];
    let orders = 0, revenue = 0;
    rows.forEach(d => Object.values(d.categories||{}).forEach(c => { orders += c.totalOrders||0; revenue += c.totalRevenue||0; }));
    const stats = [
      { label:'Total Orders',  value: orders.toLocaleString() },
      { label:'Est. Revenue',  value: '$'+revenue.toLocaleString(undefined,{maximumFractionDigits:0}), color:'#34d399' },
      { label:'Days Returned', value: String(rows.length) },
    ];
    res.innerHTML = renderMetaBar(ms, `${rows.length} day${rows.length!==1?'s':''} · ${from} → ${to}`) +
      renderStatGrid(stats) + renderAggTable(rows) + renderRawJson(id, json);
  } catch(e) {
    res.innerHTML = `<div class="err-box">${e.message}</div>`;
  }
  btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
}

// ── Customers card ────────────────────────────────────────────────────────────
buildCard({
  path: '/api/customers',
  subtitle: 'Customer list — cursor-paginated',
  bodyFn(body, id) {
    body.innerHTML = `<div class="card-row">
      <div class="params" style="align-items:center">
        <input class="dark-input" id="q-${id}" placeholder="e.g. gupta, sara…" style="width:200px"
          onkeydown="if(event.key==='Enter') runCustomers('${id}')">
        ${monoParam('limit','10')}
      </div>
      <button class="run-btn" id="btn-${id}" onclick="runCustomers('${id}')">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
      </button>
    </div><div id="res-${id}"></div>`;
  }
});

async function runCustomers(id) {
  const q = document.getElementById('q-' + id).value.trim();
  const btn = document.getElementById('btn-' + id);
  const res = document.getElementById('res-' + id);
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Running…';
  res.innerHTML = `<div class="loading"><span class="spinner"></span>Sending request…</div>`;
  try {
    const url = '/api/customers?limit=10' + (q ? '&q=' + encodeURIComponent(q) : '');
    const { json, ms } = await fetchTimed(url);
    const rows = Array.isArray(json) ? json : (json.data||[]);
    res.innerHTML = renderMetaBar(ms, `${rows.length} customer${rows.length!==1?'s':''} returned`) +
      (rows.length ? renderCustomerTable(rows) : '<p style="font-size:.75rem;color:#71717a">No results.</p>') +
      renderRawJson(id, json);
  } catch(e) {
    res.innerHTML = `<div class="err-box">${e.message}</div>`;
  }
  btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
}

// ── Regions card ──────────────────────────────────────────────────────────────
buildCard({
  path: '/api/regions',
  subtitle: 'All regions — no parameters',
  bodyFn(body, id) {
    body.innerHTML = `<div class="card-row">
      <p style="font-size:.6875rem;color:#52525b">Returns the full list of regions used for filtering.</p>
      <button class="run-btn" id="btn-${id}" onclick="runRegions('${id}')">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
      </button>
    </div><div id="res-${id}"></div>`;
  }
});

async function runRegions(id) {
  const btn = document.getElementById('btn-' + id);
  const res = document.getElementById('res-' + id);
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Running…';
  res.innerHTML = `<div class="loading"><span class="spinner"></span>Sending request…</div>`;
  try {
    const { json, ms } = await fetchTimed('/api/regions');
    const rows = Array.isArray(json) ? json : [];
    res.innerHTML = renderMetaBar(ms, `${rows.length} region${rows.length!==1?'s':''} returned`) +
      renderRawJson(id, json);
  } catch(e) {
    res.innerHTML = `<div class="err-box">${e.message}</div>`;
  }
  btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
}

// ── Brush card ────────────────────────────────────────────────────────────────

(function() {
  const S = { data: [], brushL: 0, brushR: 1, res: null, fetching: false };
  let brushTimer = null;

  buildCard({
    path: '/api/aggregates?from=…&to=…',
    subtitle: 'Drag brush handles · sub-second re-fetch',
    bodyFn(body, id) {
      body.innerHTML = `
        <div class="card-row" id="brush-init-row-${id}">
          <p style="font-size:.6875rem;color:#52525b">Loads a year of aggregate data, then drag the handles to re-query any sub-range live.</p>
          <button class="run-btn" id="brush-btn-${id}" onclick="brushInit('${id}')">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run
          </button>
        </div>
        <div id="brush-chart-${id}" style="display:none;margin-bottom:1rem">
          <svg id="brush-svg-${id}" viewBox="0 0 600 80" width="100%" height="80"
            preserveAspectRatio="none" style="display:block;border-radius:6px"></svg>
          <div id="brush-track-${id}" style="position:relative;height:20px;margin-top:8px;
            background:rgba(255,255,255,0.04);border-radius:10px;user-select:none">
            <div id="brush-fill-${id}" style="position:absolute;top:0;height:100%;left:0%;width:100%;
              background:rgba(129,140,248,0.18);border:1px solid rgba(129,140,248,0.45);
              border-radius:10px;pointer-events:none"></div>
            <div id="brush-hl-${id}" style="position:absolute;top:50%;left:0%;
              transform:translate(-50%,-50%);width:10px;height:22px;background:#818cf8;
              border-radius:3px;cursor:ew-resize;touch-action:none;z-index:2"></div>
            <div id="brush-hr-${id}" style="position:absolute;top:50%;left:100%;
              transform:translate(-50%,-50%);width:10px;height:22px;background:#818cf8;
              border-radius:3px;cursor:ew-resize;touch-action:none;z-index:2"></div>
          </div>
          <div style="display:flex;justify-content:space-between;margin-top:6px">
            <span id="brush-dl-${id}" style="font-size:0.625rem;font-family:monospace;color:#52525b"></span>
            <span id="brush-dr-${id}" style="font-size:0.625rem;font-family:monospace;color:#52525b"></span>
          </div>
        </div>
        <div id="brush-res-${id}"></div>`;
      attachBrushHandlers(id);
    }
  });

  window.brushInit = async function(id) {
    const btn = document.getElementById('brush-btn-' + id);
    btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Loading…';
    const today = new Date().toISOString().slice(0,10);
    const ago   = new Date(Date.now()-365*864e5).toISOString().slice(0,10);
    try {
      const { json, ms } = await fetchTimed(`/api/aggregates?from=${ago}&to=${today}&topCategories=1`);
      const raw  = json?.data ?? json;
      const data = Array.isArray(raw) ? raw : [];
      if (!data.length) throw new Error('no data');
      S.data = data; S.brushL = 0; S.brushR = 1;
      S.res = { json, ms, from: data[0].date, to: data[data.length-1].date };
      buildSvgBars(id);
      updateBrushVisuals(id);
      document.getElementById('brush-init-row-' + id).style.display = 'none';
      document.getElementById('brush-chart-' + id).style.display = '';
      updateResults(id);
    } catch(e) {
      document.getElementById('brush-res-' + id).innerHTML = `<div class="err-box">Failed to load aggregates</div>`;
      btn.disabled = false; btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M5 3l14 9-14 9V3z"/></svg>Run';
    }
  };

  function buildSvgBars(id) {
    const data = S.data, n = data.length;
    const totals = data.map(d => Object.values(d.categories||{}).reduce((s,c)=>s+(c.totalOrders||0),0));
    const mx = Math.max(...totals, 1);
    const svg = document.getElementById('brush-svg-' + id);
    svg.innerHTML = totals.map((v, i) => {
      const x = (i/n)*600, bw = 600/n, h = Math.max(2,(v/mx)*76);
      return `<rect id="bb-${id}-${i}" x="${x.toFixed(2)}" y="${(80-h).toFixed(2)}" width="${(bw-0.4).toFixed(2)}" height="${h.toFixed(2)}" fill="#1e293b" rx="1"/>`;
    }).join('');
  }

  function updateBrushVisuals(id) {
    const { data, brushL, brushR } = S;
    const n = data.length;
    const li = Math.round(brushL*(n-1)), ri = Math.round(brushR*(n-1));
    for (let i = 0; i < n; i++) {
      const bar = document.getElementById(`bb-${id}-${i}`);
      if (bar) bar.setAttribute('fill', (i>=li&&i<=ri) ? '#818cf8' : '#1e293b');
    }
    const fill = document.getElementById('brush-fill-' + id);
    const hl   = document.getElementById('brush-hl-'   + id);
    const hr   = document.getElementById('brush-hr-'   + id);
    const dl   = document.getElementById('brush-dl-'   + id);
    const dr   = document.getElementById('brush-dr-'   + id);
    if (fill) { fill.style.left = `${brushL*100}%`; fill.style.width = `${(brushR-brushL)*100}%`; }
    if (hl)   hl.style.left = `${brushL*100}%`;
    if (hr)   hr.style.left = `${brushR*100}%`;
    if (dl)   dl.textContent = data[li]?.date || '';
    if (dr)   dr.textContent = data[ri]?.date || '';
  }

  function attachBrushHandlers(id) {
    ['l','r'].forEach(side => {
      const handle = document.getElementById(`brush-h${side}-${id}`);
      const track  = document.getElementById('brush-track-' + id);
      if (!handle || !track) return;
      handle.addEventListener('pointerdown', e => { e.preventDefault(); handle.setPointerCapture(e.pointerId); });
      handle.addEventListener('pointermove', e => {
        if (!handle.hasPointerCapture(e.pointerId) || !S.data.length) return;
        const rect = track.getBoundingClientRect();
        const pos  = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const min  = 1 / Math.max(S.data.length, 1);
        if (side === 'l') S.brushL = Math.min(pos, S.brushR - min);
        else              S.brushR = Math.max(pos, S.brushL + min);
        updateBrushVisuals(id);
        if (brushTimer) clearTimeout(brushTimer);
        brushTimer = setTimeout(() => doBrushFetch(id), 180);
      });
      handle.addEventListener('pointerup', e => handle.releasePointerCapture(e.pointerId));
    });
  }

  function updateResults(id) {
    const resEl = document.getElementById('brush-res-' + id);
    if (!resEl || !S.res) return;
    if (S.fetching) { resEl.innerHTML = `<div class="loading"><span class="spinner"></span>Fetching…</div>`; return; }
    const raw = S.res.json?.data ?? S.res.json;
    const rows = Array.isArray(raw) ? raw : [];
    let bOrders=0, bRevenue=0;
    rows.forEach(d => Object.values(d.categories||{}).forEach(c=>{bOrders+=c.totalOrders||0;bRevenue+=c.totalRevenue||0;}));
    resEl.innerHTML = renderMetaBar(S.res.ms, `${rows.length} day${rows.length!==1?'s':''} · ${S.res.from} → ${S.res.to}`) +
      renderStatGrid([
        { label:'Orders',        value: bOrders.toLocaleString() },
        { label:'Est. Revenue',  value: '$'+bRevenue.toLocaleString(undefined,{maximumFractionDigits:0}), color:'#34d399' },
        { label:'Days in range', value: String(rows.length) },
      ]);
  }

  async function doBrushFetch(id) {
    const n = S.data.length;
    if (!n) return;
    const li = Math.round(S.brushL*(n-1)), ri = Math.round(S.brushR*(n-1));
    const from = S.data[li]?.date, to = S.data[ri]?.date;
    if (!from||!to) return;
    S.fetching = true; updateResults(id);
    try {
      const r2 = await fetchTimed(`/api/aggregates?from=${from}&to=${to}&topCategories=1`);
      S.res = { ...r2, from, to };
    } catch {} finally { S.fetching = false; }
    updateResults(id);
  }
})();
