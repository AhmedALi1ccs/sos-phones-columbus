# SOS Phones — Columbus

A static site (GitHub Pages) for searching the `Buybox` property list in Supabase and
tracking phone numbers per property. 418,508 records across Franklin, Licking and
Fairfield counties, Ohio.

- **Browse everything** by default: with nothing typed and nothing filtered, the home
  page lists every record ordered by **list stack** — how many distinct distress reasons
  the record carries — heaviest first. The badge on each result is that number.
- **Paginated**, 15 per page, with first/prev/numbered/next/last. The page is in the URL
  (`?p=14`).
- **Search** by any part of a property address, owner name, mailing address or parcel
  number, with a dropdown to pick which field to search. The chosen field is kept in the
  URL (`?q=summit&f=property`) so a search can be shared or reached with the back button.
- **Filter by distress** on the home page: the reasons in `Lists` as toggle chips with
  counts. Picking several narrows to records carrying **all** of them, and it combines
  with the search box. The selection lives in the URL (`?d=probate|vacant`).
- **Export CSV** of whatever is filtered — property fields plus each parcel's phone
  numbers flattened into `Phone 1`, `Phone 1 Type`, `Phone 1 Status`, … the same shape
  the importer reads.
- **Retractable left sidebar** with five sections: **Search**, **Mailing**,
  **Cold calling**, **SMS** and **Remove**. The « button collapses it to an icon rail;
  the choice is remembered per browser. One definition in `assets/nav.js`.
- **Mailing** (`mailed.html`) lists the `Mail` table, newest first, filtered by
  **campaign** (`Tag`), **month** and free text (`?t=7%2BTPH&mo=2026-07-01`).
- **SMS** (`sms.html`) lists the `SMS` table the same way, filtered by **approach** and
  **month** (`?a=fishnet&mo=2026-08-01`).
- **Cold calling** (`coldcalling.html`) lists numbers gathered for calling, by source.
- **Property page** shows owner, property and mailing address, appraised value and sale,
  the `Lists` distresses and `Tags` history, a chip per mailing and per text, the cold
  calling numbers, and up to **30 phone numbers**, each with a status: ✅ Correct ·
  ❌ Wrong · 💀 Dead (no status = ○). Click a symbol to set it, click it again to clear it.

## Setup

1. **Run the SQL** (once, in order) against the Supabase database. Use the session pooler
   (port 5432) — the index builds take a minute or two:

   ```bash
   export PGPASSWORD='...'
   psql -h aws-0-eu-west-3.pooler.supabase.com -p 5432 \
        -U postgres.okojvwzrdtcvglaujxau -d postgres -c "set statement_timeout=0" \
        -f sql/01_schema.sql -f sql/02_search.sql -f sql/03_mail.sql -f sql/04_sms.sql \
        -f sql/05_cold_calling.sql -f sql/06_removal.sql -f sql/07_access.sql
   ```

   Every file is safe to re-run. **This has already been done** for the live database.

2. **The publishable key** is in `config.js`
   (Supabase → Project Settings → API → `sb_publishable_…`). Never put the secret key there.

3. **Publish**: push to GitHub; Pages serves `main` / root.

## Local preview

```bash
python3 -m http.server 8080
# open http://localhost:8080
```

## The tables

| Table | Who writes it | Notes |
| --- | --- | --- |
| `Buybox` | you, loaded directly | Primary key `"Parcel Number"`. Read-only to the website. |
| `Mail` | you, loaded directly | One row per mailed parcel. `"Date"` is text like `Jul-26`. Read-only to the website. |
| `SMS` | you, loaded directly | One row per text: `Month`, `Year`, `Approach`. Carries no phone numbers. Read-only to the website. |
| `property_phones` | the website and the uploaders | Phone numbers and their statuses, keyed by parcel. |
| `ColdCalling` | the uploader | Address, number, source; linked to a parcel when the address matches one. |
| `notBuybox` | the Remove page | Records moved out of `Buybox`, kept so they can be put back. |

None of the SQL alters `Buybox`, `Mail` or `SMS`: everything on them is an expression
index, so your loads keep working unchanged.

> ⚠️ `Mail` has its primary key on `"Parcel Number"`, so it can hold **one mailing per
> parcel**. Mailing the same parcel in a second campaign will be refused by the database
> until that key is widened (e.g. to `("Parcel Number", "Tag", "Date")`).

### How things are compared

- **Parcel numbers** are compared by `parcel_norm()`: punctuation stripped and
  case-folded, so `010-000001-00`, `01000000100` and `010 000001 00` are one parcel.
  `assets/db.js` has a matching `parcelKey()` — change one and you must change the other.
  `Parcel Number` is unique in `Buybox`, so it alone identifies a property; phone numbers
  are keyed on it rather than on any row id.
- **Addresses** are compared by `addr_norm()`, which folds case, punctuation and street
  words (`street`→`st`, `avenue`→`ave`, …) from the one list in `fold_street_words()`.
  `1570 Franklin Avenue` and `1570 FRANKLIN AVE` match.
- **The search box** matches each typed word **as typed or as its abbreviation**. This
  data abbreviates suffixes (`st`, `ave`, `dr`) but spells out street *names* (`summit`,
  `creek`, `ridge`), so folding `summit`→`smt` alone would miss 765 records on Summit St.
  `search_words()` + `word_like()` build that match; Mailing, SMS and Cold calling use
  them too.
- **Distress reasons** are folded by `distress_keys()` (`HIGH EQUITY`/`High equity` →
  `high equity`, `Tax Del` → `tax delinquent`).
- **Months**: `mail_period()` reads `Mail."Date"` (`Jul-26`, `July 2026`, `2026-07-15`,
  `07/15/2026`, `7/2026`) as the first of that month; `period_of(Month, Year)` does the
  same for `SMS`. A date it cannot read is counted on the page rather than hidden.
- **SMS approach** is compared case-insensitively, so `Ghost` and `ghost` are one choice.

> ⚠️ `parcel_norm()`, `distress_keys()`, `list_stack()` and `addr_norm()` are used inside
> expression indexes. If you ever change one, **rebuild the indexes on it**
> (`reindex table public."Buybox"`) — Postgres does not, and lookups will silently return
> nothing.

## Speed, and the 3-second limit

Supabase gives the public key a **3 s statement timeout**. Everything the site does is
measured under it, as the `anon` role, at 418k rows:

| | |
| --- | --- |
| Browse, any page (incl. the last) | 0.1–0.2 s |
| Search, e.g. `summit st`, `smith` | 0.1–0.3 s |
| Distress filter count, e.g. Absentee (158k) | ~0.4 s |
| Mailing / SMS page | 0.1–0.6 s; SMS's approach picker ~1.2 s (it counts all 105k texts) |
| Export, per 1,000 rows | 0.3–1.3 s |
| Remove a zip of 3,424 records | ~0.15 s |

Things worth knowing:

- **`distress_keys()` is PL/pgSQL on purpose.** As a SQL function with an aggregate it
  can't be inlined, so Postgres re-planned it on every row (~29 µs); sorting 240k search
  matches by stack took 7 s. The PL/pgSQL version is ~4 µs.
- **A broad search is sorted by stack, not by relevance.** Ranking evaluates every match;
  `columbus` matches 240k records, which is ~6 s. Past 10,000 matches the page walks the
  stack index instead and says so ("too many matches to rank — add a word"). Deep pages of
  such a search get slower: page 4,000 of `columbus` takes ~2 s, and past the limit the
  page says it is too deep and asks for a narrower search.
- **Why the search functions are `SECURITY DEFINER`.** With row-level security on,
  Postgres won't use table statistics to estimate a `LIKE` for the `anon` role, so it
  guessed "42 rows" for `columbus` and picked a plan that sorted all 240k. Running as the
  owner gives it the real numbers. They only read tables the public key can already read,
  and every user value is quoted with `%L`.
- **Restoring is chunked.** Inserting into `Buybox` costs ~1.5 ms a row, almost all of it
  the trigram search index, so `restore_to_buybox()` puts back 500 per call and the page
  loops. (Removal deletes, which costs indexes nothing.)

### Loading into Buybox

The same index makes bulk loads slower — about **1.5 ms a row**, so a full reload of 418k
rows is ~10 minutes. Load in batches, or for a full reload drop the search index first
and rebuild it after (~1 minute):

```sql
drop index public.buybox_search_trgm;
-- ... load ...
-- then re-run sql/01_schema.sql, which recreates it
```

### After loading into Buybox — refresh the distress counts

The distress chips and their counts are materialised (computing them live is a scan of
every row). After new data lands:

```sql
select public.refresh_distress_vocab();
```

**Until you do, the chip numbers are wrong and a new reason will not appear at all.** The
page prints *"counts as of …"* beside the filter heading, and says to refresh once they
are over a day old. Filtering itself is always live — only the label is cached. The
website cannot run the refresh; it is for whoever loads Buybox.

## Remove — taking records out of Buybox

`settings.html` has a **Remove from Buybox** bar. Pick one field to match on — Parcel
Number, Address or Property zip — enter a value, and a confirmation shows **how many
records match** before anything moves.

Nothing is deleted. Matching records move to **`notBuybox`**, which carries every Buybox
column plus `removed_at`, `removed_by`, `removed_match_field` and `removed_match_value`.
The page lists recent removals with a **Restore** button that puts a batch back. A parcel
that has been loaded into Buybox again in the meantime stays in the archive rather than
clashing with it. **Phone numbers are kept** — they are keyed on the parcel.

> ⚠️ **This page has no login, by choice.** Anyone with the site URL can move records out
> of Buybox. Removals are reversible from the same page, and the public key has no direct
> write access to Buybox: `remove_from_buybox()` and `restore_to_buybox()` are
> `SECURITY DEFINER` with a pinned `search_path`, so the only route out of Buybox is the
> one that archives. To close the page off, drop their `grant execute ... to anon` lines
> in `sql/07_access.sql`.

## Exporting

The Export button pages through `export_properties()` 1,000 rows at a time and builds the
CSV in the browser, so it is capped at **50,000 records**. The button shows what will
actually come out — `Export 50,000` with a tooltip when more match.

## Uploading (Streamlit)

```bash
pip install -r requirements.txt
./run_upload.sh                      # or: python3 -m streamlit run streamlit_app.py
```

Credentials come from `.streamlit/secrets.toml`, which is git-ignored — copy
`.streamlit/secrets.toml.example` and fill in the password. There is a **Test connection**
button in the sidebar. The app connects as the database owner, not through the public key.

| Page | What it does |
| --- | --- |
| Upload phone numbers | bulk load numbers against parcel numbers or addresses |
| Phone status | bulk-apply statuses from a file, or set one by hand |
| Cold calling | load a calling list: address, number, source |

`Buybox`, `Mail` and `SMS` are loaded straight into Supabase, so there is no page for them.

Upload a CSV/XLSX with **Phone**, plus either a **Parcel Number** or an **Address**. A mix
is fine: a row with a parcel number uses it directly and skips the address lookup.
**Phone Type**, **City** and **Zip** are optional; City and Zip only matter for an address
that belongs to several parcels (`603 olde towne ave` is 10 condos). Those rows are
**rejected, not guessed**, because a number on the wrong parcel is worse than none.

"Check without importing" runs the whole thing in a transaction and rolls back, so you see
the counts first. Rejected rows are listed with a reason and downloadable as CSV. The
`samples/` files are working examples (real parcels, fake 555 numbers) that exercise each
kind of rejection.

The pipelines live in `phone_import.py`, `contact_import.py` and `status_update.py`, which
import no Streamlit and can be run headlessly; the `streamlit_app.py` and `pages/` files
are only the interface over them.

> ⚠️ There are two Streamlit installs on this machine — the `streamlit` command on PATH is
> Python 3.11's (1.41.1) and `python3 -m streamlit` is 3.12's (1.62.0). Stick to arguments
> that work in both: `use_container_width=` does; `width=` raises under 1.41.

## Importing phone numbers from the command line

Long format, one row per phone:

```csv
Parcel Number,Phone,Phone Type
010-000001-00,6145551000,Mobile
010-000001-00,6145551001,Residential
```

Wide format (`Phone 1`, `Phone 1 Type`, … `Phone 30`) works too.

```bash
python3 scripts/import_phones.py Book1.csv           # dry run, writes nothing
python3 scripts/import_phones.py Book1.csv --apply   # commit
```

It **defaults to a dry run**. Anything it cannot place — parcel missing or not in Buybox,
malformed number, over the 30 cap — goes to `<file>_rejects.csv` with a reason. Numbers
already in the table are skipped, so re-running a file is safe. `--fill-type` back-fills
`phone_type` on rows that are already there but have none. Phone Type wording is mapped:
`Mobile`/`Wireless`/`Cell` → `mobile`, `Residential`/`Landline`/`Home` → `landline`.

## `property_phones`

| Column | Notes |
| --- | --- |
| `parcel` | as stored in Buybox, e.g. `010-000001-00` |
| `parcel_key` | normalised, generated — what lookups and the unique index use |
| `phone` | as entered / displayed |
| `phone_norm` | 10 digits, generated — unique per parcel, so a number can't be added twice |
| `slot` | display order, 1–30 |
| `phone_type` | `landline` \| `mobile` \| `NULL` — shown as ☎️ / 📱 |
| `status` | `correct` \| `wrong` \| `dead` \| `NULL` |
| `note` | optional free text |
| `updated_by` | initials typed in the header (stored in the browser) |
| `created_at`, `updated_at` | `updated_at` maintained by trigger |

A trigger refuses the 31st number for a parcel.

> **Note on access:** the site is deliberately open — the publishable key ships in
> `config.js`, so anyone with the page URL can read the property list and edit phone
> statuses. Adding Supabase login later means swapping the policies from `anon` to
> `authenticated` in `sql/07_access.sql`.
