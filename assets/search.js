import {
  db, configured, configBanner, esc, clean, cityLine, splitList, chipsHtml, propertyHref, mountWho
} from "./db.js";

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

const qEl       = document.getElementById("q");
const fieldEl   = document.getElementById("field");
const hintEl    = document.getElementById("hint");
const statusEl  = document.getElementById("status");
const resultsEl = document.getElementById("results");
const moreEl    = document.getElementById("more");

mountWho(document.getElementById("whoHost"));

let seq = 0;          // guards against out-of-order responses
let offset = 0;
let currentQuery = "";
let currentField = "all";

function applyField(f) {
  currentField = FIELDS[f] ? f : "all";
  fieldEl.value = currentField;
  qEl.placeholder = FIELDS[currentField].placeholder;
  hintEl.textContent = FIELDS[currentField].hint;
}

function idleText() {
  return currentField === "folio"
    ? "Type a parcel number to search."
    : "Start typing to search 285,947 properties.";
}

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

async function runSearch(term, append = false) {
  const mine = ++seq;
  if (!append) {
    offset = 0;
    resultsEl.innerHTML = "";
    moreEl.innerHTML = "";
    statusEl.textContent = "Searching…";
    statusEl.className = "empty";
  }

  const { data, error } = await db.rpc("search_properties", {
    q: term, max_rows: PAGE + 1, skip: offset, field: currentField
  });

  if (mine !== seq) return;                       // a newer search already fired

  if (error) {
    statusEl.innerHTML = `<span class="err" style="display:block">Search failed: ${esc(error.message)}</span>`;
    return;
  }

  const hasMore = data.length > PAGE;
  const rows = hasMore ? data.slice(0, PAGE) : data;

  if (!append && rows.length === 0) {
    statusEl.textContent = `No matches for “${term}” in ${fieldEl.options[fieldEl.selectedIndex].text.toLowerCase()}.`;
    return;
  }

  statusEl.textContent = "";
  resultsEl.insertAdjacentHTML("beforeend", rows.map(resultHtml).join(""));
  offset += rows.length;

  moreEl.innerHTML = hasMore
    ? `<button class="btn ghost" id="moreBtn">Load more</button>`
    : `<p class="hint">${offset} result${offset === 1 ? "" : "s"}.</p>`;

  const btn = document.getElementById("moreBtn");
  if (btn) btn.addEventListener("click", () => {
    btn.disabled = true;
    runSearch(currentQuery, true);
  });
}

function syncUrl(term) {
  const url = new URL(location.href);
  if (term) url.searchParams.set("q", term); else url.searchParams.delete("q");
  if (currentField !== "all") url.searchParams.set("f", currentField); else url.searchParams.delete("f");
  history.replaceState(null, "", url);
}

function search() {
  const term = qEl.value.trim();
  syncUrl(term);

  const min = FIELDS[currentField].min;
  if (term.length < min) {
    seq++;                                        // cancel any in-flight response
    resultsEl.innerHTML = "";
    moreEl.innerHTML = "";
    statusEl.className = "empty";
    statusEl.textContent = term.length ? `Keep typing — at least ${min} characters.` : idleText();
    return;
  }
  currentQuery = term;
  runSearch(term);
}

let debounce;
qEl.addEventListener("input", () => {
  clearTimeout(debounce);
  debounce = setTimeout(search, 280);
});

fieldEl.addEventListener("change", () => {
  applyField(fieldEl.value);
  clearTimeout(debounce);
  search();                                       // re-run immediately, no debounce
  qEl.focus();
});

// restore from the URL (back button, shared link)
const params = new URLSearchParams(location.search);
applyField(params.get("f") || "all");

if (!configured) {
  configBanner(document.getElementById("banner"));
  qEl.disabled = true;
  fieldEl.disabled = true;
  statusEl.textContent = "";
} else {
  const initial = params.get("q");
  if (initial) {
    qEl.value = initial;
    search();
  } else {
    statusEl.textContent = idleText();
  }
}
