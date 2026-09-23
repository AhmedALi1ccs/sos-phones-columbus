-- SOS Phones : one Date column on Mailed.  Safe to re-run.
--
-- Replaces Month + Year with a single Date, and drops the columns that existed
-- only to unpick the old packed Type string, or to record a mail date arriving
-- separately from the rows themselves.
--
-- Date is a real date, not text: the page offers a from/to range and orders
-- newest first, which text cannot do. Postgres reads YYYY-MM-DD and, with this
-- database's ISO/MDY setting, MM/DD/YYYY as well.
begin;

alter table public."Mailed"
  add column if not exists "Date" date;

alter table public."Mailed"
  drop column if exists "Month",
  drop column if exists "Year",
  drop column if exists "Type",
  drop column if exists mailed_on,
  drop column if exists mailed_src;

create index if not exists mailed_date_col_idx on public."Mailed" ("Date");
create index if not exists mailed_vendor_only_idx on public."Mailed" (btrim("Vendor"));
create index if not exists mailed_distress_only_idx on public."Mailed" (btrim("Distress"));

-- these existed only to read the old packed string or the split Month/Year
drop function if exists public.mailed_vendor_of(text, text);
drop function if exists public.mailed_distress_of(text, text);
drop function if exists public.mail_vendor(text);
drop function if exists public.mail_distress(text);
drop function if exists public.month_num(text);
drop function if exists public.year_num(text);

commit;
