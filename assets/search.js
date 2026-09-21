import {
  db, configured, configBanner, esc, clean, cityLine, splitList, chipsHtml,
  propertyHref, mountWho, toast
} from "./db.js";
import { exportCsv, EXPORT_CAP } from "./export.js";

const PER_PAGE = 15;

/** What each field means to the person typing, and how short a query may be. */
const FIELDS = {
  all:      { placeholder: "Search by property address, owner name, mailing address…",
              hint: "Searches every field. Partial matches are fine.", min: 3 },
  property: { placeholder: "e.g. 2451 Juniper Dr, or just Juniper",
              hint: "Property address, city, state or zip only.", min: 3 },
  name:     { placeholder: "e.g. Mildred Brown, or just Brown",
              hint: "Owner name only — full, first or last.", min: 3 },
  mailing:  { placeholder: "e.g. 3540 Wheeler Rd",
              hint: "Mailing address, city, state or zip only.", min: 3 },
  folio:    { placeholder: "e.g. F# 077G222, or just 077G222",
              hint: "Parcel number. The “F# ” prefix is optional, and a fragment works.", min: 2 }
};

const qEl       = document.getElementById("q");
const fieldEl   = document.getElementById("field");
const hintEl    = document.getElementById("hint");
const summaryEl = document.getElementById("summary");
const statusEl  = document.getElementById("status");
const resultsEl = document.getElementById("results");
const pagerEl   = document.getElementById("pager");
const chipsEl   = document.getElementById("distressChips");
const countEl   = document.getElementById("filterCount");
const clearBtn  = document.getElementById("clearFilters");
const exportBtn = document.getElementById("exportBtn");

mountWho(document.getElementById("whoHost"));

function setStatus(html, isHtml = false) {
  if (isHtml) statusEl.innerHTML = html; else statusEl.textContent = html || "";
  statusEl.hidden = !html;
}

let pageSeq  = 0;        // guards against out-of-order page responses
let countSeq = 0;        // ...and a separate one for the total, so one cannot cancel the other
let page = 0;            // zero-based
let total = null;
let currentQuery = "";
let currentField = "all";
let selected = new Set();

const keys = () => [...selected];
const termIsUsable = () => qEl.value.trim().length >= FIELDS[currentField].min;
const totalPages = () => (total === null ? null : Math.max(1, Math.ceil(total / PER_PAGE)));

function applyField(f) {
  currentField = FIELDS[f] ? f : "all";
  fieldEl.value = currentField;
  qEl.placeholder = FIELDS[currentField].placeholder;
  hintEl.textContent = FIELDS[currentField].hint;
}

/* ----------------------------- distress chips ----------------------------- */
async function loadDistresses() {
  const { data, error } = await db.rpc("list_distresses");
  if (error) {
    chipsEl.innerHTML = `<span class="hint">Could not load distress reasons: ${esc(error.message)}</span>`;
    return;
  }
  chipsEl.innerHTML = data.map((d) => `
    <button type="button" class="chip-toggle" data-key="${esc(d.key)}"
            aria-pressed="${selected.has(d.key)}">
      ${esc(d.label)} <span class="n">${Number(d.n_properties).toLocaleString()}</span>
    </button>`).join("");

  chipsEl.querySelectorAll(".chip-toggle").forEach((b) =>
    b.addEventListener("click", () => {
      const k = b.dataset.key;
      if (selected.has(k)) selected.delete(k); else selected.add(k);
      b.setAttribute("aria-pressed", String(selected.has(k)));
      onCriteriaChanged();
    }));
}

/* -------------------------------- results -------------------------------- */
function resultHtml(r) {
  const addr = clean(r.property_address) || "(no property address)";
  const lists = splitList(r.lists);
  const phones = Number(r.phone_count) || 0;
  const stack = Number(r.list_stack) || 0;
  return `
    <a class="result" href="${propertyHref(r)}">
      <span class="line1">
        <span class="addr">${esc(addr)}</span>
        <span class="name">${esc(clean(r.full_name))}</span>
      </span>
      <span class="line2">
        ${esc(cityLine(r.property_city, r.property_state, r.property_zip))}
        &nbsp;·&nbsp; Mailing: ${esc(clean(r.mailing_address) || "—")}${
          clean(r.mailing_city) ? ", " + esc(cityLine(r.mailing_city, r.mailing_state, r.mailing_zip)) : ""}
        ${clean(r.folio) ? `&nbsp;·&nbsp; ${esc(clean(r.folio))}` : ""}
      </span>
      <span class="chips">
        ${stack ? `<span class="chip stack" title="Distress reasons on this record">${stack}</span>` : ""}
        ${phones ? `<span class="chip tel">📞 ${phones}</span>` : ""}
        ${chipsHtml(lists.slice(0, 6))}
        ${lists.length > 6 ? `<span class="chip">+${lists.length - 6}</span>` : ""}
      </span>
    </a>`;
}

async function loadPage() {
  const mine = ++pageSeq;
  setStatus("Searching…");

  const { data, error } = await db.rpc("search_properties", {
    q: currentQuery || null,
    max_rows: PER_PAGE,
    skip: page * PER_PAGE,
    field: currentField,
    p_lists: selected.size ? keys() : null
  });

  if (mine !== pageSeq) return;                 // a newer request already fired

  if (error) {
    setStatus(`<span class="err" style="display:block">Search failed: ${esc(error.message)}</span>`, true);
    resultsEl.innerHTML = "";
    pagerEl.innerHTML = "";
    return;
  }

  if (data.length === 0) {
    setStatus(currentQuery
      ? `No matches for “${currentQuery}”${selected.size ? " with those distress reasons" : ""}.`
      : "No records carry all of those distress reasons.");
    resultsEl.innerHTML = "";
    pagerEl.innerHTML = "";
    summaryEl.textContent = "";
    return;
  }

  setStatus("");
  resultsEl.innerHTML = data.map(resultHtml).join("");
  renderSummary(data.length);
  renderPager();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function loadTotal() {
  const mine = ++countSeq;
  total = null;
  renderSummary();
  renderPager();

  const { data, error } = await db.rpc("count_properties", {
    q: currentQuery || null,
    field: currentField,
    p_lists: selected.size ? keys() : null
  });
  if (error || mine !== countSeq) return;

  total = Number(data);
  countEl.textContent = selected.size ? `${total.toLocaleString()} record${total === 1 ? "" : "s"}` : "";

  // the CSV is assembled in the browser, so say what will actually come out
  const exportable = Math.min(total, EXPORT_CAP);
  exportBtn.textContent = `Export ${exportable.toLocaleString()}`;
  exportBtn.title = total > EXPORT_CAP
    ? `${total.toLocaleString()} match, but an export is capped at ${EXPORT_CAP.toLocaleString()}. `
      + `Narrow it with another distress reason or a search term.`
    : "";
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
  const sortedBy = currentQuery ? "best match" : "most distress reasons";
  summaryEl.innerHTML = total === 0 ? ""
    : `Showing <b>${from.toLocaleString()}–${to.toLocaleString()}</b> of <b>${total.toLocaleString()}</b>, sorted by ${sortedBy}.`;
}

/** 1 … 7 8 [9] 10 11 … 19,063 */
function pageWindow(current, last) {
  const out = new Set([0, last - 1]);
  for (let i = current - 2; i <= current + 2; i++) if (i >= 0 && i < last) out.add(i);
  return [...out].sort((a, b) => a - b);
}

function renderPager() {
  const last = totalPages();
  if (last === null || last <= 1) { pagerEl.innerHTML = ""; return; }

  const btn = (label, target, opts = {}) =>
    `<button type="button" data-page="${target}"
       ${opts.disabled ? "disabled" : ""}
       ${opts.current ? 'aria-current="page"' : ""}
       ${opts.label ? `aria-label="${opts.label}"` : ""}>${label}</button>`;

  let html = btn("«", 0, { disabled: page === 0, label: "First page" })
           + btn("‹", page - 1, { disabled: page === 0, label: "Previous page" });

  let prev = -1;
  for (const i of pageWindow(page, last)) {
    if (prev >= 0 && i > prev + 1) html += `<span class="gap">…</span>`;
    html += btn((i + 1).toLocaleString(), i, { current: i === page });
    prev = i;
  }

  html += btn("›", page + 1, { disabled: page >= last - 1, label: "Next page" })
        + btn("»", last - 1, { disabled: page >= last - 1, label: "Last page" });

  pagerEl.innerHTML = html;
  pagerEl.querySelectorAll("button[data-page]").forEach((b) =>
    b.addEventListener("click", () => goToPage(Number(b.dataset.page))));
}

function goToPage(n) {
  const last = totalPages();
  page = Math.max(0, last === null ? n : Math.min(n, last - 1));
  syncUrl();
  loadPage();
}

/* ------------------------------ criteria ------------------------------ */
function syncUrl() {
  const url = new URL(location.href);
  const term = qEl.value.trim();
  if (term) url.searchParams.set("q", term); else url.searchParams.delete("q");
  if (currentField !== "all") url.searchParams.set("f", currentField); else url.searchParams.delete("f");
  if (selected.size) url.searchParams.set("d", keys().join("|")); else url.searchParams.delete("d");
  if (page > 0) url.searchParams.set("p", page + 1); else url.searchParams.delete("p");
  history.replaceState(null, "", url);
}

function onCriteriaChanged(keepPage = false) {
  const term = qEl.value.trim();
  const min = FIELDS[currentField].min;

  // a term too short to search is treated as no term, not as an error
  if (term.length && !termIsUsable()) {
    setStatus(`Keep typing — at least ${min} characters.`);
    resultsEl.innerHTML = "";
    pagerEl.innerHTML = "";
    summaryEl.textContent = "";
    return;
  }

  currentQuery = termIsUsable() ? term : "";
  if (!keepPage) page = 0;
  clearBtn.hidden = selected.size === 0;
  exportBtn.disabled = false;
  exportBtn.textContent = "Export CSV";
  countEl.textContent = "";

  syncUrl();
  loadTotal();
  loadPage();
}

let debounce;
qEl.addEventListener("input", () => {
  clearTimeout(debounce);
  debounce = setTimeout(() => onCriteriaChanged(), 280);
});

fieldEl.addEventListener("change", () => {
  applyField(fieldEl.value);
  clearTimeout(debounce);
  onCriteriaChanged();
  qEl.focus();
});

clearBtn.addEventListener("click", () => {
  selected.clear();
  chipsEl.querySelectorAll(".chip-toggle").forEach((b) => b.setAttribute("aria-pressed", "false"));
  onCriteriaChanged();
});

exportBtn.addEventListener("click", async () => {
  const label = exportBtn.textContent;
  exportBtn.disabled = true;
  const res = await exportCsv({
    query: currentQuery,
    field: currentField,
    keys: keys(),
    onProgress: (n) => { exportBtn.textContent = `Exporting… ${n.toLocaleString()}`; }
  });
  exportBtn.textContent = label;
  exportBtn.disabled = false;
  if (res) {
    toast(res.hitCap
      ? `Exported the first ${res.count.toLocaleString()} records (limit reached)`
      : `Exported ${res.count.toLocaleString()} records`);
  }
});

/* ------------------------------ start-up ------------------------------ */
const params = new URLSearchParams(location.search);
applyField(params.get("f") || "all");
(params.get("d") || "").split("|").filter(Boolean).forEach((k) => selected.add(k));
page = Math.max(0, (parseInt(params.get("p"), 10) || 1) - 1);
if (params.get("q")) qEl.value = params.get("q");

if (!configured) {
  configBanner(document.getElementById("banner"));
  qEl.disabled = true;
  fieldEl.disabled = true;
  exportBtn.disabled = true;
  chipsEl.innerHTML = "";
} else {
  loadDistresses();
  onCriteriaChanged(true);        // with nothing set this browses everything by list stack
}
