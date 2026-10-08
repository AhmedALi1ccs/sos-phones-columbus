import {
  db, configured, configBanner, esc, clean, digits, fmtPhone, cityLine, splitList,
  chipsHtml, fmtSaleDate, fmtMoney, monthLabel, relTime, getWho, mountWho, toast,
  STATUS, NO_STATUS, PHONE_TYPE
} from "./db.js";

const MAX_PHONES = 30;

const titleEl = document.getElementById("title");
const subEl   = document.getElementById("subtitle");
const bodyEl  = document.getElementById("body");

mountWho(document.getElementById("whoHost"));
document.getElementById("back").href =
  document.referrer.includes("index.html") ? document.referrer : "index.html";

const qParcel = new URLSearchParams(location.search).get("parcel");

let property = null;   // normalised, snake_case
let phones   = [];

if (!configured) {
  configBanner(document.getElementById("banner"));
  titleEl.textContent = "Not connected";
} else if (!qParcel) {
  titleEl.textContent = "No property selected";
  bodyEl.innerHTML = `<p class="hint"><a href="index.html">Go back to search</a></p>`;
} else {
  load();
}

async function load() {
  const { data, error } = await db.rpc("get_property", { p_parcel: qParcel });
  if (error) { fail(error.message); return; }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) { notFound(); return; }

  property = row;
  renderHead();
  renderBody();
  loadMailed(); loadSms(); loadColdCalls();
  if (hasStreetAddress()) loadPhones();
}

function fail(msg) {
  titleEl.textContent = "Error";
  bodyEl.innerHTML = `<div class="err">${esc(msg)}</div>`;
}
function notFound() {
  titleEl.textContent = "Property not found";
  bodyEl.innerHTML = `<p class="hint">That parcel is not in Buybox — it may have been removed.
    <a href="index.html">Back to search</a></p>`;
}

function renderHead() {
  const p = property;
  titleEl.textContent = clean(p.property_address) || "(no property address)";
  const bits = [cityLine(p.property_city, p.property_state, p.property_zip)];
  if (clean(p.parcel)) bits.push(clean(p.parcel));
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
  const tags  = splitList(p.tags);

  bodyEl.innerHTML = `
    <div class="grid">
      <section class="card panel">
        <h2>Owner</h2>
        ${kv([["Full name", p.full_name], ["First", p.first_name], ["Last", p.last_name], ["Parcel number", p.parcel]])}
      </section>

      <section class="card panel">
        <h2>Property address</h2>
        ${kv([["Address", p.property_address], ["City", p.property_city],
              ["State", p.property_state], ["Zip", p.property_zip]])}
      </section>

      <section class="card panel">
        <h2>Mailing address</h2>
        ${kv([["Address", p.mailing_address], ["City", p.mailing_city],
              ["State", p.mailing_state], ["Zip", p.mailing_zip]])}
      </section>

      <section class="card panel">
        <h2>Record</h2>
        ${kv([["Appraised value", fmtMoney(p.appraised_value)],
              ["Sale date", fmtSaleDate(p.sale_date)],
              ["Sale price", fmtMoney(p.sale_price)]])}
        <div style="margin-top:12px" id="mailedBox"><span class="badge no">Checking mail history…</span></div>
        <div style="margin-top:10px" id="smsBox"><span class="badge no">Checking SMS…</span></div>
        <div style="margin-top:10px" id="coldBox"><span class="badge no">Checking cold calling…</span></div>
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
      ${Number(p.address_records) > 1 ? `<p class="hint" style="margin:0 0 8px">
         Filed under the address <b>${esc(clean(p.property_address))}</b>, which
         ${(Number(p.address_records) - 1).toLocaleString()} other record${Number(p.address_records) === 2 ? "" : "s"}
         share — they all show these numbers.</p>` : ""}
      <div class="card phones" id="phones">
        ${hasStreetAddress()
          ? `<div class="phone-row"><span class="skeleton" style="width:200px"></span></div>`
          : `<div class="phone-row"><span class="hint">Unavailable — this record has no street address
             (“${esc(clean(p.property_address))}”), and phone numbers are filed by address.</span></div>`}
      </div>
    </section>

    <p class="hint" style="margin-top:14px">
      ${STATUS.correct.symbol} Correct &nbsp;·&nbsp; ${STATUS.wrong.symbol} Wrong number &nbsp;·&nbsp;
      ${STATUS.dead.symbol} Dead line &nbsp;·&nbsp; ${NO_STATUS.symbol} not checked yet.
      Click a symbol to set it, click it again to clear.
      Line type is ${PHONE_TYPE.mobile.symbol} mobile or ${PHONE_TYPE.landline.symbol} landline.
    </p>`;
}

/* --------------------------- mail and SMS --------------------------- */
/**
 * Both are logs loaded into Supabase as they happen: one chip per mailing or
 * text, saying what it was and when.
 */
async function loadHistory({ rpc, boxId, icon, had, none, chip }) {
  const box = document.getElementById(boxId);
  const { data, error } = await db.rpc(rpc, { p_parcel: property.parcel });

  if (error)               { box.innerHTML = `<span class="badge no">${icon} history unavailable</span>`; return; }
  if (!data || !data.length) { box.innerHTML = `<span class="badge no">${icon} ${esc(none)}</span>`; return; }

  const kinds = [...new Set(data.map(chip).filter(Boolean))];
  box.innerHTML =
    `<span class="badge yes">${icon} ${esc(had)} ×${data.length}</span>` +
    (kinds.length ? `<div class="chips" style="margin-top:8px">${chipsHtml(kinds)}</div>` : "");
}

const loadMailed = () => loadHistory({
  rpc: "get_mail_history", boxId: "mailedBox", icon: "✉️", had: "Mailed", none: "Not mailed",
  chip: (r) => [clean(r.tag), r.period ? monthLabel(r.period, true) : clean(r.mail_date),
                fmtMoney(r.check_value)].filter(Boolean).join(" · ")
});

const loadSms = () => loadHistory({
  rpc: "get_sms_history", boxId: "smsBox", icon: "💬", had: "Texted", none: "Not texted",
  chip: (r) => [clean(r.approach), r.period ? monthLabel(r.period, true)
                                            : [clean(r.month), clean(r.year)].join(" ").trim()]
                 .filter(Boolean).join(" · ")
});

/* ---------------------------- cold calling ---------------------------- */
async function loadColdCalls() {
  const box = document.getElementById("coldBox");
  const { data, error } = await db
    .from("ColdCalling")
    .select("phone, source")
    .eq("addr_key", property.addr_key)
    .order("source", { ascending: true, nullsFirst: false })
    .order("id", { ascending: true });

  if (error)        { box.innerHTML = `<span class="badge no">📞 Cold calling unavailable</span>`; return; }
  if (!data.length) { box.innerHTML = `<span class="badge no">📞 Not cold called</span>`; return; }

  const shown = data.slice(0, 8);
  box.innerHTML =
    `<span class="badge yes">📞 Cold called ×${data.length}</span>` +
    `<div class="chips" style="margin-top:8px">` +
    shown.map((c) => `
      <a class="chip tel" href="tel:${esc(digits(c.phone))}"
         title="${esc(clean(c.source) || "no source")}">${esc(fmtPhone(c.phone))}${
        clean(c.source) ? ` <span class="n">${esc(clean(c.source))}</span>` : ""}</a>`).join("") +
    (data.length > shown.length ? `<span class="chip">+${data.length - shown.length}</span>` : "") +
    `</div>`;
}

/* ------------------------------- phones ------------------------------- */
/** "0" and other placeholders are shared by thousands of records: no numbers there. */
function hasStreetAddress() {
  return /[A-Z]/.test(property.addr_key || "");
}

function phoneFilter(query) {
  return query.eq("addr_key", property.addr_key);
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
                   : `<div class="phone-row"><span class="hint">No phone numbers yet for this address.</span></div>`) +
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
  if (phones.some((p) => digits(p.phone) === d)) { toast("Already listed at this address", true); return; }

  const slot = phones.reduce((m, p) => Math.max(m, p.slot || 0), 0) + 1;
  const { data, error } = await db.from("property_phones").insert({
      address: property.property_address,
      phone: fmtPhone(raw) || raw,
      phone_type: document.getElementById("newType").value || null,
      slot,
      updated_by: getWho() || null
    }).select().single();

  if (error) {
    toast(error.code === "23505" ? "That number is already listed at this address" : error.message, true);
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
  if (!confirm(`Remove ${fmtPhone(ph.phone)} from this address?`)) return;

  rowBusy(phoneId, true);
  const { error } = await db.from("property_phones").delete().eq("id", phoneId);
  if (error) { rowBusy(phoneId, false); toast(error.message, true); return; }
  phones = phones.filter((p) => p.id !== phoneId);
  renderPhones();
  toast("Phone removed");
}
