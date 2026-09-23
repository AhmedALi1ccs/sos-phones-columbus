import { db, configured, configBanner, esc, clean, getWho, mountWho, toast, relTime } from "./db.js";
import { mountSidebar } from "./nav.js";

const FIELDS = {
  folio:   { label: "Parcel Number", placeholder: "e.g. F# 077G222",
             hint: "Matches the parcel number, with or without the “F# ” prefix." },
  address: { label: "Address",      placeholder: "e.g. 308 Cedar Rock Mdws",
             hint: "Matches the property address exactly, ignoring case and street-word spelling. " +
                   "An address shared by several properties removes all of them." },
  zip:     { label: "Property zip", placeholder: "e.g. 30906",
             hint: "Matches the property zip exactly. A single zip can cover tens of thousands of records." }
};

const fieldEl   = document.getElementById("field");
const valueEl   = document.getElementById("value");
const hintEl    = document.getElementById("fieldHint");
const removeBtn = document.getElementById("removeBtn");
const listEl    = document.getElementById("removals");

const backEl    = document.getElementById("modalBack");
const countEl   = document.getElementById("modalCount");
const bodyEl    = document.getElementById("modalBody");
const confirmBtn = document.getElementById("confirmBtn");
const cancelBtn  = document.getElementById("cancelBtn");

mountSidebar("remove");
mountWho(document.getElementById("whoHost"));

function applyField() {
  const f = FIELDS[fieldEl.value];
  valueEl.placeholder = f.placeholder;
  hintEl.textContent = f.hint;
}
fieldEl.addEventListener("change", applyField);
applyField();

if (!configured) {
  configBanner(document.getElementById("banner"));
  [fieldEl, valueEl, removeBtn].forEach((el) => (el.disabled = true));
  listEl.innerHTML = "";
}

/* ------------------------------ confirmation ------------------------------ */
let onConfirm = null;

function openModal({ count, title, body, confirmLabel }) {
  document.getElementById("modalTitle").textContent = title;
  countEl.textContent = count;
  bodyEl.innerHTML = body;
  confirmBtn.textContent = confirmLabel;
  backEl.hidden = false;
  cancelBtn.focus();
}

function closeModal() {
  backEl.hidden = true;
  onConfirm = null;
  confirmBtn.disabled = false;
}

cancelBtn.addEventListener("click", closeModal);
backEl.addEventListener("click", (e) => { if (e.target === backEl) closeModal(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !backEl.hidden) closeModal(); });

confirmBtn.addEventListener("click", async () => {
  if (!onConfirm) return;
  confirmBtn.disabled = true;
  const fn = onConfirm;
  await fn();
  closeModal();
});

/* -------------------------------- removal -------------------------------- */
async function askToRemove() {
  const field = fieldEl.value;
  const value = valueEl.value.trim();
  if (!value) { toast("Enter a value to match on", true); valueEl.focus(); return; }

  removeBtn.disabled = true;
  removeBtn.textContent = "Counting…";
  const { data, error } = await db.rpc("count_removal", { p_field: field, p_value: value });
  removeBtn.disabled = false;
  removeBtn.textContent = "Remove…";

  if (error) { toast(error.message, true); return; }

  const n = Number(data) || 0;
  if (n === 0) {
    toast(`No records match that ${FIELDS[field].label.toLowerCase()}`, true);
    return;
  }

  openModal({
    count: `${n.toLocaleString()} record${n === 1 ? "" : "s"}`,
    title: "Are you sure?",
    body: `This will be removed from <b>BuyBox</b> where ${esc(FIELDS[field].label)} is
           <b>${esc(value)}</b>, and moved to <b>notBuyBox</b>.<br><br>
           Phone numbers are kept, and the removal can be undone from
           “Recently removed” below.`,
    confirmLabel: `Yes, remove ${n.toLocaleString()}`
  });

  onConfirm = async () => {
    const { data: moved, error: err } = await db.rpc("remove_from_buybox", {
      p_field: field, p_value: value, p_by: getWho() || null
    });
    if (err) { toast(err.message, true); return; }
    toast(`Moved ${Number(moved).toLocaleString()} record(s) to notBuyBox`);
    valueEl.value = "";
    loadRemovals();
  };
}

removeBtn.addEventListener("click", askToRemove);
valueEl.addEventListener("keydown", (e) => { if (e.key === "Enter") askToRemove(); });

/* ---------------------------- recently removed ---------------------------- */
async function loadRemovals() {
  const { data, error } = await db.rpc("list_removals", { max_rows: 25 });
  if (error) {
    listEl.innerHTML = `<div class="phone-row"><span class="err">${esc(error.message)}</span></div>`;
    return;
  }
  if (!data.length) {
    listEl.innerHTML = `<div class="phone-row"><span class="hint">Nothing has been removed yet.</span></div>`;
    return;
  }

  listEl.innerHTML = data.map((r) => `
    <div class="removal-row">
      <span class="what">${esc(FIELDS[r.match_field]?.label || r.match_field)}: ${esc(clean(r.match_value))}</span>
      <span class="chip">${Number(r.n_records).toLocaleString()} record${r.n_records === 1 ? "" : "s"}</span>
      <span class="grow"></span>
      <span class="meta">${esc(clean(r.removed_by) || "—")} · ${esc(relTime(r.removed_at))}</span>
      <button class="btn ghost" data-field="${esc(r.match_field)}"
              data-value="${esc(clean(r.match_value))}" data-n="${r.n_records}">Restore</button>
    </div>`).join("");

  listEl.querySelectorAll("button[data-field]").forEach((b) =>
    b.addEventListener("click", () => askToRestore(b.dataset.field, b.dataset.value, Number(b.dataset.n))));
}

function askToRestore(field, value, n) {
  openModal({
    count: `${n.toLocaleString()} record${n === 1 ? "" : "s"}`,
    title: "Put these back?",
    body: `They will move from <b>notBuyBox</b> back into <b>BuyBox</b>, under the ids
           they had before, and reappear in search.`,
    confirmLabel: `Yes, restore ${n.toLocaleString()}`
  });
  countEl.style.color = "var(--good)";

  onConfirm = async () => {
    const { data, error } = await db.rpc("restore_to_buybox", { p_field: field, p_value: value });
    countEl.style.color = "";
    if (error) { toast(error.message, true); return; }
    toast(`Restored ${Number(data).toLocaleString()} record(s) to BuyBox`);
    loadRemovals();
  };
}

if (configured) loadRemovals();
