"""
Setting the status of one phone number on one property.

Look up an address (or parcel number) together with a phone number: if that
number is already on the property its status is changed, and if it is not, it
is added carrying that status.

Kept free of Streamlit so it can be exercised without a browser.
"""

import re

import psycopg2
import psycopg2.extras

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


def _resolve_sql(by_parcel, city, zipcode):
    """
    Build the parcel lookup. The narrowing clauses are added only when they are
    actually given: written as `%(city)s = '' or ...` they would sit in the
    predicate as an OR and cost the query its index.
    """
    where = [('public.parcel_norm(b."Parcel Number") = public.parcel_norm(%(key)s)' if by_parcel
              # only the street part: "364 W Lane Ave, Columbus, OH 43201" matches too
              else 'public.addr_norm(b."Property address") = public.addr_norm(split_part(%(key)s, \',\', 1))')]
    if city:
        where.append('lower(btrim(b."Property city")) = lower(btrim(%(city)s))')
    if zipcode:
        where.append('btrim(coalesce(b."Property zip", \'\')) = btrim(%(zip)s)')

    return f"""
        select min(b."Parcel Number")                as parcel,
               min(b."Property address")             as property_address,
               min(b."Property city")                as property_city,
               min(b."Full Name")                    as full_name,
               count(*)                              as parcels
        from public."Buybox" b
        where {' and '.join(where)}
    """


def look_up(conn_params, *, key_field, key_value, phone, city="", zipcode=""):
    """
    Resolve the property and report what is already on it.

    Returns a dict with `error` set when it cannot be acted on, otherwise the
    property, the phone row if that number is already there, and every number
    on the property for context.
    """
    digits = normalize_phone(phone)
    if not (key_value or "").strip():
        return {"error": "Enter an address or a parcel number."}
    if not digits:
        return {"error": "That phone number is not 10 digits."}

    args = {"key": key_value.strip(), "city": city.strip(), "zip": zipcode.strip()}

    conn = psycopg2.connect(**conn_params)
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(_resolve_sql(key_field == "parcel", args["city"], args["zip"]), args)
            hit = cur.fetchone()

            if not hit or not hit["parcels"]:
                return {"error": f"No property in Buybox matches that "
                                 f"{'parcel number' if key_field == 'parcel' else 'address'}."}
            if hit["parcels"] > 1:
                return {"error": f"That matches {hit['parcels']} different properties. "
                                 f"Add a City or Zip to narrow it."}

            cur.execute("""
                select id, phone, phone_type, status, note, updated_by, updated_at
                from public.property_phones
                where parcel_key = public.parcel_norm(%s)
                order by slot nulls last, id""", (hit["parcel"],))
            phones = cur.fetchall()
    finally:
        conn.close()

    existing = next((p for p in phones if normalize_phone(p["phone"]) == digits), None)
    return {"error": None, "property": dict(hit), "digits": digits,
            "existing": dict(existing) if existing else None,
            "phones": [dict(p) for p in phones]}


def apply_status(conn_params, *, parcel, digits, status,
                 phone_type=None, updated_by=None, commit=True):
    """
    Set the status, adding the number to the property if it is not there yet.
    Returns what it did: 'updated' or 'added'.
    """
    conn = psycopg2.connect(**conn_params)
    try:
        with conn.cursor() as cur:
            cur.execute("""
                update public.property_phones
                   set status = %s, updated_by = %s
                 where parcel_key = public.parcel_norm(%s)
                   and phone_norm = %s
                returning id""", (status, updated_by, parcel, digits))
            row = cur.fetchone()
            action = "updated"

            if row is None:
                cur.execute("""
                    insert into public.property_phones
                        (parcel, phone, phone_type, status, slot, updated_by)
                    values (%s, %s, %s, %s,
                            coalesce((select max(slot) from public.property_phones
                                       where parcel_key = public.parcel_norm(%s)), 0) + 1,
                            %s)
                    returning id""",
                    (parcel, pretty_phone(digits), phone_type, status, parcel, updated_by))
                row = cur.fetchone()
                action = "added"

        if commit:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    return {"action": action, "id": row[0] if row else None}
