-- SOS Phones : cold calling lists.  Safe to re-run.
--
-- A row is "this number, for this address, came from this source". The address
-- is resolved to a parcel where BuyBox knows it, so a row can link through to
-- the property page -- but a row that resolves to nothing is still kept, since
-- a calling list is worth having even for addresses not in BuyBox.
begin;

create table if not exists public."ColdCalling" (
  id           bigint generated always as identity primary key,
  address      text not null,
  addr_key     text generated always as (upper(public.fold_street_words(address))) stored,
  phone        text not null,
  phone_norm   text generated always as (
                 case when length(regexp_replace(coalesce(phone,''), '\D', '', 'g')) = 11
                       and left(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 1) = '1'
                      then substr(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 2)
                      else regexp_replace(coalesce(phone,''), '\D', '', 'g')
                 end) stored,
  source       text,
  folio        text,                       -- filled in when the address matched a parcel
  county       text,
  folio_key    text generated always as (
                 upper(regexp_replace(regexp_replace(coalesce(folio,''), '^\s*[Ff]\s*#\s*', ''),
                                      '[^A-Za-z0-9]', '', 'g'))) stored,
  county_key   text generated always as (lower(btrim(coalesce(county, '')))) stored,
  uploaded_src text,
  created_at   timestamptz not null default now(),
  constraint coldcalling_address_not_blank check (btrim(address) <> '')
);

-- the same number for the same address from the same source is one entry
create unique index if not exists coldcalling_uniq
  on public."ColdCalling" (addr_key, phone_norm, coalesce(source, ''));
create index if not exists coldcalling_folio_idx  on public."ColdCalling" (folio_key, county_key);
create index if not exists coldcalling_source_idx on public."ColdCalling" (source);
create index if not exists coldcalling_phone_idx  on public."ColdCalling" (phone_norm);
create index if not exists coldcalling_created_idx on public."ColdCalling" (created_at desc);

-- ---------------------------------------------------------------
-- The source picker, with counts.
-- ---------------------------------------------------------------
drop function if exists public.list_call_sources();
create function public.list_call_sources()
returns table (source text, n bigint)
language sql stable as $$
  select coalesce(nullif(btrim(source), ''), '(none)'), count(*)
  from public."ColdCalling" group by 1 order by 2 desc;
$$;

-- ---------------------------------------------------------------
-- One filter, used by both the page and its total.
-- ---------------------------------------------------------------
drop function if exists public.calls_where(text, text);
create function public.calls_where(q text default null, p_source text default null)
returns text
language plpgsql
immutable
as $fn$
declare
  w text := '';
  t text;
begin
  if coalesce(btrim(p_source), '') <> '' then
    w := w || case when p_source = '(none)'
                   then ' and coalesce(btrim(c.source), '''') = '''''
                   else format(' and btrim(c.source) = %L', btrim(p_source)) end;
  end if;

  foreach t in array public.search_tokens(q) loop
    if t <> '' then
      w := w || format(
        ' and lower(coalesce(c.address,'''')||'' ''||coalesce(c.phone,'''')||'' ''||'
        'coalesce(c.source,'''')||'' ''||coalesce(c.folio,'''')) like %L', '%' || t || '%');
    end if;
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- One page of the cold calling list, and its exact size.
-- ---------------------------------------------------------------
drop function if exists public.search_calls(text, text, int, int);
create function public.search_calls(
  q        text default null,
  p_source text default null,
  max_rows int  default 15,
  skip     int  default 0
)
returns table (
  id               bigint,
  address          text,
  phone            text,
  source           text,
  folio            text,
  county           text,
  full_name        text,
  property_city    text,
  property_state   text,
  property_zip     text,
  created_at       timestamptz
)
language plpgsql
stable
as $fn$
begin
  -- ids first, then the BuyBox lookup for just this page: doing it before the
  -- LIMIT would run the lookup for every row in the table
  return query execute format($q$
    with page as (
      select c.id from public."ColdCalling" c
      where true %s
      order by c.address, c.phone_norm, c.id
      limit %s offset %s
    )
    select c.id, c.address, c.phone, c.source, c.folio,
           coalesce(c.county, b."Property county"), b."Full Name",
           b."Property city", b."Property state", b."Property zip", c.created_at
    from public."ColdCalling" c
    join page on page.id = c.id
    left join lateral (
      select bb."Property county", bb."Full Name", bb."Property city",
             bb."Property state", bb."Property zip"
      from public."BuyBox" bb
      where public.folio_norm(bb."FOLIO") = nullif(c.folio_key, '')
      limit 1
    ) b on true
    order by c.address, c.phone_norm, c.id
  $q$,
  public.calls_where(q, p_source),
  greatest(1, least(coalesce(max_rows, 15), 5000)),
  greatest(0, coalesce(skip, 0)));
end
$fn$;

drop function if exists public.count_calls(text, text);
create function public.count_calls(q text default null, p_source text default null)
returns bigint
language plpgsql
stable
as $fn$
declare n bigint;
begin
  execute format('select count(*) from public."ColdCalling" c where true %s',
                 public.calls_where(q, p_source)) into n;
  return coalesce(n, 0);
end
$fn$;

-- the website reads this list; only the uploader writes it
alter table public."ColdCalling" enable row level security;
drop policy if exists coldcalling_read on public."ColdCalling";
create policy coldcalling_read on public."ColdCalling"
  for select to anon, authenticated using (true);

grant select on public."ColdCalling" to anon, authenticated;
grant execute on function public.list_call_sources()          to anon, authenticated;
grant execute on function public.calls_where(text, text)      to anon, authenticated;
grant execute on function public.search_calls(text, text, int, int) to anon, authenticated;
grant execute on function public.count_calls(text, text)      to anon, authenticated;

commit;
