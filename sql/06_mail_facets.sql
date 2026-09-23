-- SOS Phones : the Mailing view.  Safe to re-run.
--
-- Mailed carries Vendor, Distress and Date as columns of their own, so nothing
-- here has to unpick a packed string any more.
begin;

-- ---------------------------------------------------------------
-- What the pickers offer, with counts.
-- ---------------------------------------------------------------
drop function if exists public.list_mail_vendors();
create function public.list_mail_vendors()
returns table (vendor text, n bigint)
language sql stable as $$
  select coalesce(nullif(btrim("Vendor"), ''), '(none)'), count(*)
  from public."Mailed" group by 1 order by 2 desc;
$$;

drop function if exists public.list_mail_distresses();
create function public.list_mail_distresses()
returns table (distress text, n bigint)
language sql stable as $$
  select coalesce(nullif(btrim("Distress"), ''), '(none)'), count(*)
  from public."Mailed" group by 1 order by 2 desc;
$$;

-- the month picker, built from the dates actually present
drop function if exists public.list_mail_periods();
create function public.list_mail_periods()
returns table (period date, n bigint)
language sql stable as $$
  select date_trunc('month', "Date")::date, count(*)
  from public."Mailed" where "Date" is not null
  group by 1 order by 1 desc;
$$;

drop function if exists public.mail_date_bounds();
create function public.mail_date_bounds()
returns table (first_mailed date, last_mailed date, n_dated bigint, n_undated bigint)
language sql stable as $$
  select min("Date"), max("Date"),
         count(*) filter (where "Date" is not null),
         count(*) filter (where "Date" is null)
  from public."Mailed";
$$;

-- ---------------------------------------------------------------
-- One filter, used by both the page and its total.
-- '(none)' means rows that carry no vendor / no distress.
-- ---------------------------------------------------------------
drop function if exists public.mailed_where(text, text, text, date, date);
drop function if exists public.mailed_where(text, text, text, date, date, int, int);
create function public.mailed_where(
  q             text default null,
  p_vendor      text default null,
  p_distress    text default null,
  p_mailed_from date default null,
  p_mailed_to   date default null
)
returns text
language plpgsql
immutable
as $fn$
declare
  w text := '';
  t text;
begin
  if coalesce(btrim(p_vendor), '') <> '' then
    w := w || case when p_vendor = '(none)'
                   then ' and coalesce(btrim(m."Vendor"), '''') = '''''
                   else format(' and btrim(m."Vendor") = %L', btrim(p_vendor)) end;
  end if;

  if coalesce(btrim(p_distress), '') <> '' then
    w := w || case when p_distress = '(none)'
                   then ' and coalesce(btrim(m."Distress"), '''') = '''''
                   else format(' and btrim(m."Distress") = %L', btrim(p_distress)) end;
  end if;

  if p_mailed_from is not null then
    w := w || format(' and m."Date" >= %L::date', p_mailed_from);
  end if;
  if p_mailed_to is not null then
    w := w || format(' and m."Date" <= %L::date', p_mailed_to);
  end if;

  foreach t in array public.search_tokens(q) loop
    if t <> '' then
      w := w || format(
        ' and lower(coalesce(m."FOLIO",'''')||'' ''||coalesce(m."Full Name",'''')||'' ''||'
        'coalesce(m."Property address",'''')||'' ''||coalesce(m."Property city",'''')||'' ''||'
        'coalesce(m."Property zip",'''')||'' ''||coalesce(m."Vendor",'''')||'' ''||'
        'coalesce(m."Distress",'''')) like %L', '%' || t || '%');
    end if;
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- One page of the Mailing list, and its exact size.
-- ---------------------------------------------------------------
drop function if exists public.search_mailed(text, text, text, date, date, int, int);
drop function if exists public.search_mailed(text, text, text, date, date, int, int, int, int);
create function public.search_mailed(
  q             text default null,
  p_vendor      text default null,
  p_distress    text default null,
  p_mailed_from date default null,
  p_mailed_to   date default null,
  max_rows      int  default 15,
  skip          int  default 0
)
returns table (
  folio            text,
  county           text,
  full_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  vendor           text,
  distress         text,
  mailed_on        date,
  check_no         text
)
language plpgsql
stable
as $fn$
begin
  -- ids first, then the BuyBox lookup for just this page: doing it before the
  -- LIMIT would run the lookup for every row in the table
  return query execute format($q$
    with page as (
      select m.ctid as rid
      from public."Mailed" m
      where true %s
      order by m."Date" desc nulls last, m."Property address" nulls last, m.ctid
      limit %s offset %s
    )
    select m."FOLIO", b.county, m."Full Name",
           m."Property address", m."Property city", m."Property state", m."Property zip",
           nullif(btrim(m."Vendor"), ''), nullif(btrim(m."Distress"), ''),
           m."Date", m."Check"
    from public."Mailed" m
    join page on page.rid = m.ctid
    left join lateral (
      select min(bb."Property county") as county from public."BuyBox" bb
      where public.folio_norm(bb."FOLIO") = public.folio_norm(m."FOLIO")
    ) b on true
    order by m."Date" desc nulls last, m."Property address" nulls last, m.ctid
  $q$,
  public.mailed_where(q, p_vendor, p_distress, p_mailed_from, p_mailed_to),
  greatest(1, least(coalesce(max_rows, 15), 5000)),
  greatest(0, coalesce(skip, 0)));
end
$fn$;

drop function if exists public.count_mailed(text, text, text, date, date);
drop function if exists public.count_mailed(text, text, text, date, date, int, int);
create function public.count_mailed(
  q             text default null,
  p_vendor      text default null,
  p_distress    text default null,
  p_mailed_from date default null,
  p_mailed_to   date default null
)
returns bigint
language plpgsql
stable
as $fn$
declare n bigint;
begin
  execute format('select count(*) from public."Mailed" m where true %s',
                 public.mailed_where(q, p_vendor, p_distress, p_mailed_from, p_mailed_to))
    into n;
  return coalesce(n, 0);
end
$fn$;

grant execute on function public.list_mail_vendors()                          to anon, authenticated;
grant execute on function public.list_mail_distresses()                       to anon, authenticated;
grant execute on function public.list_mail_periods()                          to anon, authenticated;
grant execute on function public.mail_date_bounds()                           to anon, authenticated;
grant execute on function public.mailed_where(text, text, text, date, date)   to anon, authenticated;
grant execute on function public.search_mailed(text, text, text, date, date, int, int) to anon, authenticated;
grant execute on function public.count_mailed(text, text, text, date, date)   to anon, authenticated;

commit;
