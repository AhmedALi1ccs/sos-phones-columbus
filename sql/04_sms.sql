-- SOS Phones : the SMS view, over the SMS table.  Safe to re-run.
--
-- SMS is loaded straight into Supabase and is a log of who was texted, when
-- (Month + Year) and how (Approach). It carries no phone numbers. Nothing here
-- alters the table.
--
-- Approach arrives in more than one case ('Ghost' / 'ghost'), so it is
-- compared on lower(btrim(...)) and shown in its most common spelling.
begin;

create index if not exists sms_approach_idx on public."SMS" (lower(btrim("Approach")));
create index if not exists sms_period_idx   on public."SMS" (public.period_of("Month", "Year"));

-- ---------------------------------------------------------------
-- What the pickers offer, with counts.  '(none)' means rows with no approach.
-- ---------------------------------------------------------------
drop function if exists public.list_sms_approaches();
create function public.list_sms_approaches()
returns table (approach text, label text, n bigint)
language sql stable as $$
  select coalesce(nullif(lower(btrim("Approach")), ''), '(none)'),
         coalesce(mode() within group (order by nullif(btrim("Approach"), '')), '(none)'),
         count(*)
  from public."SMS" group by 1 order by 3 desc;
$$;

drop function if exists public.list_sms_periods();
create function public.list_sms_periods()
returns table (period date, n bigint)
language sql stable as $$
  select public.period_of("Month", "Year"), count(*)
  from public."SMS" group by 1 order by 1 desc nulls last;
$$;

-- ---------------------------------------------------------------
-- One filter, used by both the page and its total.
-- p_approach is the folded key list_sms_approaches() hands out.
-- ---------------------------------------------------------------
drop function if exists public.sms_where(text, text, date);
create function public.sms_where(
  q          text default null,
  p_approach text default null,
  p_period   date default null
)
returns text
language plpgsql
immutable
as $fn$
declare
  w text := '';
  t text;
begin
  if coalesce(btrim(p_approach), '') <> '' then
    w := w || case when p_approach = '(none)'
                   then ' and coalesce(lower(btrim(s."Approach")), '''') = '''''
                   else format(' and lower(btrim(s."Approach")) = %L', lower(btrim(p_approach))) end;
  end if;

  if p_period is not null then
    w := w || format(' and public.period_of(s."Month", s."Year") = %L::date', p_period);
  end if;

  foreach t in array public.search_words(q) loop
    w := w || ' and ' || public.word_like(
      'lower(coalesce(s."parcel number",'''')||'' ''||coalesce(s."Full Name",'''')||'' ''||'
      'coalesce(s."Property address",'''')||'' ''||coalesce(s."Property city",'''')||'' ''||'
      'coalesce(s."Property zip",'''')||'' ''||coalesce(s."Approach",''''))', t);
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- One page of the SMS list, and its exact size.
-- ---------------------------------------------------------------
drop function if exists public.search_sms(text, text, date, int, int);
create function public.search_sms(
  q          text default null,
  p_approach text default null,
  p_period   date default null,
  max_rows   int  default 15,
  skip       int  default 0
)
returns table (
  parcel           text,
  full_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  approach         text,
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
  -- rows first, then the Buybox check for just this page
  return query execute format($q$
    with page as (
      select s.ctid as rid
      from public."SMS" s
      where true %s
      order by public.period_of(s."Month", s."Year") desc nulls last,
               s."Property address" nulls last, s."parcel number", s.ctid
      limit %s offset %s
    )
    select s."parcel number", s."Full Name",
           s."Property address", s."Property city", s."Property state", s."Property zip",
           nullif(btrim(s."Approach"), ''), public.period_of(s."Month", s."Year"),
           exists (select 1 from public."Buybox" b where b."Parcel Number" = s."parcel number")
    from public."SMS" s
    join page on page.rid = s.ctid
    order by public.period_of(s."Month", s."Year") desc nulls last,
             s."Property address" nulls last, s."parcel number", s.ctid
  $q$,
  public.sms_where(q, p_approach, p_period),
  greatest(1, least(coalesce(max_rows, 15), 5000)),
  greatest(0, coalesce(skip, 0)));
end
$fn$;

drop function if exists public.count_sms(text, text, date);
create function public.count_sms(
  q          text default null,
  p_approach text default null,
  p_period   date default null
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
  execute format('select count(*) from public."SMS" s where true %s',
                 public.sms_where(q, p_approach, p_period)) into n;
  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- get_sms_history(parcel) : the property page's SMS panel.
-- ---------------------------------------------------------------
drop function if exists public.get_sms_history(text);
create function public.get_sms_history(p_parcel text)
returns table (approach text, period date, month text, year text)
language sql
stable
as $$
  select nullif(btrim(s."Approach"), ''), public.period_of(s."Month", s."Year"),
         nullif(btrim(s."Month"), ''), nullif(btrim(s."Year"), '')
  from public."SMS" s
  where public.parcel_norm(s."parcel number") = public.parcel_norm(p_parcel)
  order by public.period_of(s."Month", s."Year") desc nulls last
  limit 20;
$$;

commit;
