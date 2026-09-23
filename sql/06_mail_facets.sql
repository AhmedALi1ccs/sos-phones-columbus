-- SOS Phones : the Mailing view.  Safe to re-run.
--
-- "Type" packs three things into one string: DM-<vendor>-<distress> <period>,
-- e.g. 'DM-OLM-Stack Aug26'. These pull the vendor and the distress back out so
-- they can be filtered on. Older rows are just a month ('Jun-26') and have
-- neither, which is reported rather than guessed at.
begin;

create or replace function public.mail_vendor(t text) returns text
language sql immutable parallel safe as
$$ select case lower((regexp_match(coalesce(t,''), '^\s*DM[-\s]*(Force|OLM)', 'i'))[1])
            when 'force' then 'DMForce'
            when 'olm'   then 'OLM'
          end $$;

create or replace function public.mail_distress(t text) returns text
language sql immutable parallel safe as
$$ select case lower((regexp_match(coalesce(t,''), '^\s*DM[-\s]*(?:Force|OLM)[-\s]*([A-Za-z]+)', 'i'))[1])
            when 'taxdel'       then 'Tax Delinquent'
            when 'codevio'      then 'Code Violations'
            when 'codeiovio'    then 'Code Violations'   -- a typo that reached the data
            when 'foreclosure'  then 'Foreclosure'
            when 'foreclosures' then 'Foreclosure'
            when 'stack'        then 'Stack'
            when 'probate'      then 'Probate'
            when 'evictions'    then 'Evictions'
            when 'divorce'      then 'Divorce'
            when 'syndicate'    then 'Syndicate'
            else initcap((regexp_match(coalesce(t,''), '^\s*DM[-\s]*(?:Force|OLM)[-\s]*([A-Za-z]+)', 'i'))[1])
          end $$;

create index if not exists mailed_vendor_idx   on public."Mailed" (public.mail_vendor("Type"));
create index if not exists mailed_distress_idx on public."Mailed" (public.mail_distress("Type"));

-- ---------------------------------------------------------------
-- The facets the two pickers offer, with counts.
-- ---------------------------------------------------------------
drop function if exists public.list_mail_vendors();
create function public.list_mail_vendors()
returns table (vendor text, n bigint)
language sql stable as $$
  select coalesce(public.mail_vendor("Type"), '(none)'), count(*)
  from public."Mailed" group by 1 order by 2 desc;
$$;

drop function if exists public.list_mail_distresses();
create function public.list_mail_distresses()
returns table (distress text, n bigint)
language sql stable as $$
  select coalesce(public.mail_distress("Type"), '(none)'), count(*)
  from public."Mailed" group by 1 order by 2 desc;
$$;

-- ---------------------------------------------------------------
-- mailed_where() : one filter, built once, so a page and its total
-- can never disagree.  '(none)' means rows whose Type carries no
-- vendor / distress at all.
-- ---------------------------------------------------------------
drop function if exists public.mailed_where(text, text, text, date, date);
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
                   then ' and public.mail_vendor(m."Type") is null'
                   else format(' and public.mail_vendor(m."Type") = %L', p_vendor) end;
  end if;

  if coalesce(btrim(p_distress), '') <> '' then
    w := w || case when p_distress = '(none)'
                   then ' and public.mail_distress(m."Type") is null'
                   else format(' and public.mail_distress(m."Type") = %L', p_distress) end;
  end if;

  if p_mailed_from is not null then
    w := w || format(' and m.mailed_on >= %L::date', p_mailed_from);
  end if;
  if p_mailed_to is not null then
    w := w || format(' and m.mailed_on <= %L::date', p_mailed_to);
  end if;

  foreach t in array public.search_tokens(q) loop
    if t <> '' then
      w := w || format(
        ' and lower(coalesce(m."FOLIO",'''')||'' ''||coalesce(m."Full Name",'''')||'' ''||'
        'coalesce(m."Property address",'''')||'' ''||coalesce(m."Property city",'''')||'' ''||'
        'coalesce(m."Property zip",'''')||'' ''||coalesce(m."Type",'''')) like %L', '%' || t || '%');
    end if;
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- One page of the Mailing list, and its exact size.
-- ---------------------------------------------------------------
drop function if exists public.search_mailed(text, text, text, date, date, int, int);
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
  mail_type        text,
  vendor           text,
  distress         text,
  mailed_on        date,
  check_no         text
)
language plpgsql
stable
as $fn$
begin
  -- Page the rows first, then look up the county for just those.  The county
  -- lateral runs once per row the executor produces, so doing it before the
  -- LIMIT means 31,675 index lookups for a 15-row page -- enough to hit the
  -- statement timeout on the unfiltered list.
  return query execute format($q$
    with page as (
      select m.ctid as rid
      from public."Mailed" m
      where true %s
      order by m.mailed_on desc nulls last, m."Property address" nulls last, m.ctid
      limit %s offset %s
    )
    select m."FOLIO", b.county, m."Full Name",
           m."Property address", m."Property city", m."Property state", m."Property zip",
           m."Type", public.mail_vendor(m."Type"), public.mail_distress(m."Type"),
           m.mailed_on, m."Check"
    from public."Mailed" m
    join page on page.rid = m.ctid
    left join lateral (
      select min(bb."Property county") as county from public."BuyBox" bb
      where public.folio_norm(bb."FOLIO") = public.folio_norm(m."FOLIO")
    ) b on true
    order by m.mailed_on desc nulls last, m."Property address" nulls last, m.ctid
  $q$,
  public.mailed_where(q, p_vendor, p_distress, p_mailed_from, p_mailed_to),
  greatest(1, least(coalesce(max_rows, 15), 5000)),
  greatest(0, coalesce(skip, 0)));
end
$fn$;

drop function if exists public.count_mailed(text, text, text, date, date);
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

grant execute on function public.mail_vendor(text)                            to anon, authenticated;
grant execute on function public.mail_distress(text)                          to anon, authenticated;
grant execute on function public.list_mail_vendors()                          to anon, authenticated;
grant execute on function public.list_mail_distresses()                       to anon, authenticated;
grant execute on function public.mailed_where(text, text, text, date, date)   to anon, authenticated;
grant execute on function public.search_mailed(text, text, text, date, date, int, int) to anon, authenticated;
grant execute on function public.count_mailed(text, text, text, date, date)   to anon, authenticated;

commit;
