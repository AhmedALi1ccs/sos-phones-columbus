# SOS Phones

A static site (GitHub Pages) for searching the `BuyBox` property list in Supabase and
tracking phone numbers per property.

- **Search** by any part of a property address, owner name, or mailing address.
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
| `search_properties(q, max_rows, skip)` | RPC used by the search box. Splits the query into tokens, requires every token to match somewhere in the record, folds typed words to the abbreviations the data uses (`street`→`st`, `drive`→`dr`, …), and ranks property-address hits first. |
| `property_phones` | One row per phone number, keyed to `BuyBox.id`. |
| RLS policies | Anyone with the link can **read** `BuyBox`/`Mailed` and **read+write** `property_phones`. `INSERT/UPDATE/DELETE` on `BuyBox`/`Mailed` are revoked from the public key. |

### `property_phones`

| Column | Notes |
| --- | --- |
| `property_id` | → `BuyBox.id` (on delete cascade) |
| `phone` | as entered / displayed |
| `phone_norm` | digits only, generated — unique per property, so the same number can't be added twice |
| `slot` | display order, 1–30 |
| `label` | optional: Mobile / Landline / … |
| `status` | `correct` \| `wrong` \| `dead` \| `NULL` |
| `note` | optional free text |
| `updated_by` | initials typed in the header (stored in the browser) |
| `created_at`, `updated_at` | `updated_at` maintained by trigger |

A trigger refuses the 31st number for a property.

> **Note on access:** the site is deliberately open — the anon key ships in `config.js`,
> so anyone with the page URL can read the property list and edit phone statuses.
> Adding Supabase email login later means swapping the policies from `anon` to
> `authenticated` in `sql/02_search_and_rls.sql`.
