import {
  db, configured, configBanner, esc, clean, cityLine, splitList, chipsHtml, mountWho, toast
} from "./db.js";

const PAGE = 25;

const qEl       = document.getElementById("q");
const statusEl  = document.getElementById("status");
const resultsEl = document.getElementById("results");
const moreEl    = document.getElementById("more");

mountWho(document.getElementById("whoHost"));

if (!configured) {
  configBanner(document.getElementById("banner"));
  qEl.disabled = true;
  statusEl.textContent = "";
}

let seq = 0;          // guards against out-of-order responses
let offset = 0;
let currentQuery = "";

function resultHtml(r) {
  const addr = clean(r.property_address) || "(no property address)";
  const lists = splitList(r.lists).slice(0, 6);
  const phones = Number(r.phone_count) || 0;
  return `
    <a class="result" href="property.html?id=${encodeURIComponent(r.id)}">
      <span class="line1">
        <span class="addr">${esc(addr)}</span>
        <span class="name">${esc(clean(r.full_name))}</span>
      </span>
      <span class="line2">
        ${esc(cityLine(r.property_city, r.property_state, r.property_zip))}
        &nbsp;·&nbsp; Mailing: ${esc(clean(r.mailing_address) || "—")}${
          clean(r.mailing_city) ? ", " + esc(cityLine(r.mailing_city, r.mailing_state, r.mailing_zip)) : ""}
      </span>
      <span class="chips">
        ${phones ? `<span class="chip tel">📞 ${phones}</span>` : ""}
        ${chipsHtml(lists)}
        ${splitList(r.lists).length > 6 ? `<span class="chip">+${splitList(r.lists).length - 6}</span>` : ""}
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
    q: term, max_rows: PAGE + 1, skip: offset
  });

  if (mine !== seq) return;                       // a newer search already fired

  if (error) {
    statusEl.innerHTML = `<span class="err" style="display:block">Search failed: ${esc(error.message)}</span>`;
    return;
  }

  const hasMore = data.length > PAGE;
  const rows = hasMore ? data.slice(0, PAGE) : data;

  if (!append && rows.length === 0) {
    statusEl.textContent = `No matches for “${term}”.`;
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

let debounce;
qEl.addEventListener("input", () => {
  clearTimeout(debounce);
  const term = qEl.value.trim();
  debounce = setTimeout(() => {
    const url = new URL(location.href);
    if (term) url.searchParams.set("q", term); else url.searchParams.delete("q");
    history.replaceState(null, "", url);

    if (term.length < 3) {
      seq++;
      resultsEl.innerHTML = "";
      moreEl.innerHTML = "";
      statusEl.className = "empty";
      statusEl.textContent = term.length
        ? "Keep typing — at least 3 characters."
        : "Start typing to search 285,947 properties.";
      return;
    }
    currentQuery = term;
    runSearch(term);
  }, 280);
});

// restore a search from the URL (back button, shared link)
const initial = new URLSearchParams(location.search).get("q");
if (initial && configured) {
  qEl.value = initial;
  currentQuery = initial.trim();
  if (currentQuery.length >= 3) runSearch(currentQuery);
}
