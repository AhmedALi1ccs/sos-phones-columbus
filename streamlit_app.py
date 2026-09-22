"""
SOS Phones — upload phone numbers by ADDRESS.

The file carries Address / Phone / Phone Type; the FOLIO is looked up from
BuyBox by the address, because property_phones is keyed on parcel, not text.

    streamlit run streamlit_app.py
"""

import io
import os

import pandas as pd
import psycopg2
import streamlit as st

MAX_PHONES = 30

st.set_page_config(page_title="SOS Phones — Upload", page_icon="📞", layout="wide")


# --------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------
def secret(name, default=""):
    """st.secrets first, then the environment, then the default."""
    try:
        if name in st.secrets:
            return st.secrets[name]
    except Exception:
        pass
    return os.environ.get(name, default)


with st.sidebar:
    st.subheader("Database")
    host = st.text_input("Host", secret("PGHOST", "aws-1-us-east-2.pooler.supabase.com"))
    port = st.number_input("Port", value=int(secret("PGPORT", "5432")), step=1)
    dbname = st.text_input("Database", secret("PGDATABASE", "postgres"))
    user = st.text_input("User", secret("PGUSER", "postgres.hoahkpeblfxjbkhwbdxs"))
    password = st.text_input("Password", secret("PGPASSWORD", ""), type="password")
    st.caption(
        "Set these once in `.streamlit/secrets.toml` (git-ignored) or as environment "
        "variables and they fill in automatically."
    )


def connect():
    return psycopg2.connect(
        host=host, port=int(port), dbname=dbname, user=user, password=password,
        connect_timeout=15,
    )


# --------------------------------------------------------------------------
# the file
# --------------------------------------------------------------------------
st.title("📞 Upload phone numbers")
st.caption(
    "Rows carrying a FOLIO use it as-is; the rest are resolved against BuyBox by "
    "address. Anything missing, unknown, or shared by more than one parcel is "
    "reported instead of guessed at."
)

upload = st.file_uploader("CSV or Excel file", type=["csv", "xlsx", "xls"])
if not upload:
    st.info("Upload a file with **Phone**, plus either a **FOLIO** or an **Address** "
            "(a mix is fine — rows with a FOLIO skip the address lookup). "
            "**Phone Type**, **City** and **Zip** are optional; City and Zip resolve "
            "addresses that appear more than once.")
    st.stop()

try:
    if upload.name.lower().endswith(".csv"):
        df = pd.read_csv(upload, dtype=str, keep_default_na=False)
    else:
        df = pd.read_excel(upload, dtype=str).fillna("")
except Exception as exc:                                   # noqa: BLE001
    st.error(f"Could not read that file: {exc}")
    st.stop()

df.columns = [str(c).strip() for c in df.columns]
st.success(f"Read **{len(df):,}** rows · {len(df.columns)} columns")
st.dataframe(df.head(8), use_container_width=True)


# --------------------------------------------------------------------------
# column mapping
# --------------------------------------------------------------------------
def guess(cols, *wanted):
    norm = {c.lower().replace(" ", "").replace("_", ""): c for c in cols}
    for w in wanted:
        k = w.lower().replace(" ", "").replace("_", "")
        if k in norm:
            return norm[k]
    return None


cols = list(df.columns)
none_label = "— none —"
opts = [none_label] + cols
st.subheader("Columns")
st.caption("A row with a FOLIO uses it directly. Only rows without one are looked up by address.")
c1, c2, c3, c4, c5, c6, c7 = st.columns(7)


def pick_optional(container, label, *names):
    g = guess(cols, *names)
    with container:
        return st.selectbox(label, opts, index=opts.index(g) if g else 0)


col_folio = pick_optional(c1, "FOLIO", "FOLIO", "Folio", "Parcel", "Parcel Number", "APN")
with c2:
    g = guess(cols, "Address", "Property address", "PropertyAddress", "Street")
    col_addr = st.selectbox("Address", opts, index=opts.index(g) if g else 0)
with c3:
    g = guess(cols, "Phone", "Phone Number", "Number")
    col_phone = st.selectbox("Phone *", cols, index=cols.index(g or cols[0]))
col_type = pick_optional(c4, "Phone Type", "Phone Type", "Type", "Line Type")
col_city   = pick_optional(c5, "City", "City", "Property city")
col_zip    = pick_optional(c6, "Zip", "Zip", "Property zip", "Zipcode", "Postal Code")
col_county = pick_optional(c7, "County", "County", "Property county")

if col_folio == none_label and col_addr == none_label:
    st.error("The file needs either a FOLIO column or an Address column.")
    st.stop()

updated_by = st.text_input("Record these as entered by", value="upload", max_chars=16)


def column(name):
    return df[name] if name and name != none_label else pd.Series([""] * len(df))


stage = pd.DataFrame({
    "row_no": range(2, len(df) + 2),           # line number in the original file
    "folio_in": column(col_folio).astype(str),
    "address": column(col_addr).astype(str),
    "city": column(col_city).astype(str),
    "county": column(col_county).astype(str),
    "zip": column(col_zip).astype(str),
    "phone": column(col_phone).astype(str),
    "ptype": column(col_type).astype(str),
})


# --------------------------------------------------------------------------
# resolve + load, all inside one transaction
# --------------------------------------------------------------------------
RESOLVE_SQL = """
create temp table stage (
  row_no int, folio_in text, address text, city text, county text,
  zip text, phone text, ptype text
) on commit drop;
"""

# Normalisation happens in SQL, using the same functions the site uses, so the
# two can never drift apart the way a second Python copy would.
NARROW = """
     (btrim(coalesce(s.city,''))   = '' or public.county_norm(b."Property city")   = public.county_norm(s.city))
 and (btrim(coalesce(s.county,'')) = '' or public.county_norm(b."Property county") = public.county_norm(s.county))
 and (btrim(coalesce(s.zip,''))    = '' or btrim(coalesce(b."Property zip",''))    = btrim(s.zip))
"""

CLASSIFY_SQL = (f"""
create temp table resolved on commit drop as
select s.row_no, s.folio_in, s.address, s.city, s.county, s.zip, s.phone, s.ptype,
       regexp_replace(coalesce(s.phone,''), '\\D', '', 'g')                       as digits,
       case lower(btrim(coalesce(s.ptype,'')))
         when 'mobile'      then 'mobile'   when 'cell'     then 'mobile'
         when 'cell phone'  then 'mobile'   when 'wireless' then 'mobile'
         when 'residential' then 'landline' when 'landline' then 'landline'
         when 'land line'   then 'landline' when 'home'     then 'landline'
         when 'house'       then 'landline'
         else null
       end                                                                       as phone_type,
       case when btrim(coalesce(s.folio_in,'')) <> '' then 'FOLIO' else 'address' end as matched_by,
       case when btrim(coalesce(s.folio_in,'')) <> '' then bf.folio   else ba.folio   end as folio,
       case when btrim(coalesce(s.folio_in,'')) <> '' then bf.county  else ba.county  end as county_out,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then coalesce(bf.parcels, 0) else coalesce(ba.parcels, 0) end            as parcels,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then coalesce(bf.parcels_before_narrowing, 0)
            else coalesce(ba.parcels_before_narrowing, 0) end                        as parcels_before_narrowing
from stage s
-- Two separate lookups rather than one with a CASE in the WHERE: a CASE there
-- cannot be turned into an index condition, and each staged row would trigger
-- a 286k-row scan. When the other key is blank its norm is NULL, so that
-- lookup matches nothing and costs an index probe.
--
-- City/Zip/County narrow the result through FILTER rather than WHERE, so the
-- key match stays indexable and we can still tell "key is unknown" apart from
-- "key is known but your City/Zip/County excluded it".
left join lateral (
  select min(b."FOLIO")           filter (where %(narrow)s) as folio,
         min(b."Property county") filter (where %(narrow)s) as county,
         count(distinct (public.folio_norm(b."FOLIO"), public.county_norm(b."Property county")))
           filter (where %(narrow)s)                        as parcels,
         count(distinct (public.folio_norm(b."FOLIO"), public.county_norm(b."Property county")))
                                                            as parcels_before_narrowing
  from public."BuyBox" b
  where public.folio_norm(b."FOLIO") = public.folio_norm(s.folio_in)
) bf on true
left join lateral (
  select min(b."FOLIO")           filter (where %(narrow)s) as folio,
         min(b."Property county") filter (where %(narrow)s) as county,
         count(distinct (public.folio_norm(b."FOLIO"), public.county_norm(b."Property county")))
           filter (where %(narrow)s)                        as parcels,
         count(distinct (public.folio_norm(b."FOLIO"), public.county_norm(b."Property county")))
                                                            as parcels_before_narrowing
  from public."BuyBox" b
  where public.addr_norm(b."Property address") = public.addr_norm(s.address)
    and coalesce(btrim(b."FOLIO"), '') <> ''
) ba on true;

create temp table classified on commit drop as
select r.*,
       case
         when btrim(coalesce(r.folio_in,'')) = '' and btrim(coalesce(r.address,'')) = ''
           then 'row has neither a FOLIO nor an address'
         when length(r.digits) not in (10, 11)
           then 'phone is not a 10 digit number'
         when r.parcels = 0 and r.parcels_before_narrowing > 0
           then r.matched_by || ' exists, but the City/Zip/County in this row does not match BuyBox'
         when r.parcels = 0
           then r.matched_by || ' not found in BuyBox'
         when r.parcels > 1
           then r.matched_by || ' belongs to ' || r.parcels
                || ' different parcels - add City, Zip or County to narrow it'
         else null
       end as reject_reason
from resolved r;

-- one row per number per parcel; the fullest copy of a number wins
create temp table to_load on commit drop as
select distinct on (public.folio_norm(folio), public.county_norm(county), norm)
       folio, county, phone_fmt as phone, phone_type, row_no, norm, matched_by
from (
  select c.folio, c.county_out as county, c.phone_type, c.row_no, c.matched_by,
         case when length(c.digits) = 11 then substr(c.digits, 2) else c.digits end as norm,
         case when length(c.digits) in (10, 11)
              then '(' || substr(right(c.digits, 10), 1, 3) || ') '
                       || substr(right(c.digits, 10), 4, 3) || '-'
                       || substr(right(c.digits, 10), 7, 4)
              else c.phone end as phone_fmt
  from classified c
  where c.reject_reason is null
) x
order by public.folio_norm(folio), public.county_norm(county), norm,
         (phone_type is null), row_no;

-- respect the 30-per-parcel cap, counting what is already stored
create temp table ranked on commit drop as
select t.*,
       coalesce(e.n, 0) as already,
       row_number() over (partition by public.folio_norm(t.folio), public.county_norm(t.county)
                          order by t.row_no) as rn
from to_load t
left join (
  select folio_key, county_key, count(*) n from public.property_phones group by 1, 2
) e on e.folio_key = public.folio_norm(t.folio) and e.county_key = public.county_norm(t.county);
""" % {"narrow": NARROW})

INSERT_SQL = f"""
insert into public.property_phones (folio, county, phone, phone_type, slot, updated_by)
select folio, county, phone, phone_type, already + rn, %s
from ranked
where already + rn <= {MAX_PHONES}
on conflict (folio_key, county_key, phone_norm) do nothing;
"""


def run(commit):
    """Resolve the staged rows; commit only when asked."""
    buf = io.StringIO()
    stage.to_csv(buf, index=False, header=False)
    buf.seek(0)

    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(RESOLVE_SQL)
            cur.copy_expert("copy stage from stdin with (format csv)", buf)
            cur.execute(CLASSIFY_SQL)

            cur.execute("select reject_reason, count(*) from classified group by 1 order by 2 desc")
            reasons = cur.fetchall()

            cur.execute("""select matched_by, count(*) from classified
                            where reject_reason is null group by 1""")
            by_key = dict(cur.fetchall())

            cur.execute(f"select count(*) from ranked where already + rn <= {MAX_PHONES}")
            loadable = cur.fetchone()[0]
            cur.execute(f"select count(*) from ranked where already + rn > {MAX_PHONES}")
            over_cap = cur.fetchone()[0]

            cur.execute("""
                select row_no, folio_in, address, city, county, zip, phone, ptype, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            cur.execute(INSERT_SQL, (updated_by or None,))
            inserted = cur.rowcount

            cur.execute("""
                select r.matched_by, r.folio, r.county, r.phone, r.phone_type,
                       b."Property address", b."Full Name"
                from ranked r
                join public."BuyBox" b
                  on public.folio_norm(b."FOLIO") = public.folio_norm(r.folio)
                 and public.county_norm(b."Property county") = public.county_norm(r.county)
                order by r.row_no limit 25""")
            preview = cur.fetchall()

        if commit:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    return {
        "reasons": reasons, "loadable": loadable, "over_cap": over_cap,
        "rejects": rejects, "inserted": inserted, "by_key": by_key,
        "already_there": loadable - inserted, "preview": preview,
    }


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
        st.caption("Resolved by "
                   + ", ".join(f"**{n:,}** {k}" for k, n in sorted(by.items())))

    if res["over_cap"]:
        st.warning(f"{res['over_cap']:,} number(s) skipped — those parcels already hold {MAX_PHONES}.")

    if res["preview"]:
        st.subheader("What this attaches")
        st.dataframe(pd.DataFrame(
            res["preview"],
            columns=["Matched by", "FOLIO", "County", "Phone", "Type", "BuyBox address", "Owner"],
        ), use_container_width=True)

    if bad:
        st.subheader("Rejected rows")
        for reason, n in res["reasons"]:
            if reason:
                st.write(f"- **{n:,}** — {reason}")
        rej = pd.DataFrame(
            res["rejects"],
            columns=["Row", "FOLIO", "Address", "City", "County", "Zip",
                     "Phone", "Phone Type", "Reason"],
        )
        st.dataframe(rej.head(200), use_container_width=True)
        st.download_button("Download all rejected rows (CSV)",
                           rej.to_csv(index=False).encode("utf-8"),
                           file_name="rejects.csv", mime="text/csv")


st.divider()
left, right = st.columns([1, 1])

if left.button("Check without importing", use_container_width=True):
    if not password:
        st.error("Enter the database password in the sidebar first.")
    else:
        with st.spinner("Resolving addresses against BuyBox…"):
            st.session_state["result"] = (run(commit=False), False)

if right.button("Import to property_phones", type="primary", use_container_width=True):
    if not password:
        st.error("Enter the database password in the sidebar first.")
    else:
        with st.spinner("Importing…"):
            st.session_state["result"] = (run(commit=True), True)
        st.balloons()

if "result" in st.session_state:
    res, committed = st.session_state["result"]
    st.divider()
    st.subheader("Imported" if committed else "Dry run — nothing was written")
    show(res, committed)
