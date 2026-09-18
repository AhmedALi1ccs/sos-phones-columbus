-- SOS Phones : search / lookup RPCs + row level security.  Safe to re-run.
begin;

drop function if exists public.search_properties(text, int, int);
drop function if exists public.get_property(text, text);
drop function if exists public.get_mail_history(text);

-- ---------------------------------------------------------------
-- search_properties(q) : partial, multi-token, case-insensitive match
-- across owner name, property address and mailing address.
-- Every token must appear somewhere in the record.
-- ---------------------------------------------------------------
create function public.search_properties(
  q         text,
  max_rows  int  default 50,
  skip      int  default 0
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
  blob   constant text :=
    $$lower(coalesce(b."Full Name",'')||' '||coalesce(b."First Name",'')||' '||coalesce(b."Last Name",'')||' '||
      coalesce(b."Property address",'')||' '||coalesce(b."Property city",'')||' '||coalesce(b."Property state",'')||' '||coalesce(b."Property zip",'')||' '||
      coalesce(b."Mailing address",'')||' '||coalesce(b."Mailing city",'')||' '||coalesce(b."Mailing state",'')||' '||coalesce(b."Mailing zip",''))$$;
  -- the data stores addresses abbreviated; fold what people actually type
  abbrev constant text[][] := array[
    ['street','st'],['avenue','ave'],['drive','dr'],['road','rd'],['lane','ln'],
    ['court','ct'],['circle','cir'],['boulevard','blvd'],['place','pl'],['terrace','ter'],
    ['parkway','pkwy'],['highway','hwy'],['trail','trl'],['square','sq'],['apartment','apt'],
    ['north','n'],['south','s'],['east','e'],['west','w'],
    ['northeast','ne'],['northwest','nw'],['southeast','se'],['southwest','sw']
  ];
  norm       text;
  toks       text[];
  t          text;
  a          text[];
  wheres     text := '';
  addr_score text := '0';
  name_score text := '0';
  mail_score text := '0';
  sql        text;
begin
  norm := lower(coalesce(q, ''));
  norm := regexp_replace(norm, '[^a-z0-9]+', ' ', 'g');
  norm := btrim(norm);
  if norm = '' then
    return;
  end if;

  foreach a slice 1 in array abbrev loop
    norm := regexp_replace(norm, '\m' || a[1] || '\M', a[2], 'g');
  end loop;

  toks := regexp_split_to_array(norm, '\s+');

  foreach t in array toks loop
    if t <> '' then
      wheres := wheres || format(' and %s like %L', blob, '%' || t || '%');
      -- relevance: how many tokens land in the property address vs the owner name
      addr_score := addr_score || format(
        ' + (case when lower(coalesce(b."Property address",'''')||'' ''||coalesce(b."Property city",'''')||'' ''||coalesce(b."Property zip",'''')) like %L then 1 else 0 end)',
        '%' || t || '%');
      name_score := name_score || format(
        ' + (case when lower(coalesce(b."Full Name",'''')) like %L then 1 else 0 end)',
        '%' || t || '%');
      mail_score := mail_score || format(
        ' + (case when lower(coalesce(b."Mailing address",'''')||'' ''||coalesce(b."Mailing city",'''')||'' ''||coalesce(b."Mailing zip",'''')) like %L then 1 else 0 end)',
        '%' || t || '%');
    end if;
  end loop;

  sql := format($q$
    select b.id, b."FOLIO", b."Property county", b."Full Name", b."First Name", b."Last Name",
           b."Property address", b."Property city", b."Property state", b."Property zip",
           b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
           b."Lists",
           (select count(*) from public.property_phones p
             where p.folio_key  = public.folio_norm(b."FOLIO")
               and p.county_key = public.county_norm(b."Property county"))
    from public."BuyBox" b
    where true %s
    order by greatest(%s, %s, %s) desc,
             (%s) desc,
             (lower(coalesce(b."Property address",'')) like %L) desc,
             b."Property address" nulls last, b.id
    limit %s offset %s
  $q$, wheres,
       addr_score, name_score, mail_score,
       addr_score,
       replace(norm, ' ', '%') || '%',
       greatest(1, least(coalesce(max_rows, 50), 200)),
       greatest(0, coalesce(skip, 0)));

  return query execute sql;
end
$fn$;

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
grant  execute on function public.search_properties(text, int, int) to anon, authenticated;
grant  execute on function public.get_property(text, text)          to anon, authenticated;
grant  execute on function public.get_mail_history(text)            to anon, authenticated;
grant  execute on function public.folio_norm(text)                  to anon, authenticated;
grant  execute on function public.county_norm(text)                 to anon, authenticated;

commit;
