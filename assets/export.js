import { db, clean, toast } from "./db.js";

// 500, not 1000: each row normalises its address to find its phone numbers,
// and 1000 rows came within half a second of the public key's 3s timeout
const PAGE_SIZE = 500;
export const EXPORT_CAP = 50000;   // a browser-built CSV has to stay in memory
const CAP = EXPORT_CAP;
const MAX_PHONE_COLS = 30;

const csvCell = (v) => {
  const s = v === null || v === undefined ? "" : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** One row per property, phones flattened into columns like the import format. */
export function toCsv(rows) {
  const phoneCols = Math.min(
    MAX_PHONE_COLS,
    rows.reduce((m, r) => Math.max(m, (r.phones || []).length), 0)
  );

  const head = [
    "Parcel Number", "Full Name", "First Name", "Last Name",
    "Property address", "Property city", "Property state", "Property zip",
    "Mailing address", "Mailing city", "Mailing state", "Mailing zip",
    "Appraised Value", "Sale Date", "Sale Price", "Lists", "Phone count"
  ];
  for (let i = 1; i <= phoneCols; i++) head.push(`Phone ${i}`, `Phone ${i} Type`, `Phone ${i} Status`);

  const lines = [head.map(csvCell).join(",")];
  for (const r of rows) {
    const phones = r.phones || [];
    const cells = [
      r.parcel, r.full_name, r.first_name, r.last_name,
      r.property_address, r.property_city, r.property_state, r.property_zip,
      r.mailing_address, r.mailing_city, r.mailing_state, r.mailing_zip,
      r.appraised_value, r.sale_date, r.sale_price, r.distress_lists, phones.length
    ];
    for (let i = 0; i < phoneCols; i++) {
      const p = phones[i];
      cells.push(p ? p.phone : "", p ? p.type || "" : "", p ? p.status || "" : "");
    }
    lines.push(cells.map(csvCell).join(","));
  }
  return "﻿" + lines.join("\r\n");   // BOM so Excel reads UTF-8 correctly
}

function download(text, filename) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function filename(query, field, keys) {
  const bits = ["sos-phones"];
  if (keys.length) bits.push(keys.join("+").replace(/[^a-z0-9+]+/gi, "-"));
  if (clean(query)) bits.push(`${field}-${clean(query)}`.replace(/[^a-z0-9-]+/gi, "-"));
  bits.push(new Date().toISOString().slice(0, 10));
  return bits.join("_").slice(0, 120) + ".csv";
}

/**
 * Pages through export_properties and hands back a CSV.
 * onProgress(n) is called after each page so the button can show a count.
 */
export async function exportCsv({ query, field, keys, onProgress }) {
  const rows = [];
  let skip = 0;

  while (rows.length < CAP) {
    const { data, error } = await db.rpc("export_properties", {
      q: query || null,
      field: field,
      p_lists: keys.length ? keys : null,
      max_rows: PAGE_SIZE,
      skip
    });
    if (error) { toast(error.message, true); return null; }

    rows.push(...data);
    onProgress(rows.length);
    if (data.length < PAGE_SIZE) break;
    skip += data.length;
  }

  if (!rows.length) { toast("Nothing to export", true); return null; }

  const hitCap = rows.length >= CAP;
  download(toCsv(rows), filename(query, field, keys));
  return { count: rows.length, hitCap };
}
