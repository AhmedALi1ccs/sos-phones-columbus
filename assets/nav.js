/** The left navigation, shared by every page so the tabs cannot drift apart. */

const TABS = [
  { key: "search",  href: "index.html",    icon: "🔎", label: "Search" },
  { key: "mailing", href: "mailed.html",   icon: "✉️", label: "Mailing" },
  { key: "calls",   href: "coldcalling.html", icon: "📞", label: "Cold calling" },
  { key: "remove",  href: "settings.html", icon: "🗂", label: "Remove" }
];

const KEY = "sos.sidebar";

function collapsed() {
  try { return localStorage.getItem(KEY) === "1"; } catch { return false; }
}
function setCollapsed(v) {
  document.body.classList.toggle("sidebar-collapsed", v);
  const btn = document.getElementById("sideToggle");
  if (btn) {
    btn.textContent = v ? "»" : "«";
    btn.title = v ? "Expand sidebar" : "Collapse sidebar";
    btn.setAttribute("aria-label", btn.title);
    btn.setAttribute("aria-expanded", String(!v));
  }
  try { localStorage.setItem(KEY, v ? "1" : "0"); } catch { /* private mode */ }
}

export function mountSidebar(active) {
  const aside = document.getElementById("sidebar");
  if (!aside) return;

  aside.innerHTML = `
    <button class="sidetoggle" id="sideToggle" type="button">«</button>
    <nav class="navtabs">
      ${TABS.map((t) => `
        <a class="navtab${t.key === active ? " active" : ""}" href="${t.href}" title="${t.label}">
          <span class="ico">${t.icon}</span><span class="lbl">${t.label}</span>
        </a>`).join("")}
    </nav>`;

  setCollapsed(collapsed());
  document.getElementById("sideToggle")
    .addEventListener("click", () => setCollapsed(!document.body.classList.contains("sidebar-collapsed")));
}
