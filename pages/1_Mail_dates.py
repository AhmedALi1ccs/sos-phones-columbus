"""
Upload the dates the mailing house reports for each record.

The file carries a Parcel Number or an Address, plus the date it went out in
yyyy-mm-dd. All the work lives in mail_import.py, which has no Streamlit
dependency.
"""

import pandas as pd
import streamlit as st

from mail_import import build_stage, run
from st_db import guess, read_upload, sidebar_connection

st.set_page_config(page_title="SOS Phones — Mail dates", page_icon="✉️", layout="wide")

NONE = "— none —"
conn_params = sidebar_connection()

st.title("✉️ Upload mail dates")
st.caption(
    "Records the date each parcel was actually mailed, onto the Mailed table. "
    "A parcel that already has a row with no date yet has it filled in; otherwise "
    "a row is added. The same parcel and date twice is one mailing, not two."
)

upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"])
if not upload:
    st.info("Upload a file with a **Date** (`yyyy-mm-dd`), plus either a **Parcel Number** or an "
            "**Address**. A **Type** column naming the campaign is optional; when it is "
            "there, the date is matched to a row for that campaign first.")
    st.stop()

df = read_upload(upload)
st.success(f"Read **{len(df):,}** rows · {len(df.columns)} columns")
with st.expander("Preview the file", expanded=True):
    st.dataframe(df.head(8), width="stretch")

cols = list(df.columns)
opts = [NONE] + cols

st.subheader("Columns")
boxes = st.columns(4)
FIELDS = [
    ("folio",   "Parcel Number", ("FOLIO", "Folio", "Parcel", "Parcel Number", "APN")),
    ("address", "Address", ("Address", "Property address", "PropertyAddress", "Street")),
    ("date",    "Date *",  ("Date", "Mailed", "Mailed On", "Mail Date", "Mailed Date", "Drop Date")),
    ("type",    "Type",    ("Type", "Campaign", "Mail Type", "List")),
]
mapping = {}
for box, (field, label, names) in zip(boxes, FIELDS):
    with box:
        g = guess(cols, *names)
        choice = st.selectbox(label, opts, index=opts.index(g) if g else 0, key=f"mc_{field}")
        mapping[field] = None if choice == NONE else choice

problems = []
if not mapping["date"]:
    problems.append("a **Date** column")
if not mapping["folio"] and not mapping["address"]:
    problems.append("either a **Parcel Number** or an **Address** column")
if problems:
    st.error("This file still needs " + " and ".join(problems) + ".")
    st.stop()

source = st.text_input("Record the source of these dates as", value=upload.name, max_chars=60)
stage = build_stage(df, mapping)


def show(res, committed):
    bad = sum(n for reason, n in res["reasons"] if reason)
    a, b, c, d = st.columns(4)
    a.metric("Dates filled in" if committed else "Would fill in", f"{res['updated']:,}")
    b.metric("Rows added" if committed else "Would add", f"{res['inserted']:,}")
    c.metric("Already recorded", f"{res['already']:,}")
    d.metric("Rejected", f"{bad:,}")

    if res.get("by_key"):
        st.caption("Resolved by " + ", ".join(f"**{n:,}** {k}" for k, n in sorted(res["by_key"].items())))

    if res["preview"]:
        st.subheader("What this does")
        st.dataframe(pd.DataFrame(
            res["preview"], columns=["Parcel Number", "Mailed on", "Action", "Property address", "City"],
        ), width="stretch")

    if bad:
        st.subheader("Rejected rows")
        for reason, n in res["reasons"]:
            if reason:
                st.write(f"- **{n:,}** — {reason}")
        rej = pd.DataFrame(res["rejects"],
                           columns=["Row", "Parcel Number", "Address", "Date", "Type", "Reason"])
        st.dataframe(rej.head(200), width="stretch")
        st.download_button("Download all rejected rows (CSV)",
                           rej.to_csv(index=False).encode("utf-8"),
                           file_name="mail_date_rejects.csv", mime="text/csv")


def go(commit):
    if not conn_params["password"]:
        st.error("No database password — set it in the sidebar.")
        return
    try:
        with st.spinner("Matching against Mailed…" if not commit else "Saving dates…"):
            st.session_state["mail_result"] = (
                run(stage, conn_params=conn_params, source=source or "upload", commit=commit),
                commit,
            )
    except Exception as exc:                               # noqa: BLE001
        st.session_state.pop("mail_result", None)
        st.error(f"Import failed, nothing was written: {exc}")


st.divider()
left, right = st.columns(2)
if left.button("Check without saving", width="stretch"):
    go(commit=False)
if right.button("Save dates to Mailed", type="primary", width="stretch"):
    go(commit=True)

if "mail_result" in st.session_state:
    res, committed = st.session_state["mail_result"]
    st.divider()
    st.subheader("Saved" if committed else "Dry run — nothing was written")
    show(res, committed)
