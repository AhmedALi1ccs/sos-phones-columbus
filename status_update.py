"""
Setting the status of one phone number on one property.

Look up an address (or parcel number) together with a phone number: if that
number is already filed under the address its status is changed, and if it is
not, it is added carrying that status.

Kept free of Streamlit so it can be exercised without a browser.
"""

import re

import psycopg2
import psycopg2.extras

from phone_import import KEEPALIVE

STATUSES = {
    "correct": "✅ Correct",
    "wrong":   "❌ Wrong",
    "dead":    "💀 Dead",
}
NO_STATUS = "○ No status"


def normalize_phone(raw):
    """Ten digits, or None if it cannot be one."""
    d = re.sub(r"\D", "", raw or "")
    if len(d) == 11 and d.startswith("1"):
        d = d[1:]
    return d if len(d) == 10 else None


def pretty_phone(d):
    return f"({d[0:3]}) {d[3:6]}-{d[6:]}" if len(d) == 10 else d


def _resolve_sql(by_parcel):
    """The property's address, found from an address or from a parcel number."""
    where = ('public.parcel_norm(b."Parcel Number") = public.parcel_norm(%(key)s)' if by_parcel
             # only the street part: "364 W Lane Ave, Columbus, OH 43201" matches too
             else 'public.addr_norm(b."Property address") = public.addr_norm(split_part(%(key)s, \',\', 1))')
    return f"""
        select min(b."Property address")                    as property_address,
               public.addr_norm(min(b."Property address"))  as addr_key,
               min(b."Property city")                       as property_city,
               min(b."Full Name")                           as full_name,
               min(b."Parcel Number")                       as parcel
        from public."Buybox" b
        where {where}
        having count(*) > 0
    """


def look_up(conn_params, *, key_field, key_value, phone):
    """
    Resolve the address and report what is already filed under it.

    Returns a dict with `error` set when it cannot be acted on, otherwise the
    property, how many Buybox records share its address, the phone row if
    that number is already there, and every number at the address.
    """
    digits = normalize_phone(phone)
    if not (key_value or "").strip():
        return {"error": "Enter an address or a parcel number."}
    if not digits:
        return {"error": "That phone number is not 10 digits."}

    conn = psycopg2.connect(**{**KEEPALIVE, **conn_params})
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(_resolve_sql(key_field == "parcel"), {"key": key_value.strip()})
            hit = cur.fetchone()

            if not hit:
                return {"error": f"No property in Buybox matches that "
                                 f"{'parcel number' if key_field == 'parcel' else 'address'}."}
            # "0" and other placeholders are shared by thousands of records
            if not re.search(r"[A-Z]", hit["addr_key"] or ""):
                return {"error": f"Buybox has no street address for that property "
                                 f"(\"{hit['property_address']}\"), so no number can be filed under it."}

            cur.execute("""select count(*) as n from public."Buybox"
                            where public.addr_norm("Property address") = %s""", (hit["addr_key"],))
            hit["records"] = cur.fetchone()["n"]

            cur.execute("""
                select id, phone, phone_type, status, note, updated_by, updated_at
                from public.property_phones
                where addr_key = %s
                order by slot nulls last, id""", (hit["addr_key"],))
            phones = cur.fetchall()
    finally:
        conn.close()

    existing = next((p for p in phones if normalize_phone(p["phone"]) == digits), None)
    return {"error": None, "property": dict(hit), "digits": digits,
            "existing": dict(existing) if existing else None,
            "phones": [dict(p) for p in phones]}


def apply_status(conn_params, *, address, digits, status,
                 phone_type=None, updated_by=None, commit=True):
    """
    Set the status, adding the number to the address if it is not there yet.
    `address` is the Buybox spelling, from look_up(). Returns what it did:
    'updated' or 'added'.
    """
    conn = psycopg2.connect(**{**KEEPALIVE, **conn_params})
    try:
        with conn.cursor() as cur:
            cur.execute("""
                update public.property_phones
                   set status = %s, updated_by = %s
                 where addr_key = public.addr_norm(%s)
                   and phone_norm = %s
                returning id""", (status, updated_by, address, digits))
            row = cur.fetchone()
            action = "updated"

            if row is None:
                cur.execute("""
                    insert into public.property_phones
                        (address, phone, phone_type, status, slot, updated_by)
                    values (%s, %s, %s, %s,
                            coalesce((select max(slot) from public.property_phones
                                       where addr_key = public.addr_norm(%s)), 0) + 1,
                            %s)
                    returning id""",
                    (address, pretty_phone(digits), phone_type, status, address, updated_by))
                row = cur.fetchone()
                action = "added"

        if commit:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    return {"action": action, "id": row[0] if row else None}
