import {
  db, configured, configBanner, esc, clean, cityLine, splitList, chipsHtml,
  propertyHref, mountWho, toast
} from "./db.js";
import { exportCsv } from "./export.js";

const PAGE = 25;

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

const qEl        = document.getElementById("q");
const fieldEl    = document.getElementById("field");
const hintEl     = document.getElementById("hint");
const statusEl   = document.getElementById("status");
const resultsEl  = document.getElementById("results");
const moreEl     = document.getElementById("more");
const chipsEl    = document.getElementById("distressChips");
const countEl    = document.getElementById("filterCount");
const clearBtn   = document.getElementById("clearFilters");
const exportBtn  = document.getElementById("exportBtn");

mountWho(document.getElementById("whoHost"));

/** The status line collapses when empty, instead of leaving a gap above the results. */
function setStatus(html, isHtml = false) {
  if (isHtml) statusEl.innerHTML = html; else statusEl.textContent = html || "";
  statusEl.hidden = !html;
}

let seq = 0;                       // guards against out-of-order search responses
let countSeq = 0;                  // ...and a separate one for the count, so the
                                   // search firing next does not cancel it
let offset = 0;
let currentQuery = "";
let currentField = "all";
let selected = new Set();          // distress keys
let filteredTotal = null;          // only known when no text query is involved

const keys = () => [...selected];

function applyField(f) {
  currentField = FIELDS[f] ? f : "all";
  fieldEl.value = currentField;
  qEl.placeholder = FIELDS[currentField].placeholder;
  hintEl.textContent = FIELDS[currentField].hint;
}

function termIsUsable() {
  return qEl.value.trim().length >= FIELDS[currentField].min;
}
function hasCriteria() {
  return termIsUsable() || selected.size > 0;
}

function idleText() {
  if (selected.size) return "";
  return currentField === "folio"
    ? "Type a parcel number, or pick a distress reason below."
    : "Start typing, or pick a distress reason below, to search 285,947 properties.";
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

async function refreshFilterCount() {
  filteredTotal = null;
  countEl.textContent = "";
  if (!selected.size) return;

  // count_by_distress ignores the text query, so only show it when there isn't one
  if (termIsUsable()) { countEl.textContent = "+ search"; return; }

  const mine = ++countSeq;
  const { data, error } = await db.rpc("count_by_distress", { p_lists: keys() });
  if (error || mine !== countSeq) return;
  filteredTotal = Number(data);
  countEl.textContent = `${filteredTotal.toLocaleString()} record${filteredTotal === 1 ? "" : "s"}`;
}

function refreshControls() {
  clearBtn.hidden = selected.size === 0;
  exportBtn.disabled = !hasCriteria();
  exportBtn.textContent = filteredTotal !== null
    ? `Export ${filteredTotal.toLocaleString()}`
    : "Export CSV";
}

/* -------------------------------- results -------------------------------- */
function resultHtml(r) {
  const addr = clean(r.property_address) || "(no property address)";
  const lists = splitList(r.lists);
  const phones = Number(r.phone_count) || 0;
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
        ${phones ? `<span class="chip tel">📞 ${phones}</span>` : ""}
        ${chipsHtml(lists.slice(0, 6))}
        ${lists.length > 6 ? `<span class="chip">+${lists.length - 6}</span>` : ""}
      </span>
    </a>`;
}

async function runSearch(append = false) {
  const mine = ++seq;
  if (!append) {
    offset = 0;
    resultsEl.innerHTML = "";
    moreEl.innerHTML = "";
    setStatus("Searching…");
  }

  const { data, error } = await db.rpc("search_properties", {
    q: currentQuery || null,
    max_rows: PAGE + 1,
    skip: offset,
    field: currentField,
    p_lists: selected.size ? keys() : null
  });

  if (mine !== seq) return;                       // a newer search already fired

  if (error) {
    setStatus(`<span class="err" style="display:block">Search failed: ${esc(error.message)}</span>`, true);
    return;
  }

  const hasMore = data.length > PAGE;
  const rows = hasMore ? data.slice(0, PAGE) : data;

  if (!append && rows.length === 0) {
    setStatus(currentQuery
      ? `No matches for “${currentQuery}”${selected.size ? " with those distress reasons" : ""}.`
      : "No records carry all of those distress reasons.");
    return;
  }

  setStatus("");
  resultsEl.insertAdjacentHTML("beforeend", rows.map(resultHtml).join(""));
  offset += rows.length;

  moreEl.innerHTML = hasMore
    ? `<button class="btn ghost" id="moreBtn">Load more</button>`
    : `<p class="hint">${offset.toLocaleString()} result${offset === 1 ? "" : "s"}.</p>`;

  const btn = document.getElementById("moreBtn");
  if (btn) btn.addEventListener("click", () => {
    btn.disabled = true;
    runSearch(true);
  });
}

function syncUrl() {
  const url = new URL(location.href);
  const term = qEl.value.trim();
  if (term) url.searchParams.set("q", term); else url.searchParams.delete("q");
  if (currentField !== "all") url.searchParams.set("f", currentField); else url.searchParams.delete("f");
  if (selected.size) url.searchParams.set("d", keys().join("|")); else url.searchParams.delete("d");
  history.replaceState(null, "", url);
}

function onCriteriaChanged() {
  syncUrl();
  refreshFilterCount().then(refreshControls);
  refreshControls();

  const term = qEl.value.trim();
  const min = FIELDS[currentField].min;

  if (!hasCriteria()) {
    seq++;                                        // cancel any in-flight response
    resultsEl.innerHTML = "";
    moreEl.innerHTML = "";
    setStatus(term.length ? `Keep typing — at least ${min} characters.` : idleText());
    return;
  }
  currentQuery = termIsUsable() ? term : "";
  runSearch();
}

let debounce;
qEl.addEventListener("input", () => {
  clearTimeout(debounce);
  debounce = setTimeout(onCriteriaChanged, 280);
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

if (!configured) {
  configBanner(document.getElementById("banner"));
  qEl.disabled = true;
  fieldEl.disabled = true;
  exportBtn.disabled = true;
  chipsEl.innerHTML = "";
  setStatus("");
} else {
  loadDistresses();
  const initial = params.get("q");
  if (initial) qEl.value = initial;
  if (initial || selected.size) onCriteriaChanged();
  else { setStatus(idleText()); refreshControls(); }
}
