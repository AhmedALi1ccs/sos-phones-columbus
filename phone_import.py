"""
Resolving and loading phone numbers into property_phones.

Kept free of Streamlit so the whole pipeline can be exercised without a
browser: streamlit_app.py is only the user interface over this.

A row that carries a FOLIO is matched on it; the rest are matched by address.
Normalisation happens in SQL, using the same functions the website uses, so
this cannot drift away from what the site considers the same parcel.
"""

import io

import pandas as pd
import psycopg2

MAX_PHONES = 30

# the column order the stage table expects
STAGE_COLUMNS = ["row_no", "folio_in", "address", "city", "county", "zip", "phone", "ptype"]


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
        "city": col("city"),
        "county": col("county"),
        "zip": col("zip"),
        "phone": col("phone"),
        "ptype": col("ptype"),
    })


RESOLVE_SQL = """
create temp table stage (
  row_no int, folio_in text, address text, city text, county text,
  zip text, phone text, ptype text
) on commit drop;
"""

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


def run(stage, *, conn_params, updated_by="upload", commit=False):
    """Resolve the staged rows; commit only when asked."""
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
