"""
SOS Phones — upload phone numbers.

Rows carrying a Parcel Number use it directly; the rest are resolved by
address. All the actual work lives in phone_import.py, which has no Streamlit
dependency, so the pipeline can be tested without a browser.

    streamlit run streamlit_app.py
"""

import pandas as pd
import streamlit as st

from phone_import import MAX_PHONES, build_stage, run
from st_db import guess, read_upload, sidebar_connection

st.set_page_config(page_title="SOS Phones — Upload", page_icon="📞", layout="wide")

NONE = "— none —"


conn_params = sidebar_connection()


# --------------------------------------------------------------------------
# the file
# --------------------------------------------------------------------------
st.title("📞 Upload phone numbers")
st.caption(
    "Rows carrying a Parcel Number use it as-is; the rest are resolved against BuyBox by "
    "address. Anything missing, unknown, or shared by more than one parcel is "
    "reported instead of guessed at."
)

upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"])
if not upload:
    st.info(
        "Upload a file with **Phone**, plus either a **Parcel Number** or an **Address** "
        "(a mix is fine — rows with a Parcel Number skip the address lookup). "
        "**Phone Type**, **City**, **Zip** and **County** are optional; they only "
        "matter for keys that turn out to be ambiguous."
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
st.caption("A row with a Parcel Number uses it directly. Only rows without one are looked up by address.")
boxes = st.columns(7)

FIELDS = [
    ("folio",   "Parcel Number", ("FOLIO", "Folio", "Parcel", "Parcel Number", "APN")),
    ("address", "Address",    ("Address", "Property address", "PropertyAddress", "Street")),
    ("phone",   "Phone *",    ("Phone", "Phone Number", "Number")),
    ("ptype",   "Phone Type", ("Phone Type", "Type", "Line Type")),
    ("city",    "City",       ("City", "Property city")),
    ("zip",     "Zip",        ("Zip", "Property zip", "Zipcode", "Postal Code")),
    ("county",  "County",     ("County", "Property county")),
]

mapping = {}
for box, (field, label, names) in zip(boxes, FIELDS):
    with box:
        g = guess(cols, *names)
        choice = st.selectbox(label, opts, index=opts.index(g) if g else 0, key=f"col_{field}")
        mapping[field] = None if choice == NONE else choice

problems = []
if not mapping["phone"]:
    problems.append("a **Phone** column")
if not mapping["folio"] and not mapping["address"]:
    problems.append("either a **Parcel Number** or an **Address** column")
if problems:
    st.error("This file still needs " + " and ".join(problems) + ".")
    st.stop()

updated_by = st.text_input("Record these as entered by", value="upload", max_chars=16)
stage = build_stage(df, mapping)


# --------------------------------------------------------------------------
# results
# --------------------------------------------------------------------------
def show(res, committed):
    ok = res["inserted"]
    bad = sum(n for reason, n in res["reasons"] if reason)

    a, b, c, d = st.columns(4)
    a.metric("Matched to a parcel", f"{res['loadable']:,}")
    b.metric("Inserted" if committed else "Would insert", f"{ok:,}")
    c.metric("Already on file", f"{res['already_there']:,}")
    d.metric("Rejected", f"{bad:,}")

    by = res.get("by_key") or {}
    if by:
        st.caption("Resolved by " + ", ".join(f"**{n:,}** {k}" for k, n in sorted(by.items())))

    if res["over_cap"]:
        st.warning(f"{res['over_cap']:,} number(s) skipped — those parcels already hold {MAX_PHONES}.")

    if res["preview"]:
        st.subheader("What this attaches")
        st.dataframe(pd.DataFrame(
            res["preview"],
            columns=["Matched by", "Parcel Number", "County", "Phone", "Type", "BuyBox address", "Owner"],
        ), use_container_width=True)

    if bad:
        st.subheader("Rejected rows")
        for reason, n in res["reasons"]:
            if reason:
                st.write(f"- **{n:,}** — {reason}")
        rej = pd.DataFrame(
            res["rejects"],
            columns=["Row", "Parcel Number", "Address", "City", "County", "Zip",
                     "Phone", "Phone Type", "Reason"],
        )
        st.dataframe(rej.head(200), use_container_width=True)
        st.download_button("Download all rejected rows (CSV)",
                           rej.to_csv(index=False).encode("utf-8"),
                           file_name="rejects.csv", mime="text/csv")


def go(commit):
    if not conn_params["password"]:
        st.error("No database password — set it in the sidebar.")
        return
    try:
        with st.spinner("Resolving against BuyBox…" if not commit else "Importing…"):
            st.session_state["result"] = (
                run(stage, conn_params=conn_params, updated_by=updated_by, commit=commit),
                commit,
            )
    except Exception as exc:                               # noqa: BLE001
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
