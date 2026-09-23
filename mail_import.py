"""
Recording when each record was mailed.

The mailing house reports, per record, the date it actually went out. Each row
in Mailed is one campaign for one parcel, so a date belongs on a row.

What an uploaded (parcel, date) does, in order:

  1. that parcel already has a row carrying that date  -> nothing to do
  2. that parcel has a row with no date yet            -> fill it in
     (preferring a row whose Type matches, when the file names a campaign)
  3. otherwise                                          -> add a row for the
     parcel, copying its details from BuyBox, or from its other Mailed rows
     when the parcel is no longer in BuyBox

Kept free of Streamlit so the whole pipeline can be exercised without a browser.
"""

import io

import pandas as pd
import psycopg2

STAGE_COLUMNS = ["row_no", "folio_in", "address", "date_in", "type_in"]


def build_stage(df, mapping, first_row=2):
    """Turn an uploaded dataframe plus a {field: column name} mapping into stage rows."""
    def col(field):
        name = mapping.get(field)
        if not name or name not in df.columns:
            return pd.Series([""] * len(df), index=df.index)
        return df[name].astype(str)

    return pd.DataFrame({
        "row_no": range(first_row, first_row + len(df)),
        "folio_in": col("folio"),
        "address": col("address"),
        "date_in": col("date"),
        "type_in": col("type"),
    })


RESOLVE_SQL = """
create temp table stage (
  row_no int, folio_in text, address text, date_in text, type_in text
) on commit drop;
"""

CLASSIFY_SQL = """
create temp table resolved on commit drop as
select s.row_no, s.folio_in, s.address, s.date_in, s.type_in,
       -- the file is specified as yyyy-mm-dd; anything else is reported, not guessed
       case when btrim(coalesce(s.date_in,'')) ~ '^\\d{4}-\\d{2}-\\d{2}$'
            then to_date(btrim(s.date_in), 'YYYY-MM-DD') end                      as mailed_on,
       case when btrim(coalesce(s.folio_in,'')) <> '' then 'FOLIO' else 'address' end as matched_by,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then public.folio_norm(s.folio_in) else ba.fkey end                    as folio_key,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then coalesce(bf.folio, mf.folio, btrim(s.folio_in)) else ba.folio end as folio,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then coalesce(ba2.parcels, 1) else coalesce(ba.parcels, 0) end         as parcels,
       case when btrim(coalesce(s.folio_in,'')) <> ''
            then (bf.folio is not null or mf.folio is not null)
            else ba.folio is not null end                                          as known
from stage s
-- by FOLIO: is the parcel in BuyBox, or at least already in Mailed?
left join lateral (
  select min(b."FOLIO") as folio from public."BuyBox" b
  where public.folio_norm(b."FOLIO") = public.folio_norm(s.folio_in)
) bf on true
left join lateral (
  select min(m."FOLIO") as folio from public."Mailed" m
  where public.folio_norm(m."FOLIO") = public.folio_norm(s.folio_in)
) mf on true
left join lateral (select 1 as parcels) ba2 on true
-- by address: resolve to a parcel through BuyBox, as the phone uploader does
left join lateral (
  select min(b."FOLIO")                       as folio,
         public.folio_norm(min(b."FOLIO"))    as fkey,
         count(distinct public.folio_norm(b."FOLIO")) as parcels
  from public."BuyBox" b
  where public.addr_norm(b."Property address") = public.addr_norm(s.address)
    and coalesce(btrim(b."FOLIO"), '') <> ''
) ba on true;

create temp table classified on commit drop as
select r.*,
       case
         when btrim(coalesce(r.folio_in,'')) = '' and btrim(coalesce(r.address,'')) = ''
           then 'row has neither a FOLIO nor an address'
         when r.mailed_on is null
           then 'date is missing or not yyyy-mm-dd'
         when r.matched_by = 'address' and r.parcels = 0
           then 'address not found in BuyBox'
         when r.matched_by = 'address' and r.parcels > 1
           then 'address belongs to ' || r.parcels || ' different parcels'
         when not r.known
           then 'FOLIO is in neither BuyBox nor Mailed'
         else null
       end as reject_reason
from resolved r;

-- One action per (parcel, date): the same pair listed twice in a file is one
-- event. Where a parcel gets several different dates, each must claim its own
-- undated row -- pointing them all at the same row silently loses every date
-- but one.
create temp table actions on commit drop as
with wanted as (
  select distinct on (c.folio_key, c.mailed_on)
         c.folio_key, c.folio, c.mailed_on, c.type_in, c.row_no
  from classified c
  where c.reject_reason is null
  order by c.folio_key, c.mailed_on, c.row_no
),
flagged as (
  select w.*,
         exists (select 1 from public."Mailed" m
                  where public.folio_norm(m."FOLIO") = w.folio_key
                    and m.mailed_on = w.mailed_on) as already_dated
  from wanted w
),
needing as (
  select f.folio_key, f.mailed_on,
         row_number() over (partition by f.folio_key order by f.mailed_on) as need_rn
  from flagged f
  where not f.already_dated
),
slots as (
  select public.folio_norm(m."FOLIO") as folio_key,
         m.ctid                       as slot_ctid,
         row_number() over (partition by public.folio_norm(m."FOLIO")
                            order by m."Type" nulls last, m.ctid) as rn
  from public."Mailed" m
  where m.mailed_on is null
    and exists (select 1 from needing n where n.folio_key = public.folio_norm(m."FOLIO"))
)
select f.folio_key, f.folio, f.mailed_on, f.type_in, f.row_no, f.already_dated,
       s.slot_ctid as fill_ctid
from flagged f
left join needing n
       on n.folio_key = f.folio_key and n.mailed_on = f.mailed_on
left join slots s
       on s.folio_key = n.folio_key and s.rn = n.need_rn;
"""

UPDATE_SQL = """
update public."Mailed" m
   set mailed_on = a.mailed_on,
       mailed_src = %s
  from actions a
 where m.ctid = a.fill_ctid
   and not a.already_dated
   and a.fill_ctid is not null;
"""

INSERT_SQL = """
insert into public."Mailed" (
  "FOLIO", "Full Name", "First Name", "Last Name",
  "Property address", "Property city", "Property state", "Property zip",
  "Mailing address", "Mailing city", "Mailing state", "Mailing zip",
  "Check", "Type", mailed_on, mailed_src)
select a.folio,
       coalesce(b."Full Name", m."Full Name"),
       coalesce(b."First Name", m."First Name"),
       coalesce(b."Last Name", m."Last Name"),
       coalesce(b."Property address", m."Property address"),
       coalesce(b."Property city", m."Property city"),
       coalesce(b."Property state", m."Property state"),
       coalesce(b."Property zip", m."Property zip"),
       coalesce(b."Mailing address", m."Mailing address"),
       coalesce(b."Mailing city", m."Mailing city"),
       coalesce(b."Mailing state", m."Mailing state"),
       coalesce(b."Mailing zip", m."Mailing zip"),
       m."Check",
       nullif(btrim(coalesce(a.type_in, '')), ''),
       a.mailed_on,
       %s
from actions a
left join lateral (
  select * from public."BuyBox" bb
  where public.folio_norm(bb."FOLIO") = a.folio_key limit 1
) b on true
left join lateral (
  select * from public."Mailed" mm
  where public.folio_norm(mm."FOLIO") = a.folio_key limit 1
) m on true
where not a.already_dated
  and a.fill_ctid is null;
"""


def run(stage, *, conn_params, source="upload", commit=False):
    """Resolve the staged rows and apply them; commit only when asked."""
    buf = io.StringIO()
    stage.to_csv(buf, index=False, header=False)
    buf.seek(0)

    conn = psycopg2.connect(**conn_params)
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

            cur.execute("select count(*) from actions where already_dated")
            already = cur.fetchone()[0]

            cur.execute("""
                select row_no, folio_in, address, date_in, type_in, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            cur.execute(UPDATE_SQL, (source,))
            updated = cur.rowcount
            cur.execute(INSERT_SQL, (source,))
            inserted = cur.rowcount

            cur.execute("""
                select a.folio, a.mailed_on,
                       case when a.already_dated then 'already recorded'
                            when a.fill_ctid is not null then 'filled in an existing row'
                            else 'added a new row' end,
                       b."Property address", b."Property city"
                from actions a
                left join lateral (
                  select * from public."BuyBox" bb
                  where public.folio_norm(bb."FOLIO") = a.folio_key limit 1
                ) b on true
                order by a.row_no limit 25""")
            preview = cur.fetchall()

        if commit:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    return {"reasons": reasons, "by_key": by_key, "already": already,
            "updated": updated, "inserted": inserted,
            "rejects": rejects, "preview": preview}
