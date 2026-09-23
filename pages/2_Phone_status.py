"""
Set the status of one phone number on one property.

Enter an address (or parcel number) and a phone number: if that number is
already on the property, its status is changed; if it is not, it is added
carrying that status. All the work lives in status_update.py.
"""

import pandas as pd
import streamlit as st

from st_db import sidebar_connection
from status_update import NO_STATUS, STATUSES, apply_status, look_up, pretty_phone

st.set_page_config(page_title="SOS Phones — Phone status", page_icon="✅", layout="wide")

conn_params = sidebar_connection()

st.title("✅ Set a phone status")
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
                                  placeholder="308 Cedar Rock Mdws  —  or  F# 077G222")

    c, d, e, f = st.columns(4)
    phone = c.text_input("Phone number", placeholder="(706) 836-9448")
    city = d.text_input("City", placeholder="optional")
    zipcode = e.text_input("Zip", placeholder="optional")
    county = f.text_input("County", placeholder="optional")
    st.caption("City, Zip and County are only needed when an address or parcel number "
               "turns out to belong to more than one property.")

    if st.form_submit_button("Look it up", type="primary", width="stretch"):
        if not conn_params["password"]:
            st.error("No database password — set it in the sidebar.")
        else:
            try:
                st.session_state["status_hit"] = look_up(
                    conn_params, key_field=key_field, key_value=key_value, phone=phone,
                    city=city, county=county, zipcode=zipcode)
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
st.caption(f"{prop['full_name'] or '—'}  ·  {prop['property_city'] or ''}  ·  "
           f"{prop['folio']}  ·  {prop['county']} County")

if existing:
    st.success(f"**{existing['phone']}** is already on this property — "
               f"current status: **{STATUSES.get(existing['status'], NO_STATUS)}**")
else:
    st.warning(f"**{pretty_phone(hit['digits'])}** is not on this property yet. "
               f"Saving will add it.")

if hit["phones"]:
    st.dataframe(pd.DataFrame([{
        "Phone": p["phone"],
        "Type": p["phone_type"] or "",
        "Status": STATUSES.get(p["status"], ""),
        "Note": p["note"] or "",
        "By": p["updated_by"] or "",
    } for p in hit["phones"]]), width="stretch", hide_index=True)
else:
    st.caption("This property has no phone numbers yet.")

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

if st.button("Save status", type="primary", width="stretch"):
    try:
        res = apply_status(conn_params, folio=prop["folio"], county=prop["county"],
                           digits=hit["digits"], status=choice,
                           phone_type=new_type or None, updated_by=who or None,
                           commit=True)
        st.session_state["status_done"] = res
        # re-read so the table reflects what was just saved
        st.session_state["status_hit"] = look_up(
            conn_params, key_field=key_field or "address",
            key_value=prop["folio"] if key_field == "parcel" else prop["property_address"],
            phone=pretty_phone(hit["digits"]),
            city=city, county=county, zipcode=zipcode)
        st.rerun()
    except Exception as exc:                               # noqa: BLE001
        st.error(f"Could not save: {exc}")

done = st.session_state.get("status_done")
if done:
    st.success(f"{'Added the number with that status' if done['action'] == 'added' else 'Status updated'}.")
