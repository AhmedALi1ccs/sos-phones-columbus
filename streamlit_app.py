"""
SOS Phones — upload phone numbers.

Rows carrying a Parcel Number use it directly; the rest are resolved by
address. All the actual work lives in phone_import.py, which has no Streamlit
dependency, so the pipeline can be tested without a browser.

    streamlit run streamlit_app.py
"""

import pandas as pd
import streamlit as st

from phone_import import MAX_PHONES, build_stage, run, wide_phone_columns
from st_db import guess, read_upload, sidebar_connection

st.set_page_config(page_title="SOS Phones — Upload", page_icon="📞", layout="wide")

NONE = "— none —"


conn_params = sidebar_connection()


# --------------------------------------------------------------------------
# the file
# --------------------------------------------------------------------------
st.title("📞 Upload phone numbers")
st.caption(
    "Phone numbers are filed under the property address: every Buybox record at that "
    "address shows them. Each row is matched by its address (or, if you choose, by the "
    "address of its Parcel Number); an address Buybox does not know is reported, not stored."
)

upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"])
if not upload:
    st.info(
        "Upload a file with **Property address** and **Phone**. **Phone Type** and "
        "**Status** are optional. A full address such as "
        "*364 W Lane Ave, Columbus, OH 43201* is fine — everything after the first comma "
        "is ignored."
    )
    st.stop()

df = read_upload(upload)
st.success(f"Read **{len(df):,}** rows · {len(df.columns)} columns")
with st.expander("Preview the file", expanded=True):
    st.dataframe(df.head(8), use_container_width=True)


# --------------------------------------------------------------------------
# column mapping
# --------------------------------------------------------------------------
cols = list(df.columns)
opts = [NONE] + cols

st.subheader("Columns")
match_by = st.radio(
    "Match each row to a property by",
    ["address", "parcel"],
    format_func=lambda v: "Property address" if v == "address" else "Parcel Number",
    horizontal=True,
)

ADDRESS_NAMES = ("Property address", "Input Property Address", "Address", "PropertyAddress",
                 "Property Street", "Site address", "Situs address", "Street")
KEY_FIELD = (("address", "Property address *", ADDRESS_NAMES) if match_by == "address" else
             ("parcel", "Parcel Number *", ("Parcel Number", "Parcel", "parcel_number", "APN", "FOLIO")))
# a skip-trace export: Phone1, Phone1 Type, Phone2, ... on one row per property
wide = wide_phone_columns(cols)
if wide:
    st.caption(f"Found **{len(wide)} phone columns** ({wide[0][0]} … {wide[-1][0]}) — every "
               f"filled one is loaded, with its type"
               f"{'' if all(t for _, t in wide) else ' where the file gives one'}.")
FIELDS = [KEY_FIELD]
if not wide:
    FIELDS += [
        ("phone", "Phone *",    ("Phone", "Phone Number", "Number")),
        ("ptype", "Phone Type", ("Phone Type", "Type", "Line Type")),
    ]
FIELDS += [("status", "Status", ("Status", "Result", "Outcome", "Phone Status"))]

# only the chosen key is staged: a row is never matched on the other one
mapping = {"parcel": None, "address": None, "phone_cols": wide}
for box, (field, label, names) in zip(st.columns(len(FIELDS)), FIELDS):
    with box:
        g = guess(cols, *names)
        choice = st.selectbox(label, opts, index=opts.index(g) if g else 0,
                              key=f"col_{match_by}_{field}")
        mapping[field] = None if choice == NONE else choice

problems = []
if not mapping[match_by]:
    problems.append("a **Property address** column" if match_by == "address"
                    else "a **Parcel Number** column")
if not wide and not mapping["phone"]:
    problems.append("a **Phone** column")
if problems:
    st.error("This file still needs " + " and ".join(problems) + ".")
    st.stop()

updated_by = st.text_input("Record these as entered by", value="upload", max_chars=16)
stage = build_stage(df, mapping)
if wide:
    st.caption(f"That is **{len(stage):,}** phone numbers across {len(df):,} rows.")


# --------------------------------------------------------------------------
# results
# --------------------------------------------------------------------------
def show(res, committed):
    ok = res["inserted"]
    bad = sum(n for reason, n in res["reasons"] if reason)

    cols = st.columns(5 if res.get("status_changed") else 4)
    cols[0].metric("Matched to an address", f"{res['loadable']:,}")
    cols[1].metric("Inserted" if committed else "Would insert", f"{ok:,}")
    cols[2].metric("Already on file", f"{res['already_there']:,}")
    cols[3].metric("Rejected", f"{bad:,}")
    if res.get("status_changed"):
        cols[4].metric("Statuses set", f"{res['status_changed']:,}")

    by = res.get("by_key") or {}
    if by:
        st.caption("Resolved by " + ", ".join(f"**{n:,}** {k}" for k, n in sorted(by.items())))

    if res.get("shared"):
        st.info(f"{res['shared']:,} number(s) go to an address that more than one Buybox record "
                f"shares (a condo or apartment building); every record there will show them.")
    if res["over_cap"]:
        st.warning(f"{res['over_cap']:,} number(s) skipped — those addresses already hold {MAX_PHONES}.")

    if res["preview"]:
        st.subheader("What this attaches")
        st.dataframe(pd.DataFrame(
            res["preview"],
            columns=["Matched by", "Address", "Records at address", "Phone", "Type", "Status"],
        ), use_container_width=True)

    if bad:
        st.subheader("Rejected rows")
        for reason, n in res["reasons"]:
            if reason:
                st.write(f"- **{n:,}** — {reason}")
        rej = pd.DataFrame(
            res["rejects"],
            columns=["Row", "Parcel Number", "Address", "Phone", "Phone Type", "Status", "Reason"],
        )
        st.dataframe(rej.head(200), use_container_width=True)
        st.download_button("Download all rejected rows (CSV)",
                           rej.to_csv(index=False).encode("utf-8"),
                           file_name="rejects.csv", mime="text/csv")


def go(commit):
    if not conn_params["password"]:
        st.error("No database password — set it in the sidebar.")
        return
    # a skip-trace file of half a million numbers takes several minutes
    bar = st.progress(0.0, text="Starting…")
    try:
        st.session_state["result"] = (
            run(stage, conn_params=conn_params, updated_by=updated_by, commit=commit,
                set_status=bool(mapping.get("status")),
                progress=lambda f, msg: bar.progress(min(max(f, 0.0), 1.0), text=msg)),
            commit,
        )
        bar.empty()
    except Exception as exc:                               # noqa: BLE001
        bar.empty()
        st.session_state.pop("result", None)
        st.error(f"Import failed, nothing was written: {exc}")


st.divider()
left, right = st.columns(2)
if left.button("Check without importing", use_container_width=True):
    go(commit=False)
if right.button("Import to property_phones", type="primary", use_container_width=True):
    go(commit=True)

if "result" in st.session_state:
    res, committed = st.session_state["result"]
    st.divider()
    st.subheader("Imported" if committed else "Dry run — nothing was written")
    show(res, committed)
