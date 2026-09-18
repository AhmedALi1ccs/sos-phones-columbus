import {
  db, configured, configBanner, esc, clean, digits, fmtPhone, cityLine, splitList,
  chipsHtml, fmtSaleDate, relTime, getWho, mountWho, toast, STATUS, NO_STATUS
} from "./db.js";

const MAX_PHONES = 30;

const titleEl = document.getElementById("title");
const subEl   = document.getElementById("subtitle");
const bodyEl  = document.getElementById("body");

mountWho(document.getElementById("whoHost"));

// keep the user's search when they go back
const backHref = document.referrer.includes("index.html") ? document.referrer : "index.html";
document.getElementById("back").href = backHref;

const id = new URLSearchParams(location.search).get("id");

if (!configured) {
  configBanner(document.getElementById("banner"));
  titleEl.textContent = "Not connected";
} else if (!id) {
  titleEl.textContent = "No property selected";
  bodyEl.innerHTML = `<p class="hint"><a href="index.html">Go back to search</a></p>`;
} else {
  load(id);
}

let property = null;
let phones = [];

async function load(propId) {
  const { data: prop, error } = await db
    .from("BuyBox").select("*").eq("id", propId).maybeSingle();

  if (error)  { titleEl.textContent = "Error"; bodyEl.innerHTML = `<div class="err">${esc(error.message)}</div>`; return; }
  if (!prop)  { titleEl.textContent = "Property not found"; bodyEl.innerHTML = `<p class="hint"><a href="index.html">Back to search</a></p>`; return; }

  property = prop;
  renderHead();
  renderBody();
  loadPhones();
  loadMailed();
}

function renderHead() {
  const p = property;
  titleEl.textContent = clean(p["Property address"]) || "(no property address)";
  const bits = [cityLine(p["Property city"], p["Property state"], p["Property zip"])];
  if (clean(p["Property county"])) bits.push(clean(p["Property county"]) + " County");
  if (clean(p.FOLIO)) bits.push(clean(p.FOLIO));
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
  const lists = splitList(p.Lists);
  const tags  = splitList(p.Tag);

  bodyEl.innerHTML = `
    <div class="grid">
      <section class="card panel">
        <h2>Owner</h2>
        ${kv([["Full name", p["Full Name"]], ["First", p["First Name"]], ["Last", p["Last Name"]], ["Folio", p.FOLIO]])}
      </section>

      <section class="card panel">
        <h2>Property address</h2>
        ${kv([
          ["Address", p["Property address"]],
          ["City", p["Property city"]],
          ["State", p["Property state"]],
          ["Zip", p["Property zip"]],
          ["County", p["Property county"]]
        ])}
      </section>

      <section class="card panel">
        <h2>Mailing address</h2>
        ${kv([
          ["Address", p["Mailing address"]],
          ["City", p["Mailing city"]],
          ["State", p["Mailing state"]],
          ["Zip", p["Mailing zip"]]
        ])}
      </section>

      <section class="card panel">
        <h2>Record</h2>
        ${kv([["Sale date", fmtSaleDate(p["Sale Date"])], ["Sale price", clean(p["Sale Price"]) && clean(p["Sale Price"]) !== "0" ? "$" + Number(p["Sale Price"]).toLocaleString() : ""]])}
        <div style="margin-top:12px" id="mailedBox">
          <span class="badge no">Checking mail history…</span>
        </div>
      </section>
    </div>

    <section class="section">
      <h2>Lists / distresses</h2>
      <div class="card panel">
        ${lists.length ? `<div class="chips">${chipsHtml(lists, "chip on")}</div>` : `<span class="hint">No lists on this record.</span>`}
        ${tags.length ? `<div style="margin-top:14px"><h2 style="margin-bottom:8px">Tag history</h2><div class="chips">${chipsHtml(tags)}</div></div>` : ""}
      </div>
    </section>

    <section class="section">
      <h2>Phone numbers <span id="phoneCount" class="hint"></span></h2>
      <div class="card phones" id="phones">
        <div class="phone-row"><span class="skeleton" style="width:200px"></span></div>
      </div>
    </section>

    <p class="hint" style="margin-top:14px">
      ${STATUS.correct.symbol} Correct &nbsp;·&nbsp; ${STATUS.wrong.symbol} Wrong number &nbsp;·&nbsp;
      ${STATUS.dead.symbol} Dead line &nbsp;·&nbsp; ${NO_STATUS.symbol} not checked yet.
      Click a symbol to set it, click it again to clear.
    </p>`;
}

/* ------------------------------- mailed ------------------------------- */
async function loadMailed() {
  const p = property;
  const box = document.getElementById("mailedBox");
  let q = db.from("Mailed").select('"FOLIO","Check","Type","Property address"').limit(5);

  if (clean(p.FOLIO)) q = q.eq("FOLIO", p.FOLIO);
  else if (clean(p["Property address"])) {
    q = q.eq("Property address", p["Property address"]).eq("Property zip", clean(p["Property zip"]));
  } else { box.innerHTML = `<span class="badge no">No mail history</span>`; return; }

  const { data, error } = await q;
  if (error) { box.innerHTML = `<span class="badge no">Mail history unavailable</span>`; return; }

  if (!data || data.length === 0) {
    box.innerHTML = `<span class="badge no">✉️ Not mailed</span>`;
    return;
  }
  const kinds = [...new Set(data.map((r) => clean(r.Type)).filter(Boolean))];
  const checks = [...new Set(data.map((r) => clean(r.Check)).filter(Boolean))];
  box.innerHTML = `<span class="badge yes">✉️ Mailed${data.length > 1 ? ` ×${data.length}` : ""}</span>
    ${kinds.length ? `<div class="chips" style="margin-top:8px">${chipsHtml(kinds)}</div>` : ""}
    ${checks.length ? `<div class="chips" style="margin-top:6px">${chipsHtml(checks.map((c) => "Check: " + c))}</div>` : ""}`;
}

/* ------------------------------- phones ------------------------------- */
async function loadPhones() {
  const { data, error } = await db
    .from("property_phones")
    .select("*")
    .eq("property_id", property.id)
    .order("slot", { ascending: true, nullsFirst: false })
    .order("id", { ascending: true });

  if (error) {
    document.getElementById("phones").innerHTML = `<div class="phone-row"><span class="err">${esc(error.message)}</span></div>`;
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
      <a class="num ${st === "dead" || st === "wrong" ? "struck" : ""}" href="tel:${esc(digits(ph.phone))}">${esc(fmtPhone(ph.phone))}</a>
      ${clean(ph.label) ? `<span class="label">${esc(ph.label)}</span>` : `<span class="label"></span>`}
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
                   : `<div class="phone-row"><span class="hint">No phone numbers yet for this property.</span></div>`) +
    `<form class="addform" id="addForm">
       <input type="tel"  class="tel" id="newPhone" placeholder="Add phone number" ${full ? "disabled" : ""}>
       <input type="text" class="lbl" id="newLabel" placeholder="label (optional)" ${full ? "disabled" : ""}>
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
    .eq("id", phoneId)
    .select()
    .single();
  rowBusy(phoneId, false);

  if (error) { toast(error.message, true); return; }
  Object.assign(ph, data);
  renderPhones();
  toast(next ? `${STATUS[next].symbol} ${STATUS[next].label}` : "Status cleared");
}

async function saveNote(phoneId, note) {
  const { error } = await db
    .from("property_phones")
    .update({ note: note.trim() || null, updated_by: getWho() || null })
    .eq("id", phoneId);
  if (error) toast(error.message, true); else toast("Note saved");
}

async function addPhone(ev) {
  ev.preventDefault();
  const input = document.getElementById("newPhone");
  const labelEl = document.getElementById("newLabel");
  const raw = input.value.trim();
  const d = digits(raw);

  if (d.length < 7) { toast("That does not look like a phone number", true); return; }
  if (phones.some((p) => digits(p.phone) === d)) { toast("Already listed on this property", true); return; }

  const slot = phones.reduce((m, p) => Math.max(m, p.slot || 0), 0) + 1;
  const { data, error } = await db
    .from("property_phones")
    .insert({
      property_id: property.id,
      phone: fmtPhone(raw) || raw,
      label: labelEl.value.trim() || null,
      slot,
      updated_by: getWho() || null
    })
    .select()
    .single();

  if (error) {
    toast(error.code === "23505" ? "That number is already on this property" : error.message, true);
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
  if (!confirm(`Remove ${fmtPhone(ph.phone)} from this property?`)) return;

  rowBusy(phoneId, true);
  const { error } = await db.from("property_phones").delete().eq("id", phoneId);
  if (error) { rowBusy(phoneId, false); toast(error.message, true); return; }
  phones = phones.filter((p) => p.id !== phoneId);
  renderPhones();
  toast("Phone removed");
}
