import { esc, clean, cityLine, fmtMoney, monthLabel, propertyHref } from "./db.js";
import { initLogPage } from "./logpage.js";

initLogPage({
  navKey: "mailing",
  noun: "mailing", nouns: "mailings",
  rpcFacets: "list_mail_tags",
  rpcPeriods: "list_mail_periods",
  rpcSearch: "search_mail",
  rpcCount: "count_mail",
  facetParam: "p_tag",
  facetUrlKey: "t",
  facetValue: (r) => r.tag,
  facetLabel: (r) => r.tag,
  emptyList: "Nothing has been mailed yet.",
  rowHtml: (r) => {
    const addr = clean(r.property_address) || "(no property address)";
    return `
      <div class="mail-row">
        <span class="addr">${r.in_buybox ? `<a href="${propertyHref(r.parcel)}">${esc(addr)}</a>` : esc(addr)}</span>
        <span class="who">${esc(clean(r.full_name))}</span>
        <span class="meta">${esc(cityLine(r.property_city, r.property_state, r.property_zip))}</span>
        <span class="tags">${r.tag ? `<span class="chip vendor">${esc(r.tag)}</span>` : ""}</span>
        <span class="meta">${esc(fmtMoney(r.check_value))}${r.in_buybox ? "" : " · not in Buybox"}</span>
        <span class="when${r.period ? "" : " none"}">${
          r.period ? esc(monthLabel(r.period, true)) : esc(clean(r.mail_date) || "no date")}</span>
      </div>`;
  }
});
