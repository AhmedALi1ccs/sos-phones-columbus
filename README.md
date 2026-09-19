# SOS Phones

A static site (GitHub Pages) for searching the `BuyBox` property list in Supabase and
tracking phone numbers per property.

- **Search** by any part of a property address, owner name, mailing address or FOLIO,
  with a dropdown to pick which field to search. The chosen field is kept in the URL
  (`?q=juniper&f=property`) so a search can be shared or reached with the back button.
- **Property page** shows the owner + address block, the `Lists` distresses, mail history,
  and up to **30 phone numbers**, each with a status: ✅ Correct · ❌ Wrong · 💀 Dead
  (no status = ○). Click a symbol to set it, click it again to clear it.

## Setup

1. **Run the SQL** (once) against the Supabase database:

   ```bash
   export PGPASSWORD='...'
   psql -h aws-1-us-east-2.pooler.supabase.com -p 5432 \
        -U postgres.hoahkpeblfxjbkhwbdxs -d postgres \
        -f sql/01_schema.sql -f sql/02_search_and_rls.sql
   ```

2. **Paste the anon key** into `config.js`
   (Supabase → Project Settings → API → `anon` `public` key).

3. **Publish**: push to GitHub, then Settings → Pages → Source: `main` / root.

## Local preview

```bash
python3 -m http.server 8080
# open http://localhost:8080
```

## What the SQL creates

| Object | Purpose |
| --- | --- |
| `buybox_search_trgm` | GIN trigram **expression** index over name + property address + mailing address. The `BuyBox` table itself is untouched, so bulk `COPY`/`INSERT` loads keep working. |
| `search_properties(q, max_rows, skip, field)` | Used by the search box; `field` is `all` \| `property` \| `name` \| `mailing` \| `folio`. Splits the query into tokens, requires every token to match somewhere in the record, folds typed words to the abbreviations the data uses (`street`→`st`, `drive`→`dr`, …), and ranks property-address hits first. A scoped search still filters through the indexed full-record expression first, so no extra index is needed per field — and it runs ~5× faster than `all` because less survives to be ranked. `folio` is matched on the normalised parcel number instead, so `F# 077G222`, `077G222` and the fragment `077G22` all work. |
| `folio_norm()` / `county_norm()` | How a parcel is compared: the cosmetic `F# ` prefix and all punctuation stripped, case-folded. `F# 0442207000`, `f#0442207000` and `0442207000` are the same parcel. **`assets/db.js` has matching `folioKey()`/`countyKey()` — change one and you must change the other.** |
| `search_properties` / `get_property` / `get_mail_history` | RPCs the pages call. Properties are addressed by **parcel**, not by `BuyBox.id`. |
| `property_phones` | One row per phone number, keyed to the property by **FOLIO + county**. |
| RLS policies | Anyone with the link can **read** `BuyBox`/`Mailed` and **read+write** `property_phones`. `INSERT/UPDATE/DELETE` on `BuyBox`/`Mailed` are revoked from the public key. |

### Why phones are keyed on FOLIO + county, not `BuyBox.id`

`BuyBox.id` is unique but **not stable** — reload BuyBox from a fresh export and the ids
get reassigned, which would silently move every phone number onto the wrong property.
Parcel numbers survive a reload.

FOLIO alone is not enough either: parcel numbers are unique *per county*, so **139 folios
in BuyBox are shared by two genuinely different properties** in different counties
(`F# 0310002020` is both *1221 George C Wilson Dr, Augusta GA* and *167 Miles Ashley Rd,
Trenton SC*). FOLIO + county reduces that to 3 collisions, all of which are true duplicate
rows of the same property. 712 rows (0.25%) have no FOLIO and cannot hold phone numbers;
the property page says so plainly.

> ⚠️ `folio_norm()` is used inside expression indexes. If you ever change it,
> **drop and recreate** `buybox_folio_idx`, `buybox_folio_county_idx` and `mailed_folio_idx` —
> Postgres does not rebuild them, and folio lookups will silently return nothing.

### `property_phones`

| Column | Notes |
| --- | --- |
| `folio` | as stored in BuyBox, e.g. `F# 0442207000` |
| `county` | disambiguates parcel numbers reused across counties |
| `folio_key`, `county_key` | normalised, generated — what lookups and the unique index use |
| `phone` | as entered / displayed |
| `phone_norm` | digits only, generated — unique per parcel, so the same number can't be added twice |
| `slot` | display order, 1–30 |
| `phone_type` | `landline` \| `mobile` \| `NULL` — shown as ☎️ / 📱 |
| `status` | `correct` \| `wrong` \| `dead` \| `NULL` |
| `note` | optional free text |
| `updated_by` | initials typed in the header (stored in the browser) |
| `created_at`, `updated_at` | `updated_at` maintained by trigger |

A trigger refuses the 31st number for a parcel.

## Importing phone numbers

Long format, one row per phone:

```csv
FOLIO,Phone,Phone Type
F# 077G222,7068369448,Mobile
F# 077G222,7062284754,Residential
```

Wide format (`Phone 1`, `Phone 1 Type`, … `Phone 30`) works too.

```bash
python3 scripts/import_phones.py Book1.csv           # dry run, writes nothing
python3 scripts/import_phones.py Book1.csv --apply   # commit
```

The importer runs inside a transaction and **defaults to a dry run**, printing what
would happen. Anything it cannot place — folio missing, folio not in BuyBox, ambiguous
parcel, malformed number, over the 30 cap — goes to `<file>_rejects.csv` with a reason.
Numbers already in the table are skipped rather than duplicated, so re-running the same
file is safe. `--fill-type` additionally back-fills `phone_type` on rows that are already
there but have none.

- **`FOLIO`** — required, in any format; the `F# ` prefix is optional.
- **`Phone`** — required, in any format.
- **`Phone Type`** — optional. Vendor wording is mapped to the two stored values:
  `Mobile`/`Wireless`/`Cell` → `mobile`, `Residential`/`Landline`/`Home` → `landline`.
  Anything else is stored as `NULL` and reported.
- **`Status`** — optional, if you already have call outcomes.
- **County** is looked up from BuyBox, not supplied. Only the 139 ambiguous parcel
  numbers can't be resolved that way; those go to a rejects file rather than being guessed.
- Owner and address columns are not needed — they already live in `BuyBox`.

> **Note on access:** the site is deliberately open — the anon key ships in `config.js`,
> so anyone with the page URL can read the property list and edit phone statuses.
> Adding Supabase email login later means swapping the policies from `anon` to
> `authenticated` in `sql/02_search_and_rls.sql`.
