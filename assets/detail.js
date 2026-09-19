import {
  db, configured, configBanner, esc, clean, digits, fmtPhone, cityLine, splitList,
  chipsHtml, fmtSaleDate, relTime, folioKey, countyKey, getWho, mountWho, toast,
  STATUS, NO_STATUS, PHONE_TYPE
} from "./db.js";

const MAX_PHONES = 30;

const titleEl = document.getElementById("title");
const subEl   = document.getElementById("subtitle");
const bodyEl  = document.getElementById("body");

mountWho(document.getElementById("whoHost"));
document.getElementById("back").href =
  document.referrer.includes("index.html") ? document.referrer : "index.html";

const params = new URLSearchParams(location.search);
const qFolio  = params.get("folio");
const qCounty = params.get("county");
const qId     = params.get("id");

let property = null;   // normalised, snake_case
let phones   = [];

if (!configured) {
  configBanner(document.getElementById("banner"));
  titleEl.textContent = "Not connected";
} else if (!qFolio && !qId) {
  titleEl.textContent = "No property selected";
  bodyEl.innerHTML = `<p class="hint"><a href="index.html">Go back to search</a></p>`;
} else {
  load();
}

async function load() {
  const res = qFolio ? await loadByFolio() : await loadById();
  if (!res) return;

  property = res;
  renderHead();
  renderBody();
  if (property.folio) { loadPhones(); loadMailed(); }
}

async function loadByFolio() {
  const { data, error } = await db.rpc("get_property", { p_folio: qFolio, p_county: qCounty });
  if (error) { fail(error.message); return null; }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) { notFound(); return null; }
  return row;
}

/** Fallback for the ~712 BuyBox rows that carry no FOLIO. */
async function loadById() {
  const { data, error } = await db.from("BuyBox").select("*").eq("id", qId).maybeSingle();
  if (error) { fail(error.message); return null; }
  if (!data) { notFound(); return null; }
  return {
    id: data.id, folio: clean(data.FOLIO), county: clean(data["Property county"]),
    full_name: data["Full Name"], first_name: data["First Name"], last_name: data["Last Name"],
    property_address: data["Property address"], property_city: data["Property city"],
    property_state: data["Property state"], property_zip: data["Property zip"],
    mailing_address: data["Mailing address"], mailing_city: data["Mailing city"],
    mailing_state: data["Mailing state"], mailing_zip: data["Mailing zip"],
    sale_date: data["Sale Date"], sale_price: data["Sale Price"],
    lists: data.Lists, tag: data.Tag, match_count: 1
  };
}

function fail(msg) {
  titleEl.textContent = "Error";
  bodyEl.innerHTML = `<div class="err">${esc(msg)}</div>`;
}
function notFound() {
  titleEl.textContent = "Property not found";
  bodyEl.innerHTML = `<p class="hint">That parcel is not in BuyBox. <a href="index.html">Back to search</a></p>`;
}

function renderHead() {
  const p = property;
  titleEl.textContent = clean(p.property_address) || "(no property address)";
  const bits = [cityLine(p.property_city, p.property_state, p.property_zip)];
  if (clean(p.county)) bits.push(clean(p.county) + " County");
  if (clean(p.folio)) bits.push(clean(p.folio));
  subEl.textContent = bits.filter(Boolean).join("  ·  ");
  document.title = `${titleEl.textContent} — SOS Phones`;
}

function kv(pairs) {
  return `<dl class="kv">${pairs
    .filter(([, v]) => clean(v))
    .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(clean(v))}</dd>`)
    .join("")}</dl>`;
}

function renderBody() {
  const p = property;
  const lists = splitList(p.lists);
  const tags  = splitList(p.tag);
  const price = clean(p.sale_price);

  bodyEl.innerHTML = `
    ${Number(p.match_count) > 1 ? `<div class="err">
       <strong>Ambiguous parcel number.</strong> ${esc(clean(p.folio))} is used by
       ${esc(String(p.match_count))} different properties (parcel numbers repeat across counties).
       Showing the first — open it from search to land on the right one.</div>` : ""}
    ${!clean(p.folio) ? `<div class="err">
       <strong>This record has no FOLIO.</strong> Phone numbers are filed by parcel number,
       so none can be attached to this row until it gets one.</div>` : ""}

    <div class="grid">
      <section class="card panel">
        <h2>Owner</h2>
        ${kv([["Full name", p.full_name], ["First", p.first_name], ["Last", p.last_name], ["Folio", p.folio]])}
      </section>

      <section class="card panel">
        <h2>Property address</h2>
        ${kv([["Address", p.property_address], ["City", p.property_city],
              ["State", p.property_state], ["Zip", p.property_zip], ["County", p.county]])}
      </section>

      <section class="card panel">
        <h2>Mailing address</h2>
        ${kv([["Address", p.mailing_address], ["City", p.mailing_city],
              ["State", p.mailing_state], ["Zip", p.mailing_zip]])}
      </section>

      <section class="card panel">
        <h2>Record</h2>
        ${kv([["Sale date", fmtSaleDate(p.sale_date)],
              ["Sale price", price && price !== "0" && !isNaN(Number(price)) ? "$" + Number(price).toLocaleString() : ""]])}
        <div style="margin-top:12px" id="mailedBox">
          ${clean(p.folio) ? `<span class="badge no">Checking mail history…</span>`
                           : `<span class="badge no">✉️ No mail history</span>`}
        </div>
      </section>
    </div>

    <section class="section">
      <h2>Lists / distresses</h2>
      <div class="card panel">
        ${lists.length ? `<div class="chips">${chipsHtml(lists, "chip on")}</div>`
                       : `<span class="hint">No lists on this record.</span>`}
        ${tags.length ? `<div style="margin-top:14px"><h2 style="margin-bottom:8px">Tag history</h2>
                          <div class="chips">${chipsHtml(tags)}</div></div>` : ""}
      </div>
    </section>

    <section class="section">
      <h2>Phone numbers <span id="phoneCount" class="hint"></span></h2>
      <div class="card phones" id="phones">
        ${clean(p.folio) ? `<div class="phone-row"><span class="skeleton" style="width:200px"></span></div>`
                         : `<div class="phone-row"><span class="hint">Unavailable — this record has no parcel number.</span></div>`}
      </div>
    </section>

    <p class="hint" style="margin-top:14px">
      ${STATUS.correct.symbol} Correct &nbsp;·&nbsp; ${STATUS.wrong.symbol} Wrong number &nbsp;·&nbsp;
      ${STATUS.dead.symbol} Dead line &nbsp;·&nbsp; ${NO_STATUS.symbol} not checked yet.
      Click a symbol to set it, click it again to clear.
      Line type is ${PHONE_TYPE.mobile.symbol} mobile or ${PHONE_TYPE.landline.symbol} landline.
    </p>`;
}

/* ------------------------------- mailed ------------------------------- */
async function loadMailed() {
  const box = document.getElementById("mailedBox");
  const { data, error } = await db.rpc("get_mail_history", { p_folio: property.folio });

  if (error)               { box.innerHTML = `<span class="badge no">Mail history unavailable</span>`; return; }
  if (!data || !data.length) { box.innerHTML = `<span class="badge no">✉️ Not mailed</span>`; return; }

  const kinds = [...new Set(data.map((r) => clean(r.mail_type)).filter(Boolean))];
  box.innerHTML =
    `<span class="badge yes">✉️ Mailed ×${data.length}</span>` +
    (kinds.length ? `<div class="chips" style="margin-top:8px">${chipsHtml(kinds)}</div>` : "");
}

/* ------------------------------- phones ------------------------------- */
function phoneFilter(query) {
  return query
    .eq("folio_key",  folioKey(property.folio))
    .eq("county_key", countyKey(property.county));
}

async function loadPhones() {
  const { data, error } = await phoneFilter(db.from("property_phones").select("*"))
    .order("slot", { ascending: true, nullsFirst: false })
    .order("id", { ascending: true });

  if (error) {
    document.getElementById("phones").innerHTML =
      `<div class="phone-row"><span class="err">${esc(error.message)}</span></div>`;
    return;
  }
  phones = data || [];
  renderPhones();
}

function phoneRowHtml(ph) {
  const st = ph.status;
  const buttons = Object.entries(STATUS).map(([key, v]) =>
    `<button class="sbtn" data-s="${key}" data-id="${ph.id}" aria-pressed="${st === key}"
             title="${v.label}">${v.symbol}</button>`).join("");
  return `
    <div class="phone-row" data-row="${ph.id}">
      <a class="num ${st === "dead" || st === "wrong" ? "struck" : ""}"
         href="tel:${esc(digits(ph.phone))}">${esc(fmtPhone(ph.phone))}</a>
      <select class="typesel" data-type="${ph.id}" title="Line type">
        <option value=""${!clean(ph.phone_type) ? " selected" : ""}>—</option>
        ${Object.entries(PHONE_TYPE).map(([k, v]) =>
          `<option value="${k}"${ph.phone_type === k ? " selected" : ""}>${v.symbol} ${v.label}</option>`).join("")}
      </select>
      <span class="statusgroup">${buttons}</span>
      <span class="note"><input type="text" data-note="${ph.id}" value="${esc(ph.note || "")}" placeholder="note…"></span>
      <span class="meta">${ph.status && ph.updated_at ? `${esc(clean(ph.updated_by) || "—")} · ${esc(relTime(ph.updated_at))}` : ""}</span>
      <button class="iconbtn" data-del="${ph.id}" title="Remove this number">✕</button>
    </div>`;
}

function renderPhones() {
  const host = document.getElementById("phones");
  const full = phones.length >= MAX_PHONES;

  host.innerHTML =
    (phones.length ? phones.map(phoneRowHtml).join("")
                   : `<div class="phone-row"><span class="hint">No phone numbers yet for this parcel.</span></div>`) +
    `<form class="addform" id="addForm">
       <input type="tel"  class="tel" id="newPhone" placeholder="Add phone number" ${full ? "disabled" : ""}>
       <select class="typesel" id="newType" ${full ? "disabled" : ""}>
         <option value="">— type —</option>
         ${Object.entries(PHONE_TYPE).map(([k, v]) => `<option value="${k}">${v.symbol} ${v.label}</option>`).join("")}
       </select>
       <button class="btn" type="submit" ${full ? "disabled" : ""}>Add</button>
       ${full ? `<span class="hint" style="align-self:center">Limit of ${MAX_PHONES} reached.</span>` : ""}
     </form>`;

  document.getElementById("phoneCount").textContent = `${phones.length} / ${MAX_PHONES}`;

  host.querySelectorAll(".sbtn").forEach((b) =>
    b.addEventListener("click", () => setStatus(Number(b.dataset.id), b.dataset.s)));
  host.querySelectorAll("[data-del]").forEach((b) =>
    b.addEventListener("click", () => removePhone(Number(b.dataset.del))));
  host.querySelectorAll("[data-note]").forEach((i) =>
    i.addEventListener("change", () => saveNote(Number(i.dataset.note), i.value)));
  host.querySelectorAll("[data-type]").forEach((sel) =>
    sel.addEventListener("change", () => saveType(Number(sel.dataset.type), sel.value)));

  document.getElementById("addForm").addEventListener("submit", addPhone);
}

function rowBusy(phoneId, busy) {
  const row = document.querySelector(`[data-row="${phoneId}"]`);
  if (row) row.classList.toggle("busy", busy);
}

async function setStatus(phoneId, status) {
  const ph = phones.find((p) => p.id === phoneId);
  if (!ph) return;
  const next = ph.status === status ? null : status;   // click again to clear

  rowBusy(phoneId, true);
  const { data, error } = await db
    .from("property_phones")
    .update({ status: next, updated_by: getWho() || null })
    .eq("id", phoneId).select().single();
  rowBusy(phoneId, false);

  if (error) { toast(error.message, true); return; }
  Object.assign(ph, data);
  renderPhones();
  toast(next ? `${STATUS[next].symbol} ${STATUS[next].label}` : "Status cleared");
}

async function saveType(phoneId, value) {
  const ph = phones.find((p) => p.id === phoneId);
  const next = value || null;
  rowBusy(phoneId, true);
  const { data, error } = await db.from("property_phones")
    .update({ phone_type: next, updated_by: getWho() || null })
    .eq("id", phoneId).select().single();
  rowBusy(phoneId, false);
  if (error) { toast(error.message, true); renderPhones(); return; }
  Object.assign(ph, data);
  toast(next ? `${PHONE_TYPE[next].symbol} ${PHONE_TYPE[next].label}` : "Type cleared");
}

async function saveNote(phoneId, note) {
  const { error } = await db.from("property_phones")
    .update({ note: note.trim() || null, updated_by: getWho() || null })
    .eq("id", phoneId);
  toast(error ? error.message : "Note saved", Boolean(error));
}

async function addPhone(ev) {
  ev.preventDefault();
  const input = document.getElementById("newPhone");
  const raw = input.value.trim();
  const d = digits(raw);

  if (d.length < 7) { toast("That does not look like a phone number", true); return; }
  if (phones.some((p) => digits(p.phone) === d)) { toast("Already listed on this parcel", true); return; }

  const slot = phones.reduce((m, p) => Math.max(m, p.slot || 0), 0) + 1;
  const { data, error } = await db.from("property_phones").insert({
      folio: property.folio,
      county: property.county || null,
      phone: fmtPhone(raw) || raw,
      phone_type: document.getElementById("newType").value || null,
      slot,
      updated_by: getWho() || null
    }).select().single();

  if (error) {
    toast(error.code === "23505" ? "That number is already on this parcel" : error.message, true);
    return;
  }
  phones.push(data);
  renderPhones();
  document.getElementById("newPhone").focus();
  toast("Phone added");
}

async function removePhone(phoneId) {
  const ph = phones.find((p) => p.id === phoneId);
  if (!ph) return;
  if (!confirm(`Remove ${fmtPhone(ph.phone)} from this parcel?`)) return;

  rowBusy(phoneId, true);
  const { error } = await db.from("property_phones").delete().eq("id", phoneId);
  if (error) { rowBusy(phoneId, false); toast(error.message, true); return; }
  phones = phones.filter((p) => p.id !== phoneId);
  renderPhones();
  toast("Phone removed");
}
