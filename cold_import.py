"""
Loading cold calling lists.

A row is an address, a number and where the number came from. The address is
resolved to a parcel when BuyBox knows it, which is what lets a row link to the
property page -- but an address BuyBox does not know is still loaded, without a
parcel, because a calling list is worth having either way. That is the one place
this differs from the phone uploader, which rejects what it cannot place.

Kept free of Streamlit so it can be exercised without a browser.
"""

import io

import pandas as pd
import psycopg2

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
       b.folio, b.county, coalesce(b.parcels, 0)                as parcels
from stage s
left join lateral (
  select min(bb."FOLIO")           as folio,
         min(bb."Property county") as county,
         count(distinct (public.folio_norm(bb."FOLIO"),
                         public.county_norm(bb."Property county"))) as parcels
  from public."BuyBox" bb
  where public.addr_norm(bb."Property address") = public.addr_norm(s.address)
    and coalesce(btrim(bb."FOLIO"), '') <> ''
) b on true;

create temp table classified on commit drop as
select r.*,
       -- only an unambiguous address earns a parcel link; the row loads either way
       case when r.parcels = 1 then r.folio  end as link_folio,
       case when r.parcels = 1 then r.county end as link_county,
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
       link_folio                                       as folio,
       link_county                                      as county,
       row_no
from classified
where reject_reason is null
order by upper(public.fold_street_words(address)), right(digits, 10),
         coalesce(btrim(source), ''), row_no;
"""

INSERT_SQL = """
insert into public."ColdCalling" (address, phone, source, folio, county, uploaded_src)
select address, phone, source, folio, county, %s
from to_load
on conflict (addr_key, phone_norm, coalesce(source, '')) do nothing;
"""


def run(stage, *, conn_params, source_label="upload", commit=False):
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

            cur.execute("select count(*) from to_load")
            loadable = cur.fetchone()[0]
            cur.execute("select count(*) from to_load where folio is not null")
            linked = cur.fetchone()[0]

            cur.execute("""
                select row_no, address, phone, source, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            cur.execute(INSERT_SQL, (source_label,))
            inserted = cur.rowcount

            cur.execute("""
                select t.address, t.phone, t.source,
                       coalesce(t.folio, '—'), coalesce(b."Full Name", '')
                from to_load t
                left join lateral (
                  select bb."Full Name" from public."BuyBox" bb
                  where public.folio_norm(bb."FOLIO") = public.folio_norm(t.folio) limit 1
                ) b on true
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
