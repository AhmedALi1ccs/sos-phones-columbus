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
      publishable key (Supabase dashboard → Project Settings → API).
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

/** Must match parcel_norm() in sql/01_schema.sql exactly. */
export function parcelKey(p) {
  return String(p ?? "").replace(/[^A-Za-z0-9]/g, "").toUpperCase();
}

/** The href for a property: keyed by parcel number, so it survives a Buybox reload. */
export function propertyHref(parcel) {
  return "property.html?parcel=" + encodeURIComponent(clean(parcel));
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

/** Sale Date arrives as ISO ("2021-12-02"), an Excel serial ("44362") or junk ("0000-00-00"). */
export function fmtSaleDate(raw) {
  const s = clean(raw);
  if (!s || !/[1-9]/.test(s.replace(/[-/]/g, ""))) return "";
  if (/^\d{4,6}$/.test(s)) {
    const n = Number(s);
    if (n > 20000 && n < 60000) {
      const d = new Date(Date.UTC(1899, 11, 30) + n * 86400000);
      return d.toISOString().slice(0, 10);
    }
  }
  return s;
}

/** "407000" or "$150,400 " -> "$407,000"; nothing for blanks and zeros. */
export function fmtMoney(raw) {
  const s = clean(raw);
  const n = Number(s.replace(/[$,\s]/g, ""));
  if (!s || !Number.isFinite(n) || n === 0) return "";
  return "$" + n.toLocaleString();
}

const MONTHS = ["January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December"];

/** "2026-07-01" -> "July 2026"; short -> "Jul 2026". */
export function monthLabel(iso, short = false) {
  if (!iso) return "";
  const [y, m] = String(iso).split("-").map(Number);
  const name = MONTHS[m - 1] || "";
  return `${short ? name.slice(0, 3) : name} ${y}`;
}

/** A Postgres statement timeout, as opposed to any other failure. */
export function isTimeout(error) {
  return Boolean(error) && (error.code === "57014" || /statement timeout/i.test(error.message || ""));
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
