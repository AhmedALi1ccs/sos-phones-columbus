"""
Upload a SMS list: address, number, source.

An address BuyBox knows is linked to its parcel, which is what lets a row open
the property page. An address BuyBox does not know is still loaded, without a
parcel — a SMS list is worth having either way. All the work lives in
cold_import.py.
"""

import pandas as pd
import streamlit as st

from contact_import import build_stage, run
from st_db import guess, read_upload, sidebar_connection

st.set_page_config(page_title="SOS Phones — SMS", page_icon="💬", layout="wide")

NONE = "— none —"
conn_params = sidebar_connection()

st.title("💬 Upload an SMS list")
st.caption(
    "Address, number and source. The same number for the same address from the same "
    "source is one entry, so re-uploading a list adds only what is new."
)

upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"])
if not upload:
    st.info("Upload a file with **Address**, **Phone** and **Source**.")
    st.stop()

df = read_upload(upload)
st.success(f"Read **{len(df):,}** rows · {len(df.columns)} columns")
with st.expander("Preview the file", expanded=True):
    st.dataframe(df.head(8), use_container_width=True)

cols = list(df.columns)
opts = [NONE] + cols
st.subheader("Columns")
boxes = st.columns(3)
FIELDS = [
    ("address", "Address *", ("Address", "Property address", "PropertyAddress", "Street")),
    ("phone",   "Phone *",   ("Phone", "Phone Number", "Number", "Cell")),
    ("source",  "Source",    ("Source", "List", "Origin", "Provider", "Vendor")),
]
mapping = {}
for box, (field, label, names) in zip(boxes, FIELDS):
    with box:
        g = guess(cols, *names)
        choice = st.selectbox(label, opts, index=opts.index(g) if g else 0, key=f"sms_{field}")
        mapping[field] = None if choice == NONE else choice

problems = []
if not mapping["address"]:
    problems.append("an **Address** column")
if not mapping["phone"]:
    problems.append("a **Phone** column")
if problems:
    st.error("This file still needs " + " and ".join(problems) + ".")
    st.stop()

if not mapping["source"]:
    fixed = st.text_input("No Source column — record these all as",
                          value=upload.name.rsplit(".", 1)[0], max_chars=60)
else:
    fixed = None

stage = build_stage(df, mapping)
if fixed is not None:
    stage["source"] = fixed

label = st.text_input("Record the file this came from as", value=upload.name, max_chars=60)


def go(commit):
    if not conn_params["password"]:
        st.error("No database password — set it in the sidebar.")
        return
    try:
        with st.spinner("Matching addresses…" if not commit else "Loading…"):
            st.session_state["sms_result"] = (
                run(stage, conn_params=conn_params, table="SMS",
                    source_label=label or "upload", commit=commit), commit)
    except Exception as exc:                               # noqa: BLE001
        st.session_state.pop("sms_result", None)
        st.error(f"Import failed, nothing was written: {exc}")


st.divider()
left, right = st.columns(2)
if left.button("Check without loading", use_container_width=True):
    go(False)
if right.button("Load into SMS", type="primary", use_container_width=True):
    go(True)

pair = st.session_state.get("sms_result")
if pair:
    res, committed = pair
    bad = sum(n for reason, n in res["reasons"] if reason)
    st.divider()
    st.subheader("Loaded" if committed else "Dry run — nothing was written")

    a, b, c, d = st.columns(4)
    a.metric("Loaded" if committed else "Would load", f"{res['inserted']:,}")
    b.metric("Linked to a property", f"{res['linked']:,}")
    c.metric("Already on the list", f"{res['already_there']:,}")
    d.metric("Rejected", f"{bad:,}")

    if res["unlinked"]:
        st.info(f"{res['unlinked']:,} of these addresses are not in BuyBox, or match more "
                f"than one property. They are loaded without a parcel link, so they will "
                f"not open a property page.")

    if res["preview"]:
        st.dataframe(pd.DataFrame(
            res["preview"], columns=["Address", "Phone", "Source", "Parcel Number", "Owner"]),
            use_container_width=True)

    if bad:
        st.subheader("Rejected rows")
        for reason, n in res["reasons"]:
            if reason:
                st.write(f"- **{n:,}** — {reason}")
        rej = pd.DataFrame(res["rejects"], columns=["Row", "Address", "Phone", "Source", "Reason"])
        st.dataframe(rej.head(200), use_container_width=True)
        st.download_button("Download all rejected rows (CSV)",
                           rej.to_csv(index=False).encode("utf-8"),
                           file_name="sms_rejects.csv", mime="text/csv")
