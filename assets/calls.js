import { db, configured, configBanner, esc, clean, cityLine, fmtPhone, digits, mountWho } from "./db.js";
import { mountSidebar } from "./nav.js";

const PER_PAGE = 15;

const sourceEl = document.getElementById("source");
const qEl      = document.getElementById("q");
const clearBtn = document.getElementById("clearFilters");
const countEl  = document.getElementById("callCount");
const infoEl   = document.getElementById("callInfo");
const summaryEl = document.getElementById("summary");
const statusEl = document.getElementById("status");
const rowsEl   = document.getElementById("rows");
const pagerEl  = document.getElementById("pager");

mountSidebar("calls");
mountWho(document.getElementById("whoHost"));

let pageSeq = 0, countSeq = 0, page = 0, total = null;

const filters = () => ({ q: qEl.value.trim() || null, p_source: sourceEl.value || null });
const anyFilter = () => Object.values(filters()).some(Boolean);
const totalPages = () => (total === null ? null : Math.max(1, Math.ceil(total / PER_PAGE)));

function setStatus(text) {
  statusEl.textContent = text || "";
  statusEl.hidden = !text;
}

async function loadSources() {
  const { data, error } = await db.rpc("list_call_sources");
  if (error) { infoEl.textContent = error.message; return; }
  if (!data.length) {
    infoEl.textContent = "No cold calling numbers yet — upload some from the Cold calling page of the uploader.";
    return;
  }
  sourceEl.insertAdjacentHTML("beforeend", data.map((r) =>
    `<option value="${esc(r.source)}">${esc(r.source)} (${Number(r.n).toLocaleString()})</option>`).join(""));
  infoEl.textContent = `${data.length} source${data.length === 1 ? "" : "s"}.`;
}

function rowHtml(r) {
  const href = clean(r.folio)
    ? `property.html?folio=${encodeURIComponent(clean(r.folio))}` +
      (clean(r.county) ? `&county=${encodeURIComponent(clean(r.county))}` : "")
    : null;
  const addr = clean(r.address);
  return `
    <div class="mail-row calls">
      <span class="addr">${href ? `<a href="${href}">${esc(addr)}</a>` : esc(addr)}</span>
      <span class="who">${esc(clean(r.full_name))}</span>
      <span class="meta">${esc(cityLine(r.property_city, r.property_state, r.property_zip))}</span>
      <span class="tags">${r.source ? `<span class="chip vendor">${esc(r.source)}</span>` : ""}</span>
      <span class="meta">${clean(r.folio) ? esc(clean(r.folio)) : "not in BuyBox"}</span>
      <a class="when" href="tel:${esc(digits(r.phone))}">${esc(fmtPhone(r.phone))}</a>
    </div>`;
}

async function load() {
  const mine = ++pageSeq;
  setStatus("Loading…");
  const { data, error } = await db.rpc("search_calls", {
    ...filters(), max_rows: PER_PAGE, skip: page * PER_PAGE
  });
  if (mine !== pageSeq) return;

  if (error) {
    setStatus("");
    rowsEl.innerHTML = `<div class="mail-row calls"><span class="err">${esc(error.message)}</span></div>`;
    pagerEl.innerHTML = "";
    return;
  }
  if (!data.length) {
    setStatus(anyFilter() ? "No numbers match these filters."
                          : "No cold calling numbers loaded yet.");
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
  const { data, error } = await db.rpc("count_calls", filters());
  if (error || mine !== countSeq) return;
  total = Number(data);
  countEl.textContent = anyFilter() ? `${total.toLocaleString()} number${total === 1 ? "" : "s"}` : "";
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
    : `Showing <b>${from.toLocaleString()}–${to.toLocaleString()}</b> of <b>${total.toLocaleString()}</b> numbers.`;
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

function syncUrl() {
  const url = new URL(location.href);
  const set = (k, v) => v ? url.searchParams.set(k, v) : url.searchParams.delete(k);
  set("s", sourceEl.value);
  set("q", qEl.value.trim());
  set("p", page > 0 ? page + 1 : "");
  history.replaceState(null, "", url);
}

function onFilterChange() {
  page = 0;
  clearBtn.hidden = !anyFilter();
  syncUrl();
  loadTotal();
  load();
}

sourceEl.addEventListener("change", onFilterChange);
let debounce;
qEl.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(onFilterChange, 280); });
clearBtn.addEventListener("click", () => { sourceEl.value = ""; qEl.value = ""; onFilterChange(); });

if (!configured) {
  configBanner(document.getElementById("banner"));
  [sourceEl, qEl].forEach((el) => (el.disabled = true));
} else {
  const p = new URLSearchParams(location.search);
  loadSources().then(() => {
    if (p.get("s")) sourceEl.value = p.get("s");
    if (p.get("q")) qEl.value = p.get("q");
    page = Math.max(0, (parseInt(p.get("p"), 10) || 1) - 1);
    clearBtn.hidden = !anyFilter();
    loadTotal();
    load();
  });
}
