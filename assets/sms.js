import { esc, clean, cityLine, monthLabel, propertyHref } from "./db.js";
import { initLogPage } from "./logpage.js";

initLogPage({
  navKey: "sms",
  noun: "text", nouns: "texts",
  rpcFacets: "list_sms_approaches",
  rpcPeriods: "list_sms_periods",
  rpcSearch: "search_sms",
  rpcCount: "count_sms",
  facetParam: "p_approach",
  facetUrlKey: "a",
  // the value is the case-folded key, so 'Ghost' and 'ghost' are one approach
  facetValue: (r) => r.approach,
  facetLabel: (r) => r.label,
  emptyList: "Nobody has been texted yet.",
  rowHtml: (r) => {
    const addr = clean(r.property_address) || "(no property address)";
    return `
      <div class="mail-row">
        <span class="addr">${r.in_buybox ? `<a href="${propertyHref(r.parcel)}">${esc(addr)}</a>` : esc(addr)}</span>
        <span class="who">${esc(clean(r.full_name))}</span>
        <span class="meta">${esc(cityLine(r.property_city, r.property_state, r.property_zip))}</span>
        <span class="tags">${r.approach ? `<span class="chip vendor">${esc(r.approach)}</span>` : ""}</span>
        <span class="meta">${esc(clean(r.parcel))}${r.in_buybox ? "" : " · not in Buybox"}</span>
        <span class="when${r.period ? "" : " none"}">${r.period ? esc(monthLabel(r.period, true)) : "no date"}</span>
      </div>`;
  }
});
