import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0/+esm";

const cfg = window.SOS_CONFIG || {};

export const configured = Boolean(cfg.SUPABASE_URL && cfg.SUPABASE_KEY);

export const db = configured
  ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, { auth: { persistSession: false } })
  : null;

export function configBanner(host) {
  host.insertAdjacentHTML("afterbegin", `
    <div class="err">
      <strong>Not connected yet.</strong> Open <code>config.js</code> and paste your Supabase
      <code>anon</code> key (Supabase dashboard → Project Settings → API → anon / public).
    </div>`);
}

/* ---------- status vocabulary ---------- */
export const STATUS = {
  correct: { symbol: "✅", label: "Correct" },
  wrong:   { symbol: "❌", label: "Wrong" },
  dead:    { symbol: "💀", label: "Dead" }
};
export const NO_STATUS = { symbol: "○", label: "No status" };

/* ---------- line type ---------- */
export const PHONE_TYPE = {
  mobile:   { symbol: "📱", label: "Mobile" },
  landline: { symbol: "☎️", label: "Landline" }
};

/* ---------- small helpers ---------- */
export const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const clean = (s) => (s == null ? "" : String(s).trim());

/** Must match folio_norm()/county_norm() in sql/01_schema.sql exactly. */
export function folioKey(f) {
  return String(f ?? "").replace(/^\s*[Ff]\s*#\s*/, "").replace(/[^A-Za-z0-9]/g, "").toUpperCase();
}
export function countyKey(c) {
  return String(c ?? "").trim().toLowerCase();
}

/** The href for a property: keyed by parcel, so it survives a BuyBox reload. */
export function propertyHref(row) {
  const p = new URLSearchParams();
  if (clean(row.folio)) {
    p.set("folio", clean(row.folio));
    if (clean(row.county)) p.set("county", clean(row.county));
  } else {
    p.set("id", row.id);          // 712 rows have no FOLIO to key on
  }
  return "property.html?" + p.toString();
}

export function digits(s) {
  return clean(s).replace(/\D/g, "");
}

export function fmtPhone(s) {
  const d = digits(s);
  if (d.length === 10) return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
  if (d.length === 11 && d[0] === "1") return `(${d.slice(1, 4)}) ${d.slice(4, 7)}-${d.slice(7)}`;
  return clean(s);
}

export function cityLine(city, state, zip) {
  const left = [clean(city), clean(state)].filter(Boolean).join(", ");
  return [left, clean(zip)].filter(Boolean).join(" ");
}

/** "HIGH EQUITY,ABSENTEE" -> ["HIGH EQUITY","ABSENTEE"] */
export function splitList(s) {
  return clean(s).split(",").map((x) => x.trim()).filter(Boolean);
}

export function chipsHtml(items, cls = "chip") {
  return items.map((x) => `<span class="${cls}">${esc(x)}</span>`).join("");
}

/** Sale Date arrives either as an Excel serial ("44362") or junk ("0000-00-00"). */
export function fmtSaleDate(raw) {
  const s = clean(raw);
  if (!s || /^0+[-/]?/.test(s) && !/[1-9]/.test(s.replace(/[-/]/g, ""))) return "";
  if (/^\d{4,6}$/.test(s)) {
    const n = Number(s);
    if (n > 20000 && n < 60000) {
      const d = new Date(Date.UTC(1899, 11, 30) + n * 86400000);
      return d.toISOString().slice(0, 10);
    }
  }
  return s;
}

export function relTime(iso) {
  if (!iso) return "";
  const secs = (Date.now() - new Date(iso).getTime()) / 1000;
  const steps = [[60, "s"], [3600, "m"], [86400, "h"], [2592000, "d"]];
  if (secs < 60) return "just now";
  for (let i = 1; i < steps.length; i++) {
    if (secs < steps[i][0]) return `${Math.floor(secs / steps[i - 1][0])}${steps[i][1]} ago`;
  }
  return new Date(iso).toISOString().slice(0, 10);
}

/* ---------- who is editing (optional, stored locally) ---------- */
const WHO_KEY = "sos.who";
export function getWho() {
  try { return localStorage.getItem(WHO_KEY) || ""; } catch { return ""; }
}
export function setWho(v) {
  try { localStorage.setItem(WHO_KEY, v); } catch { /* private mode */ }
}
export function mountWho(host) {
  host.innerHTML = `<label class="who">Initials
    <input type="text" id="who" maxlength="16" placeholder="you" value="${esc(getWho())}"></label>`;
  host.querySelector("#who").addEventListener("input", (e) => setWho(e.target.value.trim()));
}

/* ---------- toast ---------- */
let toastEl, toastTimer;
export function toast(msg, bad = false) {
  if (!toastEl) {
    toastEl = document.createElement("div");
    toastEl.className = "toast";
    document.body.appendChild(toastEl);
  }
  toastEl.textContent = msg;
  toastEl.classList.toggle("bad", bad);
  toastEl.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove("show"), 2600);
}
