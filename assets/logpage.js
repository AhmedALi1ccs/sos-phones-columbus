/**
 * The list page behind Mailing and SMS. Both are logs loaded straight into
 * Supabase -- who was contacted, how, and in which month -- so they share this
 * and differ only by configuration: one category picker (campaign tag /
 * approach), a month picker and free text.
 */
import { db, configured, configBanner, esc, mountWho, monthLabel } from "./db.js";
import { mountSidebar } from "./nav.js";

const PER_PAGE = 15;

export function initLogPage(cfg) {

const facetEl  = document.getElementById("facet");
const periodEl = document.getElementById("period");
const qEl      = document.getElementById("q");
const clearBtn = document.getElementById("clearFilters");
const countEl  = document.getElementById("logCount");
const infoEl   = document.getElementById("logInfo");
const summaryEl = document.getElementById("summary");
const statusEl = document.getElementById("status");
const rowsEl   = document.getElementById("rows");
const pagerEl  = document.getElementById("pager");

mountSidebar(cfg.navKey);
mountWho(document.getElementById("whoHost"));

let pageSeq = 0, countSeq = 0, page = 0, total = null;

const filters = () => ({
  q: qEl.value.trim() || null,
  [cfg.facetParam]: facetEl.value || null,
  p_period: periodEl.value || null
});
const anyFilter = () => Object.values(filters()).some(Boolean);
const totalPages = () => (total === null ? null : Math.max(1, Math.ceil(total / PER_PAGE)));
const plural = (n) => (n === 1 ? cfg.noun : cfg.nouns);

function setStatus(text) {
  statusEl.textContent = text || "";
  statusEl.hidden = !text;
}

/* ------------------------------- facets ------------------------------- */
async function loadFacets() {
  const [f, per] = await Promise.all([db.rpc(cfg.rpcFacets), db.rpc(cfg.rpcPeriods)]);

  if (!f.error) {
    facetEl.insertAdjacentHTML("beforeend", f.data.map((r) =>
      `<option value="${esc(cfg.facetValue(r))}">${esc(cfg.facetLabel(r))} (${Number(r.n).toLocaleString()})</option>`).join(""));
  }
  if (!per.error) {
    // a row whose date could not be read has no period, and cannot be picked
    const dated = per.data.filter((r) => r.period);
    periodEl.insertAdjacentHTML("beforeend", dated.map((r) =>
      `<option value="${esc(r.period)}">${esc(monthLabel(r.period))} (${Number(r.n).toLocaleString()})</option>`).join(""));
    const undated = per.data.filter((r) => !r.period).reduce((n, r) => n + Number(r.n), 0);
    const all = per.data.reduce((n, r) => n + Number(r.n), 0);
    infoEl.textContent = all === 0 ? cfg.emptyList
      : `${all.toLocaleString()} ${plural(all)} across ${dated.length} month${dated.length === 1 ? "" : "s"}` +
        (undated ? `; ${undated.toLocaleString()} have a date that could not be read.` : ".");
  }
  const err = f.error || per.error;
  if (err) infoEl.textContent = err.message;
}

/* -------------------------------- rows -------------------------------- */
async function load() {
  const mine = ++pageSeq;
  setStatus("Loading…");
  const { data, error } = await db.rpc(cfg.rpcSearch, {
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
    setStatus(anyFilter() ? `No ${cfg.nouns} match these filters.` : cfg.emptyList);
    rowsEl.innerHTML = "";
    pagerEl.innerHTML = "";
    summaryEl.textContent = "";
    return;
  }
  setStatus("");
  rowsEl.innerHTML = data.map(cfg.rowHtml).join("");
  renderSummary(data.length);
  renderPager();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function loadTotal() {
  const mine = ++countSeq;
  total = null;
  renderSummary();
  renderPager();
  const { data, error } = await db.rpc(cfg.rpcCount, filters());
  if (error || mine !== countSeq) return;
  total = Number(data);
  countEl.textContent = anyFilter() ? `${total.toLocaleString()} ${plural(total)}` : "";
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
    : `Showing <b>${from.toLocaleString()}–${to.toLocaleString()}</b> of <b>${total.toLocaleString()}</b> ${cfg.nouns}, newest first.`;
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
  set(cfg.facetUrlKey, facetEl.value);
  set("mo", periodEl.value);
  set("q", qEl.value.trim());
  set("p", page > 0 ? page + 1 : "");
  history.replaceState(null, "", url);
}

function restoreFromUrl() {
  const p = new URLSearchParams(location.search);
  if (p.get(cfg.facetUrlKey)) facetEl.value = p.get(cfg.facetUrlKey);
  if (p.get("mo")) periodEl.value = p.get("mo");
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

[facetEl, periodEl].forEach((el) => el.addEventListener("change", onFilterChange));
let debounce;
qEl.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(onFilterChange, 280); });
clearBtn.addEventListener("click", () => {
  [facetEl, periodEl, qEl].forEach((el) => (el.value = ""));
  onFilterChange();
});

  if (!configured) {
    configBanner(document.getElementById("banner"));
    [facetEl, periodEl, qEl].forEach((el) => (el.disabled = true));
    return;
  }
  loadFacets().then(() => {
    restoreFromUrl();
    clearBtn.hidden = !anyFilter();
    loadTotal();
    load();
  });
}
