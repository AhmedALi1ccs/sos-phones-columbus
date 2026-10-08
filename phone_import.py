"""
Resolving and loading phone numbers into property_phones.

Kept free of Streamlit so the whole pipeline can be exercised without a
browser: streamlit_app.py is only the user interface over this.

Phone numbers belong to a property address, not to a parcel: every Buybox
record at that address shows them. A row is matched by its address, or -- if
the file is matched by Parcel Number -- by the address of that parcel. Either
way the address must exist in Buybox, so a typo is reported instead of stored.
Normalisation happens in SQL, using the same addr_norm() the website uses, so
the two cannot disagree about what is the same address.
"""

import io
import re

import pandas as pd
import psycopg2

MAX_PHONES = 30

# A big load spends minutes inside one statement with nothing crossing the
# wire, and an idle connection gets dropped on the way to Supabase ("SSL SYSCALL
# error: EOF detected" partway through a 500k-number insert). TCP keepalives
# keep it open.
KEEPALIVE = dict(keepalives=1, keepalives_idle=30, keepalives_interval=10, keepalives_count=6)

# the column order the stage table expects
STAGE_COLUMNS = ["row_no", "parcel_in", "address", "phone", "ptype", "status_in"]


def wide_phone_columns(columns):
    """
    Phone1 / Phone 1 / Phone_1 ..., each with its own "PhoneN Type" if present,
    as [(phone column, type column or None), ...] in number order. Skip-trace
    exports come in this shape: one row per property, several numbers across.
    """
    def key(c):
        return re.sub(r"[\s_]+", "", c.lower())
    phones, types = {}, {}
    for c in columns:
        m = re.fullmatch(r"phone(\d+)", key(c))
        if m:
            phones[int(m.group(1))] = c
        m = re.fullmatch(r"phone(\d+)(?:line)?type", key(c))
        if m:
            types[int(m.group(1))] = c
    return [(phones[n], types.get(n)) for n in sorted(phones)]


def build_stage(df, mapping, first_row=2):
    """
    Turn an uploaded dataframe plus a {field: column name} mapping into stage rows.

    mapping["phone_cols"], when given, is the wide shape -- [(phone column, type
    column), ...] -- and each filled one becomes a row of its own, carrying the
    file's row number. Otherwise mapping["phone"] / ["ptype"] is one per row.
    """
    def col(field):
        name = mapping.get(field)
        if not name or name not in df.columns:
            return pd.Series([""] * len(df), index=df.index)
        return df[name].astype(str)

    base = pd.DataFrame({
        "row_no": range(first_row, first_row + len(df)),
        "parcel_in": col("parcel"),
        "address": col("address"),
    }, index=df.index)

    pairs = mapping.get("phone_cols")
    if not pairs:
        base["phone"] = col("phone")
        base["ptype"] = col("ptype")
        base["status_in"] = col("status")
        return base[STAGE_COLUMNS]

    parts = []
    for phone_col, type_col in pairs:
        part = base.copy()
        part["phone"] = df[phone_col].astype(str)
        part["ptype"] = df[type_col].astype(str) if type_col else ""
        part["status_in"] = col("status")
        parts.append(part[part["phone"].str.strip() != ""])
    if not parts:
        return pd.DataFrame(columns=STAGE_COLUMNS)
    return pd.concat(parts).sort_values("row_no", kind="stable")[STAGE_COLUMNS]


RESOLVE_SQL = """
create temp table stage (
  row_no int, parcel_in text, address text, phone text, ptype text, status_in text
) on commit drop;
"""

CLASSIFY_SQL = """
-- What each row is looked up by. A file of 500k numbers has ~130k distinct
-- addresses, so each one is resolved once, below, rather than once per number.
create temp table keyed on commit drop as
select s.*,
       btrim(coalesce(s.parcel_in, ''))                                          as pk_in,
       -- only the street part: a file may write "364 W Lane Ave, Columbus, OH 43201",
       -- and no Buybox address contains a comma
       case when btrim(coalesce(s.parcel_in, '')) = ''
            then btrim(split_part(coalesce(s.address, ''), ',', 1)) else '' end  as ak_in
from stage s;

create temp table key_hits on commit drop as
select k.pk_in, k.ak_in,
       coalesce(bf.address, ba.address)            as prop_address,
       coalesce(bf.addr_key, ba.addr_key)          as addr_key,
       coalesce(bf.records, ba.records, 0)         as records
from (select distinct pk_in, ak_in from keyed) k
-- Two separate lookups rather than one with a CASE in the WHERE: a CASE there
-- cannot be turned into an index condition, and each key would trigger a
-- 418k-row scan. When the other key is blank its norm is NULL, so that
-- lookup matches nothing and costs an index probe.
left join lateral (
  select min(b."Property address")                    as address,
         public.addr_norm(min(b."Property address"))  as addr_key,
         (select count(*) from public."Buybox" bb
           where public.addr_norm(bb."Property address") = public.addr_norm(min(b."Property address"))) as records
  from public."Buybox" b
  where k.pk_in <> ''
    and public.parcel_norm(b."Parcel Number") = public.parcel_norm(k.pk_in)
  having count(*) > 0
) bf on true
left join lateral (
  select min(b."Property address")                    as address,
         public.addr_norm(min(b."Property address"))  as addr_key,
         count(*)                                     as records
  from public."Buybox" b
  where k.ak_in <> ''
    and public.addr_norm(b."Property address") = public.addr_norm(k.ak_in)
  having count(*) > 0
) ba on true;

create temp table resolved on commit drop as
select s.row_no, s.parcel_in, s.address, s.phone, s.ptype, s.status_in,
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
       case when s.pk_in <> '' then 'Parcel Number' else 'address' end           as matched_by,
       h.prop_address, h.addr_key, h.records
from keyed s
join key_hits h on h.pk_in = s.pk_in and h.ak_in = s.ak_in;

create temp table classified on commit drop as
select r.*,
       case
         when btrim(coalesce(r.parcel_in,'')) = '' and btrim(coalesce(r.address,'')) = ''
           then 'row has no address'
         when not (length(r.digits) = 10
                   or (length(r.digits) = 11 and left(r.digits, 1) = '1'))
           then 'phone is not a 10 digit number'
         when r.status = '?'
           then 'status is not one of correct / wrong / dead'
         when r.addr_key is null
           then r.matched_by || ' not found in Buybox'
         -- "0" and other placeholders: thousands of records share them, so a
         -- number filed there would show on all of them
         when r.addr_key !~ '[A-Z]'
           then 'Buybox has no street address for this property ("' || r.prop_address || '")'
         else null
       end as reject_reason
from resolved r;

-- one row per number per address; the fullest copy of a number wins
create temp table to_load on commit drop as
select distinct on (addr_key, norm)
       prop_address as address, addr_key, records, phone_fmt as phone,
       phone_type, status, row_no, norm, matched_by
from (
  select c.prop_address, c.addr_key, c.records, c.phone_type, c.status, c.row_no, c.matched_by,
         right(c.digits, 10) as norm,
         '(' || substr(right(c.digits, 10), 1, 3) || ') '
             || substr(right(c.digits, 10), 4, 3) || '-'
             || substr(right(c.digits, 10), 7, 4) as phone_fmt
  from classified c
  where c.reject_reason is null
) x
order by addr_key, norm, (status is null), (phone_type is null), row_no;

-- respect the 30-per-address cap, counting what is already stored
create temp table ranked on commit drop as
select t.*,
       coalesce(e.n, 0) as already,
       row_number() over (partition by t.addr_key order by t.row_no) as rn,
       row_number() over (order by t.row_no, t.norm)                 as seq   -- for inserting in batches
from to_load t
left join (
  select addr_key, count(*) n from public.property_phones group by 1
) e on e.addr_key = t.addr_key;

create index on ranked (seq);
"""

# Rows go in INSERT_BATCH at a time, each its own statement in the one
# transaction: a single 450k-row insert sat silent for minutes and Supabase's
# pooler dropped the connection under it ("SSL SYSCALL error: EOF detected").
INSERT_BATCH = 20000

INSERT_SQL = f"""
insert into public.property_phones (address, phone, phone_type, status, slot, updated_by)
select address, phone, phone_type, status, already + rn, %s
from ranked
where already + rn <= {MAX_PHONES}
  and seq > %s and seq <= %s
on conflict (addr_key, phone_norm) do nothing;
"""

# For numbers already at the address, the insert above does nothing, so the
# status has to be applied separately. Only rows whose file gave a status are
# touched, and an existing line type is left alone rather than overwritten.
UPDATE_STATUS_SQL = """
update public.property_phones p
   set status = r.status,
       phone_type = coalesce(p.phone_type, r.phone_type),
       updated_by = %s
  from ranked r
 where p.addr_key   = r.addr_key
   and p.phone_norm = r.norm
   and r.status is not null
   and p.status is distinct from r.status;
"""


def run(stage, *, conn_params, updated_by="upload", commit=False, set_status=False,
        progress=None):
    """
    Resolve the staged rows; commit only when asked.

    progress(fraction, message), if given, is called as the work goes: a
    skip-trace file of half a million numbers takes several minutes.
    """
    say = progress or (lambda fraction, message: None)
    buf = io.StringIO()
    stage.to_csv(buf, index=False, header=False)
    buf.seek(0)

    conn = psycopg2.connect(**{**KEEPALIVE, **conn_params})
    try:
        with conn.cursor() as cur:
            # a skip-trace file of 500k numbers takes minutes, past the owner
            # role's 2 minute statement timeout; this lasts only as long as the
            # transaction
            cur.execute("set local statement_timeout = 0")
            cur.execute(RESOLVE_SQL)
            say(0.02, f"Sending {len(stage):,} rows…")
            cur.copy_expert("copy stage from stdin with (format csv)", buf)
            say(0.05, "Matching addresses against Buybox…")
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
            cur.execute("select count(*) from ranked where records > 1")
            shared = cur.fetchone()[0]

            cur.execute("""
                select row_no, parcel_in, address, phone, ptype, status_in, reject_reason
                from classified where reject_reason is not null order by row_no""")
            rejects = cur.fetchall()

            status_changed = 0
            if set_status:
                cur.execute(UPDATE_STATUS_SQL, (updated_by or None,))
                status_changed = cur.rowcount

            cur.execute("select coalesce(max(seq), 0) from ranked")
            last = cur.fetchone()[0]
            inserted = 0
            for lo in range(0, last, INSERT_BATCH):
                say(0.4 + 0.55 * lo / max(last, 1),
                    f"{'Inserting' if commit else 'Checking'} numbers… {lo:,} of {last:,}")
                cur.execute(INSERT_SQL, (updated_by or None, lo, lo + INSERT_BATCH))
                inserted += cur.rowcount
            say(0.97, "Finishing…")

            cur.execute("""
                select r.matched_by, r.address, r.records, r.phone, r.phone_type, r.status
                from ranked r
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
        "status_changed": status_changed, "shared": shared,
        "already_there": loadable - inserted, "preview": preview,
    }
