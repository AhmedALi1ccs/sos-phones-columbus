-- SOS Phones : the Mailing view, over the Mail table.  Safe to re-run.
--
-- Mail is loaded straight into Supabase, so this only reads it: nothing here
-- alters the table. "Date" is text such as 'Jul-26'; mail_period() turns it
-- into the first day of that month so the page can sort and filter on it.
begin;

-- ---------------------------------------------------------------
-- Month and year arrive however the file writes them: Jul, July, 7, 07 /
-- 26, 2026. These give one number to sort and filter on.
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

-- a month and a year, as the first day of that month; NULL when either is unreadable
create or replace function public.period_of(m text, y text) returns date
language sql immutable parallel safe as
$$ select case when public.month_num(m) is not null and public.year_num(y) is not null
               then make_date(public.year_num(y), public.month_num(m), 1) end $$;

-- 'Jul-26', 'July 2026', '2026-07-15', '07/15/2026', '7/2026' -> 2026-07-01
--
-- One expression with no FROM, repeating btrim(d), on purpose: that lets
-- Postgres inline it. Written with a sub-select it is re-planned on every
-- call, which cost ~270us a row.
create or replace function public.mail_period(d text) returns date
language sql immutable parallel safe as
$$ select case
            when btrim(d) ~ '^\d{4}-\d{1,2}(-\d{1,2})?$'
              then public.period_of(split_part(btrim(d), '-', 2), split_part(btrim(d), '-', 1))
            when btrim(d) ~ '^\d{1,2}/\d{1,2}/\d{2,4}$'
              then public.period_of(split_part(btrim(d), '/', 1), split_part(btrim(d), '/', 3))
            when btrim(d) ~ '^\d{1,2}/\d{4}$'
              then public.period_of(split_part(btrim(d), '/', 1), split_part(btrim(d), '/', 2))
            when btrim(d) ~ '^[A-Za-z]+[\s\-/.,]+\d{2,4}$'
              then public.period_of(substring(btrim(d) from '^[A-Za-z]+'), substring(btrim(d) from '\d{2,4}$'))
          end $$;

-- ---------------------------------------------------------------
-- What the pickers offer, with counts.  '(none)' means rows with no tag.
-- ---------------------------------------------------------------
drop function if exists public.list_mail_tags();
create function public.list_mail_tags()
returns table (tag text, n bigint)
language sql stable as $$
  select coalesce(nullif(btrim("Tag"), ''), '(none)'), count(*)
  from public."Mail" group by 1 order by 2 desc;
$$;

drop function if exists public.list_mail_periods();
create function public.list_mail_periods()
returns table (period date, n bigint)
language sql stable as $$
  select public.mail_period("Date"), count(*)
  from public."Mail" group by 1 order by 1 desc nulls last;
$$;

-- ---------------------------------------------------------------
-- One filter, used by both the page and its total.
-- ---------------------------------------------------------------
drop function if exists public.mail_where(text, text, date);
create function public.mail_where(
  q        text default null,
  p_tag    text default null,
  p_period date default null
)
returns text
language plpgsql
immutable
as $fn$
declare
  w text := '';
  t text;
begin
  if coalesce(btrim(p_tag), '') <> '' then
    w := w || case when p_tag = '(none)'
                   then ' and coalesce(btrim(m."Tag"), '''') = '''''
                   else format(' and btrim(m."Tag") = %L', btrim(p_tag)) end;
  end if;

  if p_period is not null then
    w := w || format(' and public.mail_period(m."Date") = %L::date', p_period);
  end if;

  foreach t in array public.search_words(q) loop
    w := w || ' and ' || public.word_like(
      'lower(coalesce(m."Parcel Number",'''')||'' ''||coalesce(m."Full Name",'''')||'' ''||'
      'coalesce(m."Property address",'''')||'' ''||coalesce(m."Property city",'''')||'' ''||'
      'coalesce(m."Property zip",'''')||'' ''||coalesce(m."Tag",''''))', t);
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- One page of the Mailing list, and its exact size.
-- ---------------------------------------------------------------
drop function if exists public.search_mail(text, text, date, int, int);
create function public.search_mail(
  q        text default null,
  p_tag    text default null,
  p_period date default null,
  max_rows int  default 15,
  skip     int  default 0
)
returns table (
  parcel           text,
  full_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  tag              text,
  check_value      text,
  mail_date        text,
  period           date,
  in_buybox        boolean
)
language plpgsql
stable
-- runs as the owner: see "Why the search functions are SECURITY DEFINER" in README
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  return query execute format($q$
    select m."Parcel Number", m."Full Name",
           m."Property address", m."Property city", m."Property state", m."Property zip",
           nullif(btrim(m."Tag"), ''), nullif(btrim(m."Check Value"), ''),
           nullif(btrim(m."Date"), ''), public.mail_period(m."Date"),
           exists (select 1 from public."Buybox" b where b."Parcel Number" = m."Parcel Number")
    from public."Mail" m
    where true %s
    order by public.mail_period(m."Date") desc nulls last, m."Property address" nulls last, m."Parcel Number"
    limit %s offset %s
  $q$,
  public.mail_where(q, p_tag, p_period),
  greatest(1, least(coalesce(max_rows, 15), 5000)),
  greatest(0, coalesce(skip, 0)));
end
$fn$;

drop function if exists public.count_mail(text, text, date);
create function public.count_mail(
  q        text default null,
  p_tag    text default null,
  p_period date default null
)
returns bigint
language plpgsql
stable
-- runs as the owner: see "Why the search functions are SECURITY DEFINER" in README
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare n bigint;
begin
  execute format('select count(*) from public."Mail" m where true %s',
                 public.mail_where(q, p_tag, p_period)) into n;
  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- get_mail_history(parcel) : the property page's mail panel.
-- ---------------------------------------------------------------
drop function if exists public.get_mail_history(text);
create function public.get_mail_history(p_parcel text)
returns table (tag text, check_value text, mail_date text, period date)
language sql
stable
as $$
  select nullif(btrim(m."Tag"), ''), nullif(btrim(m."Check Value"), ''),
         nullif(btrim(m."Date"), ''), public.mail_period(m."Date")
  from public."Mail" m
  where public.parcel_norm(m."Parcel Number") = public.parcel_norm(p_parcel)
  order by public.mail_period(m."Date") desc nulls last
  limit 20;
$$;

commit;
