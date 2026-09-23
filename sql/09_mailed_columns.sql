-- SOS Phones : vendor / distress / month / year as columns of their own.
-- Safe to re-run.
--
-- "Type" packed all four into one string ('DM-OLM-Stack Aug26') and everything
-- had to unpick it. They are columns now. Type is kept and still read as a
-- fallback, so a row that only carries it is not lost.
begin;

alter table public."Mailed"
  add column if not exists "Vendor"   text,
  add column if not exists "Distress" text,
  add column if not exists "Month"    text,
  add column if not exists "Year"     text;

-- ---------------------------------------------------------------
-- Month and Year arrive however the file writes them: Sep, September,
-- 9, 09 / 26, 2026. These give one number to sort and filter on.
-- ---------------------------------------------------------------
create or replace function public.month_num(m text) returns int
language sql immutable parallel safe as
$$ select case lower(btrim(coalesce(m, '')))
            when 'jan' then 1  when 'january'   then 1  when '1' then 1  when '01' then 1
            when 'feb' then 2  when 'february'  then 2  when '2' then 2  when '02' then 2
            when 'mar' then 3  when 'march'     then 3  when '3' then 3  when '03' then 3
            when 'apr' then 4  when 'april'     then 4  when '4' then 4  when '04' then 4
            when 'may' then 5                           when '5' then 5  when '05' then 5
            when 'jun' then 6  when 'june'      then 6  when '6' then 6  when '06' then 6
            when 'jul' then 7  when 'july'      then 7  when '7' then 7  when '07' then 7
            when 'aug' then 8  when 'august'    then 8  when '8' then 8  when '08' then 8
            when 'sep' then 9  when 'september' then 9  when '9' then 9  when '09' then 9
                               when 'sept'      then 9
            when 'oct' then 10 when 'october'   then 10 when '10' then 10
            when 'nov' then 11 when 'november'  then 11 when '11' then 11
            when 'dec' then 12 when 'december'  then 12 when '12' then 12
          end $$;

-- '26' and '2026' are the same year; anything else is left alone
create or replace function public.year_num(y text) returns int
language sql immutable parallel safe as
$$ select case
            when btrim(coalesce(y,'')) ~ '^\d{4}$' then btrim(y)::int
            when btrim(coalesce(y,'')) ~ '^\d{2}$' then 2000 + btrim(y)::int
          end $$;

-- ---------------------------------------------------------------
-- What the rest of the system reads. The column wins; Type is unpicked
-- only when the column is empty, so old-shaped rows still work.
-- ---------------------------------------------------------------
create or replace function public.mailed_vendor_of(p_vendor text, p_type text) returns text
language sql immutable parallel safe as
$$ select coalesce(nullif(btrim(coalesce(p_vendor,'')), ''), public.mail_vendor(p_type)) $$;

create or replace function public.mailed_distress_of(p_distress text, p_type text) returns text
language sql immutable parallel safe as
$$ select coalesce(nullif(btrim(coalesce(p_distress,'')), ''), public.mail_distress(p_type)) $$;

create index if not exists mailed_vendor_col_idx
  on public."Mailed" (public.mailed_vendor_of("Vendor", "Type"));
create index if not exists mailed_distress_col_idx
  on public."Mailed" (public.mailed_distress_of("Distress", "Type"));
create index if not exists mailed_period_idx
  on public."Mailed" (public.year_num("Year"), public.month_num("Month"));

grant execute on function public.month_num(text)                     to anon, authenticated;
grant execute on function public.year_num(text)                      to anon, authenticated;
grant execute on function public.mailed_vendor_of(text, text)        to anon, authenticated;
grant execute on function public.mailed_distress_of(text, text)      to anon, authenticated;

commit;
