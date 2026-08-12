let endpoints = [];
let meta = {};
let statusChart = null;
let hasLoadedOnce = false;

const REFRESH_MS = 60000;
const THEME_KEY = 'dashboardTheme';
const STALE_AFTER_MIN = 15;

function esc(value) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[c]);
}

function plain(value) {
  return (value === null || value === undefined) ? '' : String(value);
}

document.addEventListener('DOMContentLoaded', () => {
  restoreTheme();
  startClock();
  loadData();
  setInterval(loadData, REFRESH_MS);
  document.getElementById('searchInput').addEventListener('input', filterAndRenderTable);
  document.getElementById('statusFilter').addEventListener('change', filterAndRenderTable);
  document.getElementById('exportBtn').addEventListener('click', exportToCsv);
  const themeBtn = document.getElementById('themeToggleBtn');
  if (themeBtn) {
    themeBtn.addEventListener('click', toggleTheme);
  }
});

function loadData() {
  return fetch('data/secureboot_data.json', { cache: 'no-store' })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP ${response.status} fetching dashboard data`);
      }
      return response.json();
    })
    .then(data => {
      const payload = (data && !Array.isArray(data)) ? data : { endpoints: data };
      endpoints = Array.isArray(payload.endpoints) ? payload.endpoints : [];
      meta = payload.meta || {};
      hasLoadedOnce = true;
      renderDashboard();
    })
    .catch(error => {
      console.error('Error fetching dashboard data:', error);
      if (!hasLoadedOnce) {
        endpoints = [];
        meta = {};
        renderDashboard();
      } else {
        renderLastRefresh();
      }
    });
}

function startClock() {
  function update() {
    const now = new Date();
    const dateStr = now.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
    const timeStr = now.toLocaleTimeString('en-US', { hour12: true });
    const elDate = document.getElementById('liveDate');
    const elClock = document.getElementById('liveClock');
    if (elDate) elDate.textContent = dateStr;
    if (elClock) elClock.textContent = timeStr;
    renderLastRefresh();
  }
  update();
  setInterval(update, 1000);
}

function renderLastRefresh() {
  const el = document.getElementById('lastRefresh');
  const dot = document.querySelector('.heartbeat-dot');
  if (!el) return;
  const collected = meta.CollectedAt ? new Date(meta.CollectedAt) : null;
  if (!collected || isNaN(collected.getTime())) {
    el.textContent = 'NO DATA';
    if (dot) setHeartbeat(dot, 'var(--red)');
    return;
  }
  const ageMin = Math.max(0, Math.floor((Date.now() - collected.getTime()) / 60000));
  const stamp = collected.toLocaleTimeString('en-US', { hour12: false });
  el.textContent = ageMin < 1 ? `${stamp} (just now)` : `${stamp} (${ageMin}m ago)`;
  if (dot) setHeartbeat(dot, ageMin >= STALE_AFTER_MIN ? 'var(--amber)' : 'var(--green)');
}

function setHeartbeat(dot, color) {
  dot.style.background = color;
  dot.style.boxShadow = `0 0 8px ${color}`;
}

function renderDashboard() {
  renderSiteBadge();
  renderLastRefresh();
  calculateMetrics();
  renderChart();
  filterAndRenderTable();
}

function renderSiteBadge() {
  const el = document.getElementById('dataBadge');
  if (!el) return;
  const site = plain(meta.SiteCode).trim();
  el.textContent = site ? `${site} SITE ACTIVE` : 'SITE UNAVAILABLE';
}

function calculateMetrics() {
  const total = endpoints.length;
  const complete = endpoints.filter(e => e.StatusCategory === 'Complete' || e.UEFICA2023Status === 'Updated').length;
  const pilot = endpoints.filter(e => e.StatusCategory === 'ReadyForPilotReview').length;
  const firmware = endpoints.filter(e => e.StatusCategory === 'NeedsFirmwareReview' || (e.UEFICA2023ErrorHex && e.UEFICA2023ErrorHex !== '0x0000')).length;
  const bitlocker = endpoints.filter(e => e.StatusCategory === 'NeedsBitLockerReview').length;
  const os = endpoints.filter(e => e.StatusCategory === 'NeedsOSReview').length;
  const legacy = endpoints.filter(e => e.StatusCategory === 'SecureBootDisabledOrLegacy').length;
  const setVal = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
  setVal('metricTotal', total);
  setVal('metricComplete', complete);
  setVal('metricPilot', pilot);
  setVal('metricFirmware', firmware);
  setVal('metricBitlocker', bitlocker);
  setVal('metricOS', os);
  setVal('metricLegacy', legacy);
}

function renderChart() {
  const total = endpoints.length || 1;
  const counts = {
    Complete: endpoints.filter(e => e.StatusCategory === 'Complete' || e.UEFICA2023Status === 'Updated').length,
    ReadyForPilotReview: endpoints.filter(e => e.StatusCategory === 'ReadyForPilotReview').length,
    NeedsFirmwareReview: endpoints.filter(e => e.StatusCategory === 'NeedsFirmwareReview').length,
    NeedsBitLockerReview: endpoints.filter(e => e.StatusCategory === 'NeedsBitLockerReview').length,
    NeedsOSReview: endpoints.filter(e => e.StatusCategory === 'NeedsOSReview').length,
    SecureBootDisabledOrLegacy: endpoints.filter(e => e.StatusCategory === 'SecureBootDisabledOrLegacy').length
  };

  const progressList = document.getElementById('progressList');
  if (progressList) {
    progressList.innerHTML = `
      ${createProgressBar('Compliant (2023 UEFI CA)', counts.Complete, total, 'var(--green)')}
      ${createProgressBar('Pilot Candidate Cohort', counts.ReadyForPilotReview, total, 'var(--teal)')}
      ${createProgressBar('Hold: OEM Firmware Review', counts.NeedsFirmwareReview, total, 'var(--amber)')}
      ${createProgressBar('Hold: BitLocker Escrow', counts.NeedsBitLockerReview, total, 'var(--violet)')}
      ${createProgressBar('Hold: OS LCU Servicing', counts.NeedsOSReview, total, 'var(--red)')}
      ${createProgressBar('Hold: Disabled / Legacy BIOS', counts.SecureBootDisabledOrLegacy, total, '#94a3b8')}
    `;
  }

  if (window.Chart) {
    const ctx = document.getElementById('statusDoughnutChart');
    if (ctx) {
      if (statusChart) { statusChart.destroy(); }
      statusChart = new Chart(ctx, {
        type: 'doughnut',
        data: {
          labels: ['Compliant', 'Pilot', 'Firmware', 'BitLocker', 'OS', 'Legacy'],
          datasets: [{
            data: [counts.Complete, counts.ReadyForPilotReview, counts.NeedsFirmwareReview, counts.NeedsBitLockerReview, counts.NeedsOSReview, counts.SecureBootDisabledOrLegacy],
            backgroundColor: ['#00e68a', '#00d4ff', '#ffaa00', '#a855f7', '#ff4466', '#94a3b8'],
            borderWidth: 0
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          cutout: '72%'
        }
      });
    }
  }
}

function createProgressBar(label, count, total, color) {
  const pct = Math.round((count / total) * 100);
  return `
    <div>
      <div style="display:flex; justify-content:space-between; font-size:0.7rem; margin-bottom:3px; color:var(--text-secondary);">
        <span>${label}</span>
        <span style="font-family:'JetBrains Mono',monospace;"><strong>${count}</strong> (${pct}%)</span>
      </div>
      <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:4px; overflow:hidden;">
        <div style="height:100%; width:${pct}%; background-color:${color}; border-radius:4px; transition:width 0.6s ease;"></div>
      </div>
    </div>
  `;
}

function filterAndRenderTable() {
  const searchEl = document.getElementById('searchInput');
  const filterEl = document.getElementById('statusFilter');
  const query = searchEl ? searchEl.value.toLowerCase() : '';
  const filter = filterEl ? filterEl.value : 'ALL';

  const filtered = endpoints.filter(e => {
    const matchesSearch = [e.ComputerName, e.Manufacturer, e.Model, e.OSName]
      .some(v => plain(v).toLowerCase().includes(query));
    const matchesFilter = (filter === 'ALL') || (e.StatusCategory === filter);
    return matchesSearch && matchesFilter;
  });

  const tbody = document.getElementById('tableBody');
  if (!tbody) return;
  tbody.innerHTML = '';

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" style="text-align: center; color: var(--text-muted); padding: 20px;">No client endpoints matching search filter.</td></tr>`;
    return;
  }

  filtered.forEach(e => {
    const tr = document.createElement('tr');
    tr.style.borderBottom = '1px solid rgba(255,255,255,0.05)';
    tr.innerHTML = `
      <td style="padding:10px 14px; font-weight:700; color:var(--text-primary); font-family:'JetBrains Mono',monospace;">${esc(e.ComputerName)}</td>
      <td style="padding:10px 14px;">${getPillHtml(e.StatusCategory)}</td>
      <td style="padding:10px 14px; color:var(--text-secondary);">${esc([e.Manufacturer, e.Model].map(plain).filter(Boolean).join(' '))}</td>
      <td style="padding:10px 14px; color:var(--text-secondary);">${esc(e.OSName)}</td>
      <td style="padding:10px 14px; font-family:'JetBrains Mono',monospace; color:var(--text-primary);">${esc(e.UEFICA2023Status || 'NotStarted')}</td>
      <td style="padding:10px 14px; font-family:'JetBrains Mono',monospace; color:var(--text-muted);">${esc(e.UEFICA2023ErrorHex || '0x0000')}</td>
      <td style="padding:10px 14px; color:var(--text-muted); font-size:0.7rem;">${esc(e.ConfidenceLevel)}</td>
    `;
    tbody.appendChild(tr);
  });
}

function getPillHtml(category) {
  switch (category) {
    case 'Complete':
      return `<span class="pill pill-green">COMPLETE</span>`;
    case 'ReadyForPilotReview':
      return `<span class="pill pill-blue">PILOT CANDIDATE</span>`;
    case 'NeedsFirmwareReview':
      return `<span class="pill pill-amber">FIRMWARE REVIEW</span>`;
    case 'NeedsBitLockerReview':
      return `<span class="pill pill-purple">BITLOCKER REVIEW</span>`;
    case 'NeedsOSReview':
      return `<span class="pill pill-red">OS REVIEW</span>`;
    case 'SecureBootDisabledOrLegacy':
      return `<span class="pill pill-gray">DISABLED / LEGACY</span>`;
    default:
      return `<span class="pill pill-gray">${esc(category) || 'UNKNOWN'}</span>`;
  }
}

function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme') || 'dark';
  const next = current === 'dark' ? 'frosty' : (current === 'frosty' ? 'light' : 'dark');
  document.documentElement.setAttribute('data-theme', next);
  try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
}

function restoreTheme() {
  let saved = null;
  try { saved = localStorage.getItem(THEME_KEY); } catch (e) {}
  document.documentElement.setAttribute('data-theme', saved || 'dark');
}

function exportToCsv() {
  const cell = v => `"${plain(v).replace(/"/g, '""')}"`;
  let csv = 'ComputerName,StatusCategory,Manufacturer,Model,OSName,UEFICA2023Status,UEFICA2023ErrorHex,ConfidenceLevel\n';
  endpoints.forEach(e => {
    csv += [
      e.ComputerName, e.StatusCategory, e.Manufacturer, e.Model,
      e.OSName, e.UEFICA2023Status, e.UEFICA2023ErrorHex, e.ConfidenceLevel
    ].map(cell).join(',') + '\n';
  });
  const blob = new Blob([csv], { type: 'text/csv' });
  const url = window.URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.setAttribute('href', url);
  a.setAttribute('download', `SecureBoot2026-ClientStatus-${new Date().toISOString().slice(0,10)}.csv`);
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}
