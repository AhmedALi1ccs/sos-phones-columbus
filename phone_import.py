"""
Resolving and loading phone numbers into property_phones.

Kept free of Streamlit so the whole pipeline can be exercised without a
browser: streamlit_app.py is only the user interface over this.

A row that carries a Parcel Number is matched on it; the rest by address.
Normalisation happens in SQL, using the same functions the website uses, so
this cannot drift away from what the site considers the same parcel.
"""

import io

import pandas as pd
import psycopg2

MAX_PHONES = 30

# the column order the stage table expects
STAGE_COLUMNS = ["row_no", "parcel_in", "address", "city", "zip",
                 "phone", "ptype", "status_in"]


def build_stage(df, mapping, first_row=2):
    """Turn an uploaded dataframe plus a {field: column name} mapping into stage rows."""
    def col(field):
        name = mapping.get(field)
        if not name or name not in df.columns:
            return pd.Series([""] * len(df), index=df.index)
        return df[name].astype(str)

    return pd.DataFrame({
        "row_no": range(first_row, first_row + len(df)),
        "parcel_in": col("parcel"),
        "address": col("address"),
        "city": col("city"),
        "zip": col("zip"),
        "phone": col("phone"),
        "ptype": col("ptype"),
        "status_in": col("status"),
    })


RESOLVE_SQL = """
create temp table stage (
  row_no int, parcel_in text, address text, city text,
  zip text, phone text, ptype text, status_in text
) on commit drop;
"""

NARROW = """
     (btrim(coalesce(s.city,'')) = '' or lower(btrim(b."Property city")) = lower(btrim(s.city)))
 and (btrim(coalesce(s.zip,''))  = '' or btrim(coalesce(b."Property zip",'')) = btrim(s.zip))
"""

CLASSIFY_SQL = (f"""
create temp table resolved on commit drop as
select s.row_no, s.parcel_in, s.address, s.city, s.zip, s.phone, s.ptype, s.status_in,
       regexp_replace(coalesce(s.phone,''), '\\D', '', 'g')                       as digits,
       case lower(btrim(coalesce(s.ptype,'')))
         when 'mobile'      then 'mobile'   when 'cell'     then 'mobile'
         when 'cell phone'  then 'mobile'   when 'wireless' then 'mobile'
         when 'residential' then 'landline' when 'landline' then 'landline'
         when 'land line'   then 'landline' when 'home'     then 'landline'
         when 'house'       then 'landline'
         else null
       end                                                                       as phone_type,
       case lower(btrim(coalesce(s.status_in,'')))
         when 'correct' then 'correct'  when 'right'  then 'correct'
         when 'good'    then 'correct'  when 'valid'  then 'correct'
         when 'yes'     then 'correct'
         when 'wrong'   then 'wrong'    when 'bad'    then 'wrong'
         when 'incorrect' then 'wrong'  when 'no'     then 'wrong'
         when 'dead'    then 'dead'     when 'disconnected' then 'dead'
         when 'no longer in service' then 'dead'
         when '' then null
         else '?'                       -- anything else is reported, not guessed
       end                                                                       as status,
       case when btrim(coalesce(s.parcel_in,'')) <> '' then 'Parcel Number' else 'address' end as matched_by,
       case when btrim(coalesce(s.parcel_in,'')) <> '' then bf.parcel else ba.parcel end as parcel,
       case when btrim(coalesce(s.parcel_in,'')) <> ''
            then coalesce(bf.parcels, 0) else coalesce(ba.parcels, 0) end            as parcels,
       case when btrim(coalesce(s.parcel_in,'')) <> ''
            then coalesce(bf.parcels_before_narrowing, 0)
            else coalesce(ba.parcels_before_narrowing, 0) end                        as parcels_before_narrowing
from stage s
-- Two separate lookups rather than one with a CASE in the WHERE: a CASE there
-- cannot be turned into an index condition, and each staged row would trigger
-- a 418k-row scan. When the other key is blank its norm is NULL, so that
-- lookup matches nothing and costs an index probe.
--
-- City/Zip narrow the result through FILTER rather than WHERE, so the key
-- match stays indexable and we can still tell "key is unknown" apart from
-- "key is known but your City/Zip excluded it".
left join lateral (
  select min(b."Parcel Number") filter (where %(narrow)s)                        as parcel,
         count(*)               filter (where %(narrow)s)                        as parcels,
         count(*)                                                                as parcels_before_narrowing
  from public."Buybox" b
  where public.parcel_norm(b."Parcel Number") = public.parcel_norm(s.parcel_in)
) bf on true
left join lateral (
  select min(b."Parcel Number") filter (where %(narrow)s)                        as parcel,
         count(*)               filter (where %(narrow)s)                        as parcels,
         count(*)                                                                as parcels_before_narrowing
  from public."Buybox" b
  -- only the street part: a file may write "364 W Lane Ave, Columbus, OH 43201",
  -- and no Buybox address contains a comma
  where public.addr_norm(b."Property address") = public.addr_norm(split_part(s.address, ',', 1))
) ba on true;

create temp table classified on commit drop as
select r.*,
       case
         when btrim(coalesce(r.parcel_in,'')) = '' and btrim(coalesce(r.address,'')) = ''
           then 'row has neither a Parcel Number nor an address'
         when not (length(r.digits) = 10
                   or (length(r.digits) = 11 and left(r.digits, 1) = '1'))
           then 'phone is not a 10 digit number'
         when r.status = '?'
           then 'status is not one of correct / wrong / dead' 
         when r.parcels = 0 and r.parcels_before_narrowing > 0
           then r.matched_by || ' exists, but the City/Zip in this row does not match Buybox'
         when r.parcels = 0
           then r.matched_by || ' not found in Buybox'
         when r.parcels > 1
           then r.matched_by || ' is used by ' || r.parcels
                || ' different properties - add City or Zip to narrow it'
         else null
       end as reject_reason
from resolved r;

-- one row per number per parcel; the fullest copy of a number wins
create temp table to_load on commit drop as
select distinct on (public.parcel_norm(parcel), norm)
       parcel, phone_fmt as phone, phone_type, status, row_no, norm, matched_by
from (
  select c.parcel, c.phone_type, c.status, c.row_no, c.matched_by,
         right(c.digits, 10) as norm,
         '(' || substr(right(c.digits, 10), 1, 3) || ') '
             || substr(right(c.digits, 10), 4, 3) || '-'
             || substr(right(c.digits, 10), 7, 4) as phone_fmt
  from classified c
  where c.reject_reason is null
) x
order by public.parcel_norm(parcel), norm,
         (status is null), (phone_type is null), row_no;

-- respect the 30-per-parcel cap, counting what is already stored
create temp table ranked on commit drop as
select t.*,
       coalesce(e.n, 0) as already,
       row_number() over (partition by public.parcel_norm(t.parcel) order by t.row_no) as rn
from to_load t
left join (
  select parcel_key, count(*) n from public.property_phones group by 1
) e on e.parcel_key = public.parcel_norm(t.parcel);
""" % {"narrow": NARROW})

INSERT_SQL = f"""
insert into public.property_phones (parcel, phone, phone_type, status, slot, updated_by)
select parcel, phone, phone_type, status, already + rn, %s
from ranked
where already + rn <= {MAX_PHONES}
on conflict (parcel_key, phone_norm) do nothing;
"""

# For numbers already on the property, the insert above does nothing, so the
# status has to be applied separately. Only rows whose file gave a status are
# touched, and an existing line type is left alone rather than overwritten.
UPDATE_STATUS_SQL = """
update public.property_phones p
   set status = r.status,
       phone_type = coalesce(p.phone_type, r.phone_type),
       updated_by = %s
  from ranked r
 where p.parcel_key = public.parcel_norm(r.parcel)
   and p.phone_norm = r.norm
   and r.status is not null
   and p.status is distinct from r.status;
"""


def run(stage, *, conn_params, updated_by="upload", commit=False, set_status=False):
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
                select row_no, parcel_in, address, city, zip, phone, ptype, status_in, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            status_changed = 0
            if set_status:
                cur.execute(UPDATE_STATUS_SQL, (updated_by or None,))
                status_changed = cur.rowcount

            cur.execute(INSERT_SQL, (updated_by or None,))
            inserted = cur.rowcount

            cur.execute("""
                select r.matched_by, r.parcel, r.phone, r.phone_type, r.status,
                       b."Property address", b."Full Name"
                from ranked r
                join public."Buybox" b on b."Parcel Number" = r.parcel
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
        "status_changed": status_changed,
        "already_there": loadable - inserted, "preview": preview,
    }
