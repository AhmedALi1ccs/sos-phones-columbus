import { db, configured, configBanner, esc, clean, cityLine, mountWho } from "./db.js";
import { mountSidebar } from "./nav.js";

const PER_PAGE = 15;

const vendorEl = document.getElementById("vendor");
const distEl   = document.getElementById("distress");
const yearEl   = document.getElementById("year");
const monthEl  = document.getElementById("month");
const fromEl   = document.getElementById("mailedFrom");
const toEl     = document.getElementById("mailedTo");
const qEl      = document.getElementById("q");
const clearBtn = document.getElementById("clearFilters");
const countEl  = document.getElementById("mailCount");
const infoEl   = document.getElementById("mailInfo");
const summaryEl = document.getElementById("summary");
const statusEl = document.getElementById("status");
const rowsEl   = document.getElementById("rows");
const pagerEl  = document.getElementById("pager");

mountSidebar("mailing");
mountWho(document.getElementById("whoHost"));

let pageSeq = 0, countSeq = 0;
let page = 0;
let total = null;

const filters = () => ({
  q: qEl.value.trim() || null,
  p_vendor: vendorEl.value || null,
  p_distress: distEl.value || null,
  p_mailed_from: fromEl.value || null,
  p_mailed_to: toEl.value || null,
  p_month: monthEl.value ? Number(monthEl.value) : null,
  p_year: yearEl.value ? Number(yearEl.value) : null
});
const anyFilter = () => Object.values(filters()).some(Boolean);
const totalPages = () => (total === null ? null : Math.max(1, Math.ceil(total / PER_PAGE)));

function setStatus(text) {
  statusEl.textContent = text || "";
  statusEl.hidden = !text;
}

/* ------------------------------- facets ------------------------------- */
const MONTHS = ["", "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December"];

async function loadFacets() {
  const [v, d, b, per] = await Promise.all([
    db.rpc("list_mail_vendors"),
    db.rpc("list_mail_distresses"),
    db.rpc("mail_date_bounds"),
    db.rpc("list_mail_periods")
  ]);

  if (!per.error) {
    // one call feeds both pickers; a row with no month or year shows as (none)
    const years = new Map(), months = new Map();
    for (const r of per.data) {
      if (r.yr) years.set(r.yr, (years.get(r.yr) || 0) + Number(r.n));
      if (r.mon) months.set(r.mon, (months.get(r.mon) || 0) + Number(r.n));
    }
    yearEl.insertAdjacentHTML("beforeend", [...years.entries()].sort((a, b2) => b2[0] - a[0])
      .map(([y, n]) => `<option value="${y}">${y} (${n.toLocaleString()})</option>`).join(""));
    monthEl.insertAdjacentHTML("beforeend", [...months.entries()].sort((a, b2) => a[0] - b2[0])
      .map(([m, n]) => `<option value="${m}">${MONTHS[m]} (${n.toLocaleString()})</option>`).join(""));
  }

  if (!v.error) {
    vendorEl.insertAdjacentHTML("beforeend", v.data.map((r) =>
      `<option value="${esc(r.vendor)}">${esc(r.vendor)} (${Number(r.n).toLocaleString()})</option>`).join(""));
  }
  if (!d.error) {
    distEl.insertAdjacentHTML("beforeend", d.data.map((r) =>
      `<option value="${esc(r.distress)}">${esc(r.distress)} (${Number(r.n).toLocaleString()})</option>`).join(""));
  }
  if (!b.error) {
    const bounds = Array.isArray(b.data) ? b.data[0] : b.data;
    if (bounds && bounds.first_mailed) {
      [fromEl, toEl].forEach((el) => { el.min = bounds.first_mailed; el.max = bounds.last_mailed; });
      infoEl.textContent =
        `${Number(bounds.n_dated).toLocaleString()} mailings have a date ` +
        `(${bounds.first_mailed} to ${bounds.last_mailed}); ` +
        `${Number(bounds.n_undated).toLocaleString()} do not yet.`;
    } else {
      infoEl.textContent = "No mail dates recorded yet — upload them from the Mail dates page.";
    }
  }
  // “(none)” is a real choice: rows whose Type names no vendor or distress
  restoreFromUrl();
  load();
}

/* -------------------------------- rows -------------------------------- */
/** "September 2026", or whatever of it the row actually carries. */
function period(r) {
  const m = clean(r.mail_month), y = clean(r.mail_year);
  if (!m && !y) return clean(r.mail_type);
  const n = MONTHS.findIndex((x) => x && x.toLowerCase().startsWith(m.toLowerCase().slice(0, 3)));
  const month = /^\d+$/.test(m) ? (MONTHS[Number(m)] || m) : (n > 0 ? MONTHS[n] : m);
  const year = /^\d{2}$/.test(y) ? `20${y}` : y;
  return [month, year].filter(Boolean).join(" ");
}

function rowHtml(r) {
  const href = clean(r.folio)
    ? `property.html?folio=${encodeURIComponent(clean(r.folio))}` +
      (clean(r.county) ? `&county=${encodeURIComponent(clean(r.county))}` : "")
    : null;
  const addr = clean(r.property_address) || "(no property address)";
  return `
    <div class="mail-row">
      <span class="addr">${href ? `<a href="${href}">${esc(addr)}</a>` : esc(addr)}</span>
      <span class="who">${esc(clean(r.full_name))}</span>
      <span class="meta">${esc(cityLine(r.property_city, r.property_state, r.property_zip))}</span>
      <span class="tags">
        ${r.vendor ? `<span class="chip vendor">${esc(r.vendor)}</span>` : ""}
        ${r.distress ? `<span class="chip">${esc(r.distress)}</span>` : ""}
      </span>
      <span class="meta">${esc(period(r))}</span>
      <span class="when${r.mailed_on ? "" : " none"}">${r.mailed_on ? esc(r.mailed_on) : "no date"}</span>
    </div>`;
}

async function load() {
  const mine = ++pageSeq;
  setStatus("Loading…");

  const { data, error } = await db.rpc("search_mailed", {
    ...filters(), max_rows: PER_PAGE, skip: page * PER_PAGE
  });
  if (mine !== pageSeq) return;

  if (error) {
    setStatus("");
    rowsEl.innerHTML = `<div class="mail-row"><span class="err">${esc(error.message)}</span></div>`;
    pagerEl.innerHTML = "";
    return;
  }
  if (!data.length) {
    setStatus("No mailings match these filters.");
    rowsEl.innerHTML = "";
    pagerEl.innerHTML = "";
    summaryEl.textContent = "";
    return;
  }

  setStatus("");
  rowsEl.innerHTML = data.map(rowHtml).join("");
  renderSummary(data.length);
  renderPager();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function loadTotal() {
  const mine = ++countSeq;
  total = null;
  renderSummary();
  renderPager();

  const { data, error } = await db.rpc("count_mailed", filters());
  if (error || mine !== countSeq) return;

  total = Number(data);
  countEl.textContent = anyFilter() ? `${total.toLocaleString()} mailing${total === 1 ? "" : "s"}` : "";
  renderSummary();
  renderPager();
}

function renderSummary(shown) {
  const from = page * PER_PAGE + 1;
  if (total === null) {
    summaryEl.innerHTML = shown ? `Showing <b>${from.toLocaleString()}–${(from + shown - 1).toLocaleString()}</b>…` : "";
    return;
  }
  const to = Math.min(total, from + PER_PAGE - 1);
  summaryEl.innerHTML = total === 0 ? ""
    : `Showing <b>${from.toLocaleString()}–${to.toLocaleString()}</b> of <b>${total.toLocaleString()}</b> mailings, newest first.`;
}

function pageWindow(current, last) {
  const out = new Set([0, last - 1]);
  for (let i = current - 2; i <= current + 2; i++) if (i >= 0 && i < last) out.add(i);
  return [...out].sort((a, b) => a - b);
}

function renderPager() {
  const last = totalPages();
  if (last === null || last <= 1) { pagerEl.innerHTML = ""; return; }

  const btn = (label, target, opts = {}) =>
    `<button type="button" data-page="${target}" ${opts.disabled ? "disabled" : ""}
       ${opts.current ? 'aria-current="page"' : ""}>${label}</button>`;

  let html = btn("«", 0, { disabled: page === 0 }) + btn("‹", page - 1, { disabled: page === 0 });
  let prev = -1;
  for (const i of pageWindow(page, last)) {
    if (prev >= 0 && i > prev + 1) html += `<span class="gap">…</span>`;
    html += btn((i + 1).toLocaleString(), i, { current: i === page });
    prev = i;
  }
  html += btn("›", page + 1, { disabled: page >= last - 1 })
        + btn("»", last - 1, { disabled: page >= last - 1 });

  pagerEl.innerHTML = html;
  pagerEl.querySelectorAll("button[data-page]").forEach((b) =>
    b.addEventListener("click", () => { page = Number(b.dataset.page); syncUrl(); load(); }));
}

/* ------------------------------ plumbing ------------------------------ */
function syncUrl() {
  const url = new URL(location.href);
  const set = (k, v) => v ? url.searchParams.set(k, v) : url.searchParams.delete(k);
  set("v", vendorEl.value);
  set("md", distEl.value);
  set("y", yearEl.value);
  set("mo", monthEl.value);
  set("mf", fromEl.value);
  set("mt", toEl.value);
  set("q", qEl.value.trim());
  set("p", page > 0 ? page + 1 : "");
  history.replaceState(null, "", url);
}

function restoreFromUrl() {
  const p = new URLSearchParams(location.search);
  if (p.get("v")) vendorEl.value = p.get("v");
  if (p.get("md")) distEl.value = p.get("md");
  if (p.get("y")) yearEl.value = p.get("y");
  if (p.get("mo")) monthEl.value = p.get("mo");
  if (p.get("mf")) fromEl.value = p.get("mf");
  if (p.get("mt")) toEl.value = p.get("mt");
  if (p.get("q")) qEl.value = p.get("q");
  page = Math.max(0, (parseInt(p.get("p"), 10) || 1) - 1);
}

function onFilterChange() {
  page = 0;
  clearBtn.hidden = !anyFilter();
  syncUrl();
  loadTotal();
  load();
}

[vendorEl, distEl, yearEl, monthEl, fromEl, toEl].forEach((el) => el.addEventListener("change", onFilterChange));
let debounce;
qEl.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(onFilterChange, 280); });
clearBtn.addEventListener("click", () => {
  [vendorEl, distEl, yearEl, monthEl].forEach((el) => (el.value = ""));
  [fromEl, toEl, qEl].forEach((el) => (el.value = ""));
  onFilterChange();
});

if (!configured) {
  configBanner(document.getElementById("banner"));
  [vendorEl, distEl, yearEl, monthEl, fromEl, toEl, qEl].forEach((el) => (el.disabled = true));
} else {
  loadFacets().then(() => { clearBtn.hidden = !anyFilter(); loadTotal(); });
}
