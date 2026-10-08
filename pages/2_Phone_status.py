"""
Set phone statuses — in bulk from a file, or one at a time.

A file carrying an address (or parcel number), a phone number and a status is
applied row by row: the status is changed if that number is already on the
property, and the number is added carrying the status if it is not. The same
pipeline as the phone uploader, so the two cannot disagree.
"""

import pandas as pd
import streamlit as st

from phone_import import MAX_PHONES, build_stage, run
from st_db import guess, read_upload, sidebar_connection
from status_update import NO_STATUS, STATUSES, apply_status, look_up, pretty_phone

st.set_page_config(page_title="SOS Phones — Phone status", page_icon="✅", layout="wide")

NONE = "— none —"
conn_params = sidebar_connection()

st.title("✅ Phone statuses")

bulk_tab, one_tab = st.tabs(["Upload a file", "One at a time"])

# ==========================================================================
# bulk
# ==========================================================================
with bulk_tab:
    st.caption(
        "A row whose number is already on the property has its status changed; "
        "a number that is not there yet is added carrying that status. "
        "Statuses are read as correct / wrong / dead — a blank one adds the number "
        "without claiming anything about it, and anything else is reported."
    )

    upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"], key="status_file")
    if not upload:
        st.info("Upload a file with **Property address** (or **Parcel Number**), **Phone** and "
                "**Status**. **Type** is optional.")
    else:
        df = read_upload(upload)
        st.success(f"Read **{len(df):,}** rows · {len(df.columns)} columns")
        with st.expander("Preview the file", expanded=True):
            st.dataframe(df.head(8), use_container_width=True)

        cols = list(df.columns)
        opts = [NONE] + cols
        st.subheader("Columns")
        match_by = st.radio(
            "Match each row to a property by", ["address", "parcel"],
            format_func=lambda v: "Property address" if v == "address" else "Parcel Number",
            horizontal=True, key="s_match_by")
        KEY_FIELD = (("address", "Property address *",
                      ("Property address", "Address", "PropertyAddress", "Site address", "Street"))
                     if match_by == "address" else
                     ("parcel", "Parcel Number *", ("Parcel Number", "Parcel", "parcel_number", "APN", "FOLIO")))
        FIELDS = [
            KEY_FIELD,
            ("phone",   "Phone *",       ("Phone", "Phone Number", "Number")),
            ("status",  "Status *",      ("Status", "Result", "Outcome", "Phone Status")),
            ("ptype",   "Type",          ("Phone Type", "Type", "Line Type")),
        ]
        # only the chosen key is staged: a row is never matched on the other one
        mapping = {"parcel": None, "address": None}
        for box, (field, label, names) in zip(st.columns(len(FIELDS)), FIELDS):
            with box:
                g = guess(cols, *names)
                choice = st.selectbox(label, opts, index=opts.index(g) if g else 0,
                                      key=f"sc_{match_by}_{field}")
                mapping[field] = None if choice == NONE else choice

        problems = []
        if not mapping[match_by]:
            problems.append("a **Property address** column" if match_by == "address"
                            else "a **Parcel Number** column")
        if not mapping["phone"]:
            problems.append("a **Phone** column")
        if not mapping["status"]:
            problems.append("a **Status** column")
        if problems:
            st.error("This file still needs " + " and ".join(problems) + ".")
        else:
            who = st.text_input("Record these as set by", value="status upload", max_chars=16)
            stage = build_stage(df, mapping)

            def go_bulk(commit):
                if not conn_params["password"]:
                    st.error("No database password — set it in the sidebar.")
                    return
                try:
                    with st.spinner("Matching against the phone list…" if not commit else "Saving statuses…"):
                        st.session_state["bulk_status"] = (
                            run(stage, conn_params=conn_params, updated_by=who or None,
                                commit=commit, set_status=True), commit)
                except Exception as exc:                   # noqa: BLE001
                    st.session_state.pop("bulk_status", None)
                    st.error(f"Import failed, nothing was written: {exc}")

            st.divider()
            left, right = st.columns(2)
            if left.button("Check without saving", use_container_width=True, key="s_dry"):
                go_bulk(False)
            if right.button("Save statuses", type="primary", use_container_width=True, key="s_go"):
                go_bulk(True)

    res_pair = st.session_state.get("bulk_status")
    if res_pair:
        res, committed = res_pair
        bad = sum(n for reason, n in res["reasons"] if reason)
        st.divider()
        st.subheader("Saved" if committed else "Dry run — nothing was written")

        a, b, c, d = st.columns(4)
        a.metric("Statuses set on existing numbers", f"{res['status_changed']:,}")
        b.metric("Numbers added", f"{res['inserted']:,}")
        c.metric("Matched to a property", f"{res['loadable']:,}")
        d.metric("Rejected", f"{bad:,}")

        if res["over_cap"]:
            st.warning(f"{res['over_cap']:,} skipped — those properties already hold {MAX_PHONES} numbers.")

        if res["preview"]:
            st.dataframe(pd.DataFrame(res["preview"], columns=[
                "Matched by", "Address", "Records at address", "Phone", "Type", "Status"]),
                use_container_width=True)

        if bad:
            st.subheader("Rejected rows")
            for reason, n in res["reasons"]:
                if reason:
                    st.write(f"- **{n:,}** — {reason}")
            rej = pd.DataFrame(res["rejects"], columns=[
                "Row", "Parcel Number", "Address", "Phone", "Type", "Status", "Reason"])
            st.dataframe(rej.head(200), use_container_width=True)
            st.download_button("Download all rejected rows (CSV)",
                               rej.to_csv(index=False).encode("utf-8"),
                               file_name="status_rejects.csv", mime="text/csv")

# ==========================================================================
# one at a time
# ==========================================================================
with one_tab:
    st.caption(
        "Looks up the property and the number together. If that number is already on the "
        "property its status is changed; if it is not, it is added with that status."
    )

    with st.form("lookup"):
        a, b = st.columns([1, 2])
        with a:
            key_field = st.radio("Look the property up by", ["address", "parcel"],
                                 format_func=lambda v: "Address" if v == "address" else "Parcel Number",
                                 horizontal=True)
        with b:
            key_value = st.text_input("Address or Parcel Number",
                                      placeholder="1570 Franklin Ave  —  or  010-000004-00")

        phone = st.text_input("Phone number", placeholder="(614) 555-0142")

        if st.form_submit_button("Look it up", type="primary", use_container_width=True):
            if not conn_params["password"]:
                st.error("No database password — set it in the sidebar.")
            else:
                try:
                    st.session_state["status_hit"] = look_up(
                        conn_params, key_field=key_field, key_value=key_value, phone=phone)
                    st.session_state.pop("status_done", None)
                except Exception as exc:                       # noqa: BLE001
                    st.session_state.pop("status_hit", None)
                    st.error(f"Lookup failed: {exc}")

    hit = st.session_state.get("status_hit")
    if not hit:
        st.stop()

    if hit.get("error"):
        st.error(hit["error"])
        st.stop()

    prop = hit["property"]
    existing = hit["existing"]

    st.divider()
    st.subheader(prop["property_address"] or "(no property address)")
    st.caption(f"{prop['full_name'] or '—'}  ·  {prop['property_city'] or ''}" +
               (f"  ·  shared by {prop['records']:,} Buybox records, who all show these numbers"
                if prop["records"] > 1 else ""))

    if existing:
        st.success(f"**{existing['phone']}** is already filed under this address — "
                   f"current status: **{STATUSES.get(existing['status'], NO_STATUS)}**")
    else:
        st.warning(f"**{pretty_phone(hit['digits'])}** is not filed under this address yet. "
                   f"Saving will add it.")

    if hit["phones"]:
        st.dataframe(pd.DataFrame([{
            "Phone": p["phone"],
            "Type": p["phone_type"] or "",
            "Status": STATUSES.get(p["status"], ""),
            "Note": p["note"] or "",
            "By": p["updated_by"] or "",
        } for p in hit["phones"]]), use_container_width=True, hide_index=True)
    else:
        st.caption("This address has no phone numbers yet.")

    st.divider()
    g, h, i = st.columns([2, 1, 1])
    choice = g.radio("Status to set", [*STATUSES, None],
                     format_func=lambda v: STATUSES.get(v, NO_STATUS),
                     horizontal=True,
                     index=list(STATUSES).index(existing["status"])
                     if existing and existing["status"] in STATUSES else 0)
    new_type = h.selectbox("Line type", ["", "mobile", "landline"],
                           format_func=lambda v: {"": "— unchanged —", "mobile": "📱 Mobile",
                                                  "landline": "☎️ Landline"}[v],
                           disabled=bool(existing))
    who = i.text_input("Set by", value="status", max_chars=16)

    if st.button("Save status", type="primary", use_container_width=True):
        try:
            res = apply_status(conn_params, address=prop["property_address"],
                               digits=hit["digits"], status=choice,
                               phone_type=new_type or None, updated_by=who or None,
                               commit=True)
            st.session_state["status_done"] = res
            # re-read so the table reflects what was just saved
            st.session_state["status_hit"] = look_up(
                conn_params, key_field="address",
                key_value=prop["property_address"],
                phone=pretty_phone(hit["digits"]))
            st.rerun()
        except Exception as exc:                               # noqa: BLE001
            st.error(f"Could not save: {exc}")

    done = st.session_state.get("status_done")
    if done:
        st.success(f"{'Added the number with that status' if done['action'] == 'added' else 'Status updated'}.")
