-- SOS Phones : search / lookup RPCs + row level security.  Safe to re-run.
begin;

drop function if exists public.search_properties(text, int, int);
drop function if exists public.search_properties(text, int, int, text);
drop function if exists public.search_properties(text, int, int, text, text[]);
drop function if exists public.list_distresses();
drop function if exists public.refresh_distress_vocab();
drop function if exists public.export_properties(text, text, text[], int, int);
drop function if exists public.count_by_distress(text[]);
drop function if exists public.get_property(text, text);
drop function if exists public.get_mail_history(text);

-- ---------------------------------------------------------------
-- search_properties(q, max_rows, skip, field)
--   field = all | property | name | mailing | folio
-- Partial, multi-token, case-insensitive.  Every token must appear.
-- ---------------------------------------------------------------
create function public.search_properties(
  q         text,
  max_rows  int    default 50,
  skip      int    default 0,
  field     text   default 'all',
  p_lists   text[] default null      -- distress keys; a record must carry them all
)
returns table (
  id               bigint,
  folio            text,
  county           text,
  full_name        text,
  first_name       text,
  last_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  mailing_address  text,
  mailing_city     text,
  mailing_state    text,
  mailing_zip      text,
  lists            text,
  phone_count      bigint
)
language plpgsql
stable
as $fn$
declare
  -- everything in one string: this is the expression the trigram index is built on
  blob_all constant text :=
    $$lower(coalesce(b."Full Name",'')||' '||coalesce(b."First Name",'')||' '||coalesce(b."Last Name",'')||' '||
      coalesce(b."Property address",'')||' '||coalesce(b."Property city",'')||' '||coalesce(b."Property state",'')||' '||coalesce(b."Property zip",'')||' '||
      coalesce(b."Mailing address",'')||' '||coalesce(b."Mailing city",'')||' '||coalesce(b."Mailing state",'')||' '||coalesce(b."Mailing zip",''))$$;
  blob_prop constant text :=
    $$lower(coalesce(b."Property address",'')||' '||coalesce(b."Property city",'')||' '||coalesce(b."Property state",'')||' '||coalesce(b."Property zip",''))$$;
  blob_name constant text :=
    $$lower(coalesce(b."Full Name",'')||' '||coalesce(b."First Name",'')||' '||coalesce(b."Last Name",''))$$;
  blob_mail constant text :=
    $$lower(coalesce(b."Mailing address",'')||' '||coalesce(b."Mailing city",'')||' '||coalesce(b."Mailing state",'')||' '||coalesce(b."Mailing zip",''))$$;

  cols constant text :=
    $$b.id, b."FOLIO", b."Property county", b."Full Name", b."First Name", b."Last Name",
      b."Property address", b."Property city", b."Property state", b."Property zip",
      b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
      b."Lists",
      (select count(*) from public.property_phones p
        where p.folio_key  = public.folio_norm(b."FOLIO")
          and p.county_key = public.county_norm(b."Property county"))$$;

  -- the data stores addresses abbreviated; fold what people actually type
  abbrev constant text[][] := array[
    ['street','st'],['avenue','ave'],['drive','dr'],['road','rd'],['lane','ln'],
    ['court','ct'],['circle','cir'],['boulevard','blvd'],['place','pl'],['terrace','ter'],
    ['parkway','pkwy'],['highway','hwy'],['trail','trl'],['square','sq'],['apartment','apt'],
    ['north','n'],['south','s'],['east','e'],['west','w'],
    ['northeast','ne'],['northwest','nw'],['southeast','se'],['southwest','sw']
  ];

  fld        text := lower(coalesce(field, 'all'));
  scope      text;
  norm       text;
  fkey       text;
  toks       text[];
  t          text;
  a          text[];
  wheres     text := '';
  -- '0::int' not '0': a bare integer in ORDER BY is read as a column position
  addr_score text := '0::int';
  name_score text := '0::int';
  mail_score text := '0::int';
  sql        text;
  lim        int  := greatest(1, least(coalesce(max_rows, 50), 5000));
  off        int  := greatest(0, coalesce(skip, 0));
  has_lists  bool := p_lists is not null and array_length(p_lists, 1) > 0;
  list_where text := '';
begin
  if has_lists then
    list_where := format(' and public.distress_keys(b."Lists") @> %L::text[]', p_lists);
  end if;
  -- ---- a FOLIO is a parcel number, not prose: match the normalised form ----
  if fld = 'folio' then
    fkey := public.folio_norm(q);
    if fkey is null or length(fkey) < 2 then
      return;
    end if;
    return query execute format($q$
      select %s
      from public."BuyBox" b
      where public.folio_norm(b."FOLIO") like %L %s
      order by (public.folio_norm(b."FOLIO") = %L) desc,
               (public.folio_norm(b."FOLIO") like %L) desc,
               b."Property address" nulls last, b.id
      limit %s offset %s
    $q$, cols, '%' || fkey || '%', list_where, fkey, fkey || '%', lim, off);
    return;
  end if;

  scope := case fld
             when 'property' then blob_prop
             when 'name'     then blob_name
             when 'mailing'  then blob_mail
             else null
           end;

  norm := lower(coalesce(q, ''));
  norm := regexp_replace(norm, '[^a-z0-9]+', ' ', 'g');
  norm := btrim(norm);
  if norm = '' and not has_lists then
    return;                 -- nothing to search and nothing to filter by
  end if;

  foreach a slice 1 in array abbrev loop
    norm := regexp_replace(norm, '\m' || a[1] || '\M', a[2], 'g');
  end loop;

  toks := regexp_split_to_array(norm, '\s+');

  foreach t in array toks loop
    if t <> '' then
      -- blob_all is the indexed expression, so it always carries the search;
      -- the scoped blob then narrows the result to the chosen field.
      wheres := wheres || format(' and %s like %L', blob_all, '%' || t || '%');
      if scope is not null then
        wheres := wheres || format(' and %s like %L', scope, '%' || t || '%');
      end if;
      -- relevance: how many tokens land in the address vs the owner name
      addr_score := addr_score || format(' + (case when %s like %L then 1 else 0 end)', blob_prop, '%' || t || '%');
      name_score := name_score || format(' + (case when %s like %L then 1 else 0 end)', blob_name, '%' || t || '%');
      mail_score := mail_score || format(' + (case when %s like %L then 1 else 0 end)', blob_mail, '%' || t || '%');
    end if;
  end loop;

  sql := format($q$
    select %s
    from public."BuyBox" b
    where true %s %s
    order by greatest(%s, %s, %s) desc,
             (%s) desc,
             (lower(coalesce(b."Property address",'')) like %L) desc,
             b."Property address" nulls last, b.id
    limit %s offset %s
  $q$, cols, wheres, list_where,
       addr_score, name_score, mail_score,
       case fld when 'name' then name_score when 'mailing' then mail_score else addr_score end,
       replace(norm, ' ', '%') || '%',
       lim, off);

  return query execute sql;
end
$fn$;

-- ---------------------------------------------------------------
-- list_distresses() : the distress vocabulary, folded to one row per
-- reason, labelled with the spelling that appears most often, and counted.
-- ---------------------------------------------------------------
-- The scan behind this costs ~11s on 286k rows, so it is materialised.
-- It only changes when BuyBox is reloaded: run refresh_distress_vocab() then.
drop materialized view if exists public.distress_vocab cascade;
create materialized view public.distress_vocab as
  select public.distress_norm(v)                 as key,
         mode() within group (order by btrim(v)) as label,
         count(distinct b.id)                    as n_properties
  from public."BuyBox" b,
       unnest(string_to_array(coalesce(b."Lists",''), ',')) v
  where public.distress_norm(v) is not null
  group by 1;

create unique index distress_vocab_key on public.distress_vocab (key);

create or replace function public.refresh_distress_vocab() returns void
  language sql security definer as
$$ refresh materialized view concurrently public.distress_vocab $$;

create function public.list_distresses()
returns table (key text, label text, n_properties bigint)
language sql
stable
as $$
  select key, label, n_properties from public.distress_vocab order by n_properties desc;
$$;

-- ---------------------------------------------------------------
-- count_by_distress() : how many records carry ALL of these reasons.
-- Answered straight from the containment index, so it stays cheap even
-- for the large lists.
-- ---------------------------------------------------------------
-- The branches are kept apart on purpose: written as one query with
-- "p_lists is null or ... @> p_lists", the OR makes the predicate
-- unindexable and the count degrades to a 286k-row scan (~12s per call).
create function public.count_by_distress(p_lists text[])
returns bigint
language plpgsql
stable
as $$
declare n bigint;
begin
  if p_lists is null or array_length(p_lists, 1) is null then
    select count(*) into n from public."BuyBox";
  else
    select count(*) into n from public."BuyBox" b
     where public.distress_keys(b."Lists") @> p_lists;
  end if;
  return n;
end $$;

-- ---------------------------------------------------------------
-- export_properties() : the same filter as the search box, plus each
-- property's phone numbers, for building a CSV.  Paged by the caller.
-- ---------------------------------------------------------------
create function public.export_properties(
  q        text   default null,
  field    text   default 'all',
  p_lists  text[] default null,
  max_rows int    default 1000,
  skip     int    default 0
)
returns table (
  folio            text,
  county           text,
  full_name        text,
  first_name       text,
  last_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  mailing_address  text,
  mailing_city     text,
  mailing_state    text,
  mailing_zip      text,
  distress_lists   text,
  phones           jsonb
)
language sql
stable
as $$
  select s.folio, s.county, s.full_name, s.first_name, s.last_name,
         s.property_address, s.property_city, s.property_state, s.property_zip,
         s.mailing_address, s.mailing_city, s.mailing_state, s.mailing_zip,
         s.lists,
         coalesce(ph.j, '[]'::jsonb)
  from public.search_properties(q, max_rows, skip, field, p_lists) s
  left join lateral (
    select jsonb_agg(jsonb_build_object(
             'phone', p.phone, 'type', p.phone_type, 'status', p.status)
           order by p.slot, p.id) as j
    from public.property_phones p
    where p.folio_key  = public.folio_norm(s.folio)
      and p.county_key = public.county_norm(s.county)
  ) ph on true;
$$;

-- ---------------------------------------------------------------
-- get_property(folio, county) : the property page loads by parcel,
-- not by BuyBox.id, so a link keeps working after BuyBox is reloaded.
-- ---------------------------------------------------------------
create function public.get_property(p_folio text, p_county text default null)
returns table (
  id               bigint,
  folio            text,
  county           text,
  full_name        text,
  first_name       text,
  last_name        text,
  property_address text,
  property_city    text,
  property_state   text,
  property_zip     text,
  mailing_address  text,
  mailing_city     text,
  mailing_state    text,
  mailing_zip      text,
  sale_date        text,
  sale_price       text,
  lists            text,
  tag              text,
  match_count      bigint            -- >1 means this parcel number is ambiguous
)
language sql
stable
as $$
  with hits as (
    select b.*
    from public."BuyBox" b
    where public.folio_norm(b."FOLIO") = public.folio_norm(p_folio)
      and (p_county is null or public.county_norm(b."Property county") = public.county_norm(p_county))
  )
  select h.id, h."FOLIO", h."Property county", h."Full Name", h."First Name", h."Last Name",
         h."Property address", h."Property city", h."Property state", h."Property zip",
         h."Mailing address", h."Mailing city", h."Mailing state", h."Mailing zip",
         h."Sale Date", h."Sale Price", h."Lists", h."Tag",
         (select count(*) from hits)
  from hits h
  order by h.id
  limit 1;
$$;

-- ---------------------------------------------------------------
-- get_mail_history(folio) : rows from Mailed for the same parcel,
-- compared on the normalised folio rather than the raw string.
-- ---------------------------------------------------------------
create function public.get_mail_history(p_folio text)
returns table (folio text, check_no text, mail_type text, property_address text)
language sql
stable
as $$
  select m."FOLIO", m."Check", m."Type", m."Property address"
  from public."Mailed" m
  where public.folio_norm(m."FOLIO") = public.folio_norm(p_folio)
  limit 20;
$$;

-- ---------------------------------------------------------------
-- Row level security : this site is intentionally open to anyone
-- with the link (read BuyBox/Mailed, read+write phone rows).
-- BuyBox and Mailed stay read-only from the browser.
-- ---------------------------------------------------------------
alter table public."BuyBox"          enable row level security;
alter table public."Mailed"          enable row level security;
alter table public.property_phones   enable row level security;

drop policy if exists buybox_read on public."BuyBox";
create policy buybox_read on public."BuyBox" for select to anon, authenticated using (true);

drop policy if exists mailed_read on public."Mailed";
create policy mailed_read on public."Mailed" for select to anon, authenticated using (true);

drop policy if exists phones_read   on public.property_phones;
drop policy if exists phones_insert on public.property_phones;
drop policy if exists phones_update on public.property_phones;
drop policy if exists phones_delete on public.property_phones;
create policy phones_read   on public.property_phones for select to anon, authenticated using (true);
create policy phones_insert on public.property_phones for insert to anon, authenticated with check (true);
create policy phones_update on public.property_phones for update to anon, authenticated using (true) with check (true);
create policy phones_delete on public.property_phones for delete to anon, authenticated using (true);

-- BuyBox / Mailed: revoke the write grants so the open anon key can only read them
revoke insert, update, delete, truncate on public."BuyBox", public."Mailed" from anon, authenticated;
grant  select on public."BuyBox", public."Mailed" to anon, authenticated;
grant  select, insert, update, delete on public.property_phones to anon, authenticated;
grant  usage on all sequences in schema public to anon, authenticated;
grant  execute on function public.search_properties(text, int, int, text, text[]) to anon, authenticated;
grant  select   on public.distress_vocab                                  to anon, authenticated;
grant  execute on function public.list_distresses()                       to anon, authenticated;
grant  execute on function public.export_properties(text, text, text[], int, int) to anon, authenticated;
grant  execute on function public.count_by_distress(text[])               to anon, authenticated;
grant  execute on function public.distress_norm(text)                     to anon, authenticated;
grant  execute on function public.distress_keys(text)                     to anon, authenticated;
grant  execute on function public.get_property(text, text)                to anon, authenticated;
grant  execute on function public.get_mail_history(text)                  to anon, authenticated;
grant  execute on function public.folio_norm(text)                        to anon, authenticated;
grant  execute on function public.county_norm(text)                       to anon, authenticated;

commit;
