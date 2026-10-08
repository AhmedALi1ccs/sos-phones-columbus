"""
Loading contact lists: cold calling, or anything else of the same shape.

A row is an address, a number and where the number came from. The address is
resolved to a parcel when Buybox knows it, which is what lets a row link to the
property page -- but an address Buybox does not know is still loaded, without a
parcel, because the list is worth having either way. That is the one place this
differs from the phone uploader, which rejects what it cannot place.

The table is a parameter so a second list of the same shape needs only a new
entry in TABLES, not a second copy of these rules.

Kept free of Streamlit so it can be exercised without a browser.
"""

import io

import pandas as pd
import psycopg2

from phone_import import KEEPALIVE

STAGE_COLUMNS = ["row_no", "address", "phone", "source"]


def build_stage(df, mapping, first_row=2):
    def col(field):
        name = mapping.get(field)
        if not name or name not in df.columns:
            return pd.Series([""] * len(df), index=df.index)
        return df[name].astype(str)

    return pd.DataFrame({
        "row_no": range(first_row, first_row + len(df)),
        "address": col("address"),
        "phone": col("phone"),
        "source": col("source"),
    })


RESOLVE_SQL = """
create temp table stage (row_no int, address text, phone text, source text) on commit drop;
"""

CLASSIFY_SQL = """
create temp table resolved on commit drop as
select s.row_no, s.address, s.phone, s.source,
       regexp_replace(coalesce(s.phone,''), '\\D', '', 'g')     as digits,
       b.parcel, coalesce(b.parcels, 0)                         as parcels
from stage s
left join lateral (
  select min(bb."Parcel Number") as parcel, count(*) as parcels
  from public."Buybox" bb
  -- only the street part: "364 W Lane Ave, Columbus, OH 43201" matches too
  where public.addr_norm(bb."Property address") = public.addr_norm(split_part(s.address, ',', 1))
) b on true;

create temp table classified on commit drop as
select r.*,
       -- only an unambiguous address earns a parcel link; the row loads either way
       case when r.parcels = 1 then r.parcel end as link_parcel,
       case
         when btrim(coalesce(r.address,'')) = ''   then 'no address in the row'
         when not (length(r.digits) = 10
                   or (length(r.digits) = 11 and left(r.digits, 1) = '1'))
           then 'phone is not a 10 digit number'
         else null
       end as reject_reason
from resolved r;

create temp table to_load on commit drop as
select distinct on (upper(public.fold_street_words(address)),
                    right(digits, 10), coalesce(btrim(source), ''))
       btrim(address)                                   as address,
       '(' || substr(right(digits, 10), 1, 3) || ') '
           || substr(right(digits, 10), 4, 3) || '-'
           || substr(right(digits, 10), 7, 4)           as phone,
       nullif(btrim(coalesce(source, '')), '')          as source,
       link_parcel                                      as parcel,
       row_no
from classified
where reject_reason is null
order by upper(public.fold_street_words(address)), right(digits, 10),
         coalesce(btrim(source), ''), row_no;
"""

# the only table-specific statement; any table in TABLES has the same
# conflict target, so nothing else has to change per list
INSERT_SQL = """
insert into public.{table} (address, phone, source, parcel, uploaded_src)
select address, phone, source, parcel, %s
from to_load
on conflict (addr_key, phone_norm, coalesce(source, '')) do nothing;
"""

TABLES = {"ColdCalling"}


def run(stage, *, conn_params, table="ColdCalling", source_label="upload", commit=False):
    if table not in TABLES:
        raise ValueError(f"unknown table {table!r}")

    buf = io.StringIO()
    stage.to_csv(buf, index=False, header=False)
    buf.seek(0)

    conn = psycopg2.connect(**{**KEEPALIVE, **conn_params})
    try:
        with conn.cursor() as cur:
            cur.execute(RESOLVE_SQL)
            cur.copy_expert("copy stage from stdin with (format csv)", buf)
            cur.execute(CLASSIFY_SQL)

            cur.execute("select reject_reason, count(*) from classified group by 1 order by 2 desc")
            reasons = cur.fetchall()

            cur.execute("select count(*) from to_load")
            loadable = cur.fetchone()[0]
            cur.execute("select count(*) from to_load where parcel is not null")
            linked = cur.fetchone()[0]

            cur.execute("""
                select row_no, address, phone, source, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            cur.execute(INSERT_SQL.format(table=f'"{table}"'), (source_label,))
            inserted = cur.rowcount

            cur.execute("""
                select t.address, t.phone, t.source,
                       coalesce(t.parcel, '—'), coalesce(b."Full Name", '')
                from to_load t
                left join public."Buybox" b on b."Parcel Number" = t.parcel
                order by t.row_no limit 25""")
            preview = cur.fetchall()

        if commit:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    return {"reasons": reasons, "loadable": loadable, "linked": linked,
            "unlinked": loadable - linked, "inserted": inserted,
            "already_there": loadable - inserted, "rejects": rejects,
            "preview": preview}
