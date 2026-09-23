# SOS Phones

A static site (GitHub Pages) for searching the `BuyBox` property list in Supabase and
tracking phone numbers per property.

- **Browse everything** by default: with nothing typed and nothing filtered, the home
  page lists all 285,947 records ordered by **list stack** — how many distinct distress
  reasons the record carries — heaviest first. The badge on each result is that number.
- **Paginated**, 15 per page, with first/prev/numbered/next/last. The page is in the URL
  (`?p=14`).
- **Search** by any part of a property address, owner name, mailing address or parcel number,
  with a dropdown to pick which field to search. The chosen field is kept in the URL
  (`?q=juniper&f=property`) so a search can be shared or reached with the back button.
- **Retractable left sidebar** with three sections: **Search**, **Mailing** and
  **Remove**. The « button collapses it to an icon rail; the choice is remembered per
  browser. One definition in `assets/nav.js`, mounted by every page.
- **Mailing** (`mailed.html`) lists every mailing, newest first, filtered by **Vendor**
  (DMForce / OLM), **Mail distress** (Stack, Tax Delinquent, Probate, …), a **date
  window**, and free text. All of it is in the URL
  (`?v=OLM&md=Probate&mf=2026-08-01`).
- **Filter by distress** on the home page: the reasons in `Lists` as toggle chips with
  counts. Picking several narrows to records carrying **all** of them, and it combines
  with the search box. The selection lives in the URL (`?d=probate|high+equity`).
- **Export CSV** of whatever is filtered — property fields plus each parcel's phone
  numbers flattened into `Phone 1`, `Phone 1 Type`, `Phone 1 Status`, … the same shape
  the importer reads.
- **Property page** shows the owner + address block, the `Lists` distresses, mail history,
  and up to **30 phone numbers**, each with a status: ✅ Correct · ❌ Wrong · 💀 Dead
  (no status = ○). Click a symbol to set it, click it again to clear it.

## A note on naming

Everything a person reads — the website, the uploaders, exported CSV headers, rejection
messages — says **Parcel Number**. The database column is still `"FOLIO"`, because
renaming it would break the bulk loads into `BuyBox` and every script that writes to it.
So `b."FOLIO"` in SQL and `Parcel Number` on screen are the same thing.

Upload files may head that column **either way**: `FOLIO`, `Folio`, `Parcel`,
`Parcel Number`, `parcel_number` and `APN` are all detected automatically.

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
| `list_stack()` | How many distinct distress reasons a record carries. Built on `distress_keys`, so `HIGH EQUITY` + `High equity` counts once. |
| `buybox_stack_idx` | `(list_stack("Lists") desc, id) INCLUDE ("Lists")`. The `INCLUDE` is what makes it an **index only** scan — without the underlying column in the index, a deep page costs a heap fetch per skipped row (offset 150k: 7.5s vs 0.8s). |
| `properties_where()` | Builds the filter as a SQL fragment. `search_properties()` and `count_properties()` both use it, so a page and its total can never disagree. |
| `count_properties()` | Exact total for the current filter, which is what paging needs. |
| `distress_norm()` / `distress_keys()` | Fold the `Lists` spellings to one key per reason (`HIGH EQUITY`/`High equity`/`High Equity` → `high equity`, `Tax Del` → `tax delinquent`). 30 raw values become 20 reasons. |
| `distress_vocab` | Materialised view of reason → label → count, read by `list_distresses()`. |
| `buybox_lists_gin` | GIN containment index over `distress_keys("Lists")`, so filtering by reason is a bitmap scan (~1ms) rather than a 286k-row scan. |
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

> ⚠️ `folio_norm()` and `distress_keys()` are used inside expression indexes. If you
> ever change either, **drop and recreate** the indexes built on them
> (`buybox_folio_idx`, `buybox_folio_county_idx`, `buybox_folio_trgm`, `mailed_folio_idx`,
> `buybox_lists_gin`) — Postgres does not rebuild them, and lookups will silently
> return nothing.

### After reloading BuyBox

The distress list and its counts are materialised, because computing them live is an
11-second scan. Once new data is loaded, refresh them:

```sql
select public.refresh_distress_vocab();
```

Until you do, the chips show the previous load's reasons and counts. Filtering, search
and everything else read BuyBox directly and are never stale.

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

## The Mailing view

`Type` packs three things into one string — `DM-OLM-Stack Aug26` is vendor `OLM`,
distress `Stack`, period `Aug26`. `mail_vendor()` and `mail_distress()` pull the first
two back out so they can be filtered on, folding the variants that reached the data:
`Foreclosure`/`Foreclosures` are one thing, so are `CodeVio`/`CodeioVio`, and `TaxDel`
reads as *Tax Delinquent*.

4,999 older rows are just a month (`Jun-26`) and carry neither. They are offered as
**(none)** in both pickers rather than hidden or guessed at.

| Vendor | | Mail distress | |
| --- | --- | --- | --- |
| OLM | 14,774 | Stack | 14,195 |
| DMForce | 11,902 | Tax Delinquent | 7,947 |
| (none) | 4,999 | (none) | 4,999 |
| | | Foreclosure | 1,379 |
| | | Probate | 1,371 |
| | | Evictions | 1,246 |
| | | Code Violations | 442 |
| | | Divorce | 74 |
| | | Syndicate | 22 |

## Setting a phone status by hand

The **Phone status** page of the Streamlit app takes an address (or parcel number) and a
phone number together:

- the number is already on that property → its status is changed
- it is not → it is added, carrying that status

Statuses are the same three the website uses: ✅ Correct, ❌ Wrong, 💀 Dead, or none.
City, Zip and County are there for the cases where an address or parcel number turns out
to belong to more than one property — the page says so rather than picking one.

The page shows every number already on the property before you save, so you can see what
you are changing.

## Mail dates

The mailing house reports the date each record actually went out.
`Mailed.mailed_on` holds it, with `mailed_src` noting where the date came from.
A `Mailed` row is one campaign for one parcel, so the date belongs on the row.

Upload them with the **Mail dates** page of the Streamlit app:

```bash
./run_upload.sh          # the sidebar lists both pages
```

The file needs a **Date** in `yyyy-mm-dd`, plus a **Parcel Number** or an **Address**.
An optional **Type** names the campaign. `samples/sample_mail_dates.csv` is an example.

What an uploaded (parcel, date) does, in order:

1. the parcel already has a row carrying that date → nothing to do
2. the parcel has a row with no date yet → fill it in, preferring a row whose `Type`
   matches when the file names a campaign
3. otherwise → add a row for the parcel, copying its details from BuyBox, or from its
   other `Mailed` rows if the parcel is no longer in BuyBox

Where one parcel gets several different dates, each claims its own undated row and any
beyond that are added as new rows — they must not all be pointed at the same row, which
would silently keep only one of the dates.

## Settings — removing records from BuyBox

`settings.html` has a **Remove from BuyBox** bar. Pick one field to match on — Parcel
Number, Address or Property zip — enter a value, and a confirmation shows **how many records
match** before anything moves.

Nothing is deleted. Matching records move to **`notBuyBox`**, which carries every
BuyBox column plus `removed_at`, `removed_by`, `removed_match_field` and
`removed_match_value`. The page lists recent removals with a **Restore** button that
puts a batch back under its original ids. **Phone numbers are kept** — they are keyed
on the parcel and are worth holding on to if the record returns.

> ⚠️ **This page has no login, by choice.** Anyone with the site URL can move records
> out of BuyBox. A single zip is a big lever: `30906` alone is 26,054 records. Two
> things limit the damage — removals are reversible from the same page, and the public
> key still has no direct write access to BuyBox. `remove_from_buybox()` and
> `restore_to_buybox()` are `SECURITY DEFINER` with a pinned `search_path`, so the only
> route out of BuyBox is the one that archives. To close the page off later, drop the
> `grant execute ... to anon` lines at the bottom of `sql/04_removal.sql`.

Matching uses the same normalisation as the rest of the site: `F# 077G222` and
`077g222` are one parcel, `308 Cedar Rock Meadows` and `308 CEDAR ROCK MDWS` are one
address. An address shared by several parcels removes all of them — the count says so
before you confirm.

## Exporting

The Export button pages through `export_properties()` 1,000 rows at a time and builds
the CSV in the browser, so it is capped at **50,000 records**. The button shows what
will actually come out — `Export 50,000` with a tooltip when more match — and the big
reasons (`Individual`, `HIGH EQUITY`, `ABSENTEE`, `0$ Transfers`) are over the cap on
their own, so narrow them with a second reason or a search term first.

## Paging cost

Ordering is served by an index, so page depth costs little: page 1 and page 200 are
~220ms, page 10,000 ~990ms, the last page (19,063) ~1.8s. Filtered sets are small
enough that every page of them is fast.

## Uploading phone numbers by address (Streamlit)

When the file has an **address** instead of a FOLIO:

```bash
pip install -r requirements.txt
./run_upload.sh                      # or: python3 -m streamlit run streamlit_app.py
```

> ⚠️ There are two Streamlit installs on this machine — the `streamlit` command on
> PATH is Python 3.11's (1.41.1) and `python3 -m streamlit` is 3.12's (1.62.0). Stick to
> arguments that work in both. `use_container_width=` does; `width=` is newer and raises
> `TypeError: button() got an unexpected keyword argument 'width'` under 1.41, even
> though 1.62 prints a deprecation warning telling you to switch to it.

The app has three pages, listed in its sidebar:

| Page | What it does |
| --- | --- |
| Upload phone numbers | bulk load numbers against parcel numbers or addresses |
| Mail dates | record when each record was mailed |
| Phone status | set one number's status on one property, adding it if absent |

Credentials come from `.streamlit/secrets.toml`, which is git-ignored — copy
`.streamlit/secrets.toml.example` and fill in the password, and the sidebar fills
itself in. There is a **Test connection** button there to confirm it before uploading.
`samples/sample_upload.csv` is a working example file (real parcels, fake 555 numbers).

The uploader is split in two: `phone_import.py` holds the pipeline and imports no
Streamlit, so it can be run and tested headlessly; `streamlit_app.py` is only the
interface over it.

Upload a CSV/XLSX with **Phone**, plus either a **Parcel Number** or an **Address**. A mix is
fine: any row that carries a parcel number uses it directly and skips the address lookup, and
only the rest are resolved against BuyBox. **Phone Type**, **City**, **Zip** and
**County** are optional; the last three only matter for keys that are ambiguous.

**Use the parcel number when you have it.** On a 4,000-row sample of real BuyBox rows,
matching by parcel number resolved 99.9% and matching by address resolved 83% — the rest of the addresses
belong to more than one parcel.

"Check without importing" runs the whole thing in a transaction and rolls back, so you
see the counts first. Rejected rows are listed with a reason and downloadable as CSV.

### How addresses are matched

`addr_norm()` folds case, punctuation and street words, so `2451 Juniper Drive`,
`2451 JUNIPER DR` and `308 Cedar Rock Meadows` / `308 CEDAR ROCK MDWS` all match. The
word list lives once in `fold_street_words()` and the search box uses the same one.

**92% of distinct addresses resolve to exactly one parcel** (81% of rows). The other
19,483 addresses — 53,193 rows — belong to several; `PINE ST` alone covers 106 parcels,
mostly unnumbered lots. Those rows are **rejected, not guessed**, because attaching a
phone number to the wrong parcel is worse than not attaching it.

City, Zip and County narrow them: `PINE ST` is ambiguous, `PINE ST` + `Aiken` + `29801`
is not. The same applies to a FOLIO — 139 parcel numbers are shared across counties, so
`F# 0310002020` alone is ambiguous while `F# 0310002020` + county `Aiken` is not.

A row whose key is known but whose City/Zip/County contradicts BuyBox is reported as
such, separately from a key that simply is not there — the two mean different things.

Throughput is about **1ms per row** (4,000 rows in ~4s); both lookups are index scans.

Database credentials come from `.streamlit/secrets.toml` (git-ignored — see
`secrets.toml.example`) or environment variables, and can be typed into the sidebar.
This app connects as the database owner, not through the public key.

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
