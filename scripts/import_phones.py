#!/usr/bin/env python3
"""
Import phone numbers into public.property_phones, linking them to Buybox by parcel number.

    python3 scripts/import_phones.py Book1.csv              # dry run, changes nothing
    python3 scripts/import_phones.py Book1.csv --apply      # actually write

Accepts either shape:

    long   Parcel Number, Phone, Phone Type[, Status][, Note]
    wide   Parcel Number, Phone 1, Phone 1 Type, Phone 2, Phone 2 Type, ...

The parcel number may be written with or without its dashes.  Rows that cannot
be matched to Buybox are written to a rejects CSV rather than guessed at.
"""

import argparse, csv, io, os, re, sys
from collections import defaultdict

import psycopg2

DSN = dict(
    host=os.environ.get("PGHOST", "aws-0-eu-west-3.pooler.supabase.com"),
    port=int(os.environ.get("PGPORT", 5432)),
    user=os.environ.get("PGUSER", "postgres.okojvwzrdtcvglaujxau"),
    password=os.environ.get("PGPASSWORD", ""),
    dbname=os.environ.get("PGDATABASE", "postgres"),
)

MAX_PHONES = 30

# vendor wording -> the two values the column accepts
TYPE_MAP = {
    "mobile": "mobile", "cell": "mobile", "cell phone": "mobile", "wireless": "mobile",
    "residential": "landline", "landline": "landline", "land line": "landline",
    "home": "landline", "house": "landline",
}
STATUS_MAP = {
    "correct": "correct", "right": "correct", "good": "correct", "valid": "correct",
    "wrong": "wrong", "bad": "wrong", "incorrect": "wrong",
    "dead": "dead", "disconnected": "dead", "no longer in service": "dead",
}


def parcel_key(p):
    """Must match parcel_norm() in sql/01_schema.sql."""
    return re.sub(r"[^A-Za-z0-9]", "", p or "").upper()


def phone_digits(p):
    d = re.sub(r"\D", "", p or "")
    if len(d) == 11 and d.startswith("1"):
        d = d[1:]
    return d


def pretty_phone(d):
    return f"({d[0:3]}) {d[3:6]}-{d[6:]}" if len(d) == 10 else d


def pick(headers, *candidates):
    """Find a column by any of several spellings, case/space-insensitive."""
    norm = {re.sub(r"[^a-z0-9]", "", h.lower()): h for h in headers}
    for c in candidates:
        k = re.sub(r"[^a-z0-9]", "", c.lower())
        if k in norm:
            return norm[k]
    return None


def read_rows(path):
    """Yield (parcel, phone, type, status, note, source_line) from long OR wide files."""
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        headers = reader.fieldnames or []
        if not headers:
            sys.exit("File has no header row.")

        c_parcel = pick(headers, "Parcel Number", "Parcel", "parcel_number", "APN", "FOLIO")
        if not c_parcel:
            sys.exit(f"No Parcel Number column found. Headers seen: {headers}")

        c_phone = pick(headers, "Phone", "Phone Number", "PhoneNumber", "Number")
        wide = []
        if not c_phone:
            for n in range(1, MAX_PHONES + 1):
                col = pick(headers, f"Phone {n}", f"Phone{n}", f"Phone_{n}")
                if col:
                    wide.append((col,
                                 pick(headers, f"Phone {n} Type", f"Phone{n}Type",
                                      f"Phone {n} Line Type", f"Phone_{n}_Type"),
                                 pick(headers, f"Phone {n} Status", f"Phone{n}Status")))
            if not wide:
                sys.exit(f"No Phone column(s) found. Headers seen: {headers}")

        c_type   = pick(headers, "Phone Type", "Type", "Line Type", "PhoneType")
        c_status = pick(headers, "Status", "Phone Status", "Result")
        c_note   = pick(headers, "Note", "Notes", "Comment")

        print(f"Format: {'wide (' + str(len(wide)) + ' phone columns)' if wide else 'long'}"
              f" · parcel={c_parcel!r}"
              f"{'' if wide else ' · phone=' + repr(c_phone)}"
              f"{' · type=' + repr(c_type) if c_type and not wide else ''}")

        for i, row in enumerate(reader, start=2):
            parcel = (row.get(c_parcel) or "").strip()
            if wide:
                for col, tcol, scol in wide:
                    val = (row.get(col) or "").strip()
                    if val:
                        yield (parcel, val,
                               (row.get(tcol) or "").strip() if tcol else "",
                               (row.get(scol) or "").strip() if scol else "",
                               "", i)
            else:
                yield (parcel, (row.get(c_phone) or "").strip(),
                       (row.get(c_type) or "").strip() if c_type else "",
                       (row.get(c_status) or "").strip() if c_status else "",
                       (row.get(c_note) or "").strip() if c_note else "",
                       i)


def _info(row):
    """How much a parsed row actually tells us: type, status, note."""
    return sum(1 for x in (row[4], row[5], row[6]) if x)


def _merge(a, b):
    """Same number twice in one file: take each field from whichever row has it."""
    return (a[0], a[1], a[2], a[3], a[4] or b[4], a[5] or b[5], a[6] or b[6], min(a[7], b[7]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("--apply", action="store_true", help="write to the database (default: dry run)")
    ap.add_argument("--rejects", default=None, help="where to write unmatched rows")
    ap.add_argument("--fill-type", action="store_true",
                    help="for numbers already present, fill phone_type where it is NULL")
    args = ap.parse_args()

    rejects_path = args.rejects or os.path.splitext(args.csv_path)[0] + "_rejects.csv"
    rejects = []       # (parcel, phone, type, status, reason)
    unknown_types, unknown_statuses = defaultdict(int), defaultdict(int)

    # ---------- 1. read + normalise the file ----------
    # keyed by (parcel, number) so the same number listed twice in one file
    # collapses to a single row -- keeping whichever copy carries the most
    # information, not merely the first one seen.
    staged_by_key = {}
    for parcel, phone, ptype, status, note, line in read_rows(args.csv_path):
        fk, d = parcel_key(parcel), phone_digits(phone)
        if not fk:
            rejects.append((parcel, phone, ptype, status, "no parcel number")); continue
        if len(d) != 10:
            rejects.append((parcel, phone, ptype, status,
                            "phone is not 10 digits" if d else "phone is empty")); continue

        t = TYPE_MAP.get(ptype.strip().lower()) if ptype else None
        if ptype and not t:
            unknown_types[ptype.strip()] += 1
        s = STATUS_MAP.get(status.strip().lower()) if status else None
        if status and not s:
            unknown_statuses[status.strip()] += 1

        row = (parcel.strip(), fk, pretty_phone(d), d, t, s, note or None, line)
        prev = staged_by_key.get((fk, d))
        if prev is None or _info(row) > _info(prev):
            staged_by_key[(fk, d)] = prev and _merge(prev, row) or row

    staged = sorted(staged_by_key.values(), key=lambda r: r[7])

    print(f"Read {len(staged) + len(rejects)} phone rows · {len(staged)} usable · {len(rejects)} rejected outright")
    if unknown_types:
        print("  Unrecognised Phone Type values (stored as NULL): "
              + ", ".join(f"{k!r}×{v}" for k, v in sorted(unknown_types.items(), key=lambda x: -x[1])[:10]))
    if unknown_statuses:
        print("  Unrecognised Status values (stored as NULL): "
              + ", ".join(f"{k!r}×{v}" for k, v in sorted(unknown_statuses.items(), key=lambda x: -x[1])[:10]))
    if not staged:
        write_rejects(rejects_path, rejects)
        return

    # ---------- 2. match to Buybox + load ----------
    conn = psycopg2.connect(**DSN)
    conn.autocommit = False
    cur = conn.cursor()

    cur.execute("""
        create temp table stage (
          parcel text, parcel_key text, phone text, phone_norm text,
          phone_type text, status text, note text, src_line int
        ) on commit drop""")

    buf = io.StringIO()
    w = csv.writer(buf, delimiter="\t", quoting=csv.QUOTE_MINIMAL, escapechar="\\")
    for r in staged:
        w.writerow(["" if x is None else x for x in r])
    buf.seek(0)
    cur.copy_expert("copy stage from stdin with (format csv, delimiter e'\\t', null '')", buf)

    # stored under Buybox's own spelling of the parcel, whatever the file wrote
    cur.execute("""
        create temp table resolved on commit drop as
        select s.*, b."Parcel Number" as buybox_parcel
        from stage s
        left join public."Buybox" b
          on public.parcel_norm(b."Parcel Number") = s.parcel_key""")

    cur.execute("select parcel, phone, coalesce(phone_type,''), coalesce(status,'') "
                "from resolved where buybox_parcel is null")
    missing = cur.fetchall()
    no_match = len(missing)
    rejects.extend([(a, b, c, d, "Parcel Number not found in Buybox") for a, b, c, d in missing])

    # ---------- 3. insert, respecting the 30-per-parcel cap ----------
    cur.execute("""
        create temp table ranked on commit drop as
        select ok.*,
               coalesce(e.n, 0) as already,
               row_number() over (partition by ok.parcel_key order by ok.src_line) as rn
        from (select * from resolved where buybox_parcel is not null) ok
        left join (
          select parcel_key, count(*) n from public.property_phones group by 1
        ) e on e.parcel_key = ok.parcel_key""")
    cur.execute(f"select count(*) from ranked where already + rn <= {MAX_PHONES}")
    will_insert = cur.fetchone()[0]
    cur.execute(f"select count(*) from ranked where already + rn > {MAX_PHONES}")
    over_cap = cur.fetchone()[0]

    cur.execute(f"""
        insert into public.property_phones (parcel, phone, phone_type, status, note, slot, updated_by)
        select buybox_parcel, phone, phone_type, status, note, already + rn, 'import'
        from ranked
        where already + rn <= {MAX_PHONES}
        on conflict (parcel_key, phone_norm) do nothing""")
    inserted = cur.rowcount
    skipped_existing = will_insert - inserted

    filled = 0
    if args.fill_type:
        cur.execute("""
            update public.property_phones p
               set phone_type = t.phone_type
              from ranked t
             where p.parcel_key = t.parcel_key
               and p.phone_norm = t.phone_norm
               and p.phone_type is null
               and t.phone_type is not null""")
        filled = cur.rowcount

    print(f"""
  matched to a parcel ....... {will_insert + over_cap}
  Parcel Number not in Buybox  {no_match}
  over the {MAX_PHONES}-number cap ..... {over_cap}
  already in the table ...... {skipped_existing}
  INSERTED .................. {inserted}{f'''
  phone_type back-filled .... {filled}''' if args.fill_type else ''}""")

    if args.apply:
        conn.commit()
        print("\nCommitted.")
    else:
        conn.rollback()
        print("\nDry run - nothing written. Re-run with --apply to commit.")
    conn.close()

    write_rejects(rejects_path, rejects)


def write_rejects(path, rejects):
    if not rejects:
        print("No rejects.")
        return
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["Parcel Number", "Phone", "Phone Type", "Status", "Reason"])
        w.writerows(rejects)
    print(f"{len(rejects)} rejected row(s) written to {path}")


if __name__ == "__main__":
    main()
