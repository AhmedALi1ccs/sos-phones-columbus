-- SOS Phones : search / lookup RPCs + row level security.  Safe to re-run.
begin;

drop function if exists public.search_properties(text, int, int);
drop function if exists public.search_properties(text, int, int, text);
drop function if exists public.search_properties(text, int, int, text, text[]);
drop function if exists public.count_by_distress(text[]);
drop function if exists public.count_properties(text, text, text[]);
drop function if exists public.count_properties(text, text, text[], date, date);
drop function if exists public.properties_where(text, text, text[]);
drop function if exists public.properties_where(text, text, text[], date, date);
drop function if exists public.search_properties(text, int, int, text, text[], date, date);
drop function if exists public.export_properties(text, text, text[], int, int, date, date);
drop function if exists public.search_tokens(text);
drop function if exists public.list_distresses();
drop function if exists public.refresh_distress_vocab();
drop function if exists public.export_properties(text, text, text[], int, int);
drop function if exists public.get_property(text, text);
drop function if exists public.get_mail_history(text);

-- ---------------------------------------------------------------
-- search_tokens() : what the person typed, folded to the words the
-- data actually stores (it abbreviates street suffixes).
-- ---------------------------------------------------------------
create function public.search_tokens(q text)
returns text[]
language sql
immutable
as $$
  -- same street-word folding as addr_norm, from the one list in 01_schema.sql
  select case
           when public.fold_street_words(q) is null then '{}'::text[]
           else regexp_split_to_array(public.fold_street_words(q), '\s+')
         end;
$$;

-- ---------------------------------------------------------------
-- properties_where() : the filter, as a SQL fragment over "BuyBox b".
-- search_properties() and count_properties() both build on this, so a
-- page of results and its total can never disagree about the filter.
-- ---------------------------------------------------------------
create function public.properties_where(
  q             text,
  field         text   default 'all',
  p_lists       text[] default null,
  p_mailed_from date   default null,
  p_mailed_to   date   default null
)
returns text
language plpgsql
immutable
as $fn$
declare
  -- the whole record in one string: the expression the trigram index is built on
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

  fld   text := lower(coalesce(field, 'all'));
  w     text := '';
  scope text;
  toks  text[];
  t     text;
  fkey  text;
begin
  if p_lists is not null and array_length(p_lists, 1) > 0 then
    w := w || format(' and public.distress_keys(b."Lists") @> %L::text[]', p_lists);
  end if;

  -- "mailed in this window": served by mailed_folio_date_idx, which leads on
  -- the parcel because this is an EXISTS correlated to the BuyBox row
  if p_mailed_from is not null or p_mailed_to is not null then
    w := w || format(
      ' and exists (select 1 from public."Mailed" m'
      ' where public.folio_norm(m."FOLIO") = public.folio_norm(b."FOLIO")'
      ' and m.mailed_on is not null%s%s)',
      case when p_mailed_from is not null
           then format(' and m.mailed_on >= %L::date', p_mailed_from) else '' end,
      case when p_mailed_to is not null
           then format(' and m.mailed_on <= %L::date', p_mailed_to) else '' end);
  end if;

  -- a FOLIO is a parcel number, not prose: match the normalised form
  if fld = 'folio' then
    fkey := public.folio_norm(q);
    if fkey is not null and length(fkey) >= 2 then
      w := w || format(' and public.folio_norm(b."FOLIO") like %L', '%' || fkey || '%');
    end if;
    return w;
  end if;

  scope := case fld
             when 'property' then blob_prop
             when 'name'     then blob_name
             when 'mailing'  then blob_mail
             else null
           end;

  foreach t in array public.search_tokens(q) loop
    if t <> '' then
      -- blob_all is the indexed expression, so it always carries the search;
      -- the scoped blob then narrows the result to the chosen field.
      w := w || format(' and %s like %L', blob_all, '%' || t || '%');
      if scope is not null then
        w := w || format(' and %s like %L', scope, '%' || t || '%');
      end if;
    end if;
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- search_properties() : one page of results.
--   field = all | property | name | mailing | folio
--   p_lists = distress keys; a record must carry them all
-- With no query and no filter this browses everything, heaviest
-- "list stack" (number of distress reasons) first.
-- ---------------------------------------------------------------
create function public.search_properties(
  q             text,
  max_rows      int    default 15,
  skip          int    default 0,
  field         text   default 'all',
  p_lists       text[] default null,   -- distress keys; a record must carry them all
  p_mailed_from date   default null,   -- and have been mailed inside this window
  p_mailed_to   date   default null
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
  list_stack       int,
  phone_count      bigint
)
language plpgsql
stable
as $fn$
declare
  blob_prop constant text :=
    $$lower(coalesce(b."Property address",'')||' '||coalesce(b."Property city",'')||' '||coalesce(b."Property zip",''))$$;
  blob_name constant text := $$lower(coalesce(b."Full Name",''))$$;
  blob_mail constant text :=
    $$lower(coalesce(b."Mailing address",'')||' '||coalesce(b."Mailing city",'')||' '||coalesce(b."Mailing zip",''))$$;

  cols constant text :=
    $$b.id, b."FOLIO", b."Property county", b."Full Name", b."First Name", b."Last Name",
      b."Property address", b."Property city", b."Property state", b."Property zip",
      b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
      b."Lists", public.list_stack(b."Lists"),
      (select count(*) from public.property_phones p
        where p.folio_key  = public.folio_norm(b."FOLIO")
          and p.county_key = public.county_norm(b."Property county"))$$;

  fld        text := lower(coalesce(field, 'all'));
  toks       text[] := public.search_tokens(q);
  -- '0::int' not '0': a bare integer in ORDER BY is read as a column position
  addr_score text := '0::int';
  name_score text := '0::int';
  mail_score text := '0::int';
  t          text;
  order_sql  text;
  lim        int  := greatest(1, least(coalesce(max_rows, 15), 5000));
  off        int  := greatest(0, coalesce(skip, 0));
begin
  if fld = 'folio' then
    -- exact parcel first, then prefix, then the rest
    order_sql := format(
      '(public.folio_norm(b."FOLIO") = %L) desc, (public.folio_norm(b."FOLIO") like %L) desc,
       public.list_stack(b."Lists") desc, b.id',
      public.folio_norm(q), coalesce(public.folio_norm(q), '') || '%');

  elsif cardinality(toks) > 0 then
    foreach t in array toks loop
      if t <> '' then
        addr_score := addr_score || format(' + (case when %s like %L then 1 else 0 end)', blob_prop, '%' || t || '%');
        name_score := name_score || format(' + (case when %s like %L then 1 else 0 end)', blob_name, '%' || t || '%');
        mail_score := mail_score || format(' + (case when %s like %L then 1 else 0 end)', blob_mail, '%' || t || '%');
      end if;
    end loop;
    -- best match first; the list stack breaks ties
    order_sql := format(
      'greatest(%s, %s, %s) desc, (%s) desc, (lower(coalesce(b."Property address",'''')) like %L) desc,
       public.list_stack(b."Lists") desc, b."Property address" nulls last, b.id',
      addr_score, name_score, mail_score,
      case fld when 'name' then name_score when 'mailing' then mail_score else addr_score end,
      array_to_string(toks, '%') || '%');

  else
    -- nothing typed: the heaviest stack is the most interesting record.
    -- Matches buybox_stack_idx, so this is an index scan, not a 286k sort.
    order_sql := 'public.list_stack(b."Lists") desc, b.id';
  end if;

  -- Page the ids first, then fetch the columns for just those rows.
  -- The phone-count subquery in the target list is evaluated once per row the
  -- executor produces, so selecting it before OFFSET means ~150k needless
  -- counts on a deep page (9s); this way it runs `lim` times.
  return query execute format(
    'with page as (
       select b.id from public."BuyBox" b where true %s order by %s limit %s offset %s
     )
     select %s from public."BuyBox" b join page on page.id = b.id order by %s',
    public.properties_where(q, field, p_lists, p_mailed_from, p_mailed_to),
    order_sql, lim, off,
    cols, order_sql);
end
$fn$;

-- ---------------------------------------------------------------
-- count_properties() : the exact size of that result set, for paging.
-- The no-filter branch is kept separate on purpose: folded into one
-- query with OR, the predicate stops being indexable.
-- ---------------------------------------------------------------
create function public.count_properties(
  q             text   default null,
  field         text   default 'all',
  p_lists       text[] default null,
  p_mailed_from date   default null,
  p_mailed_to   date   default null
)
returns bigint
language plpgsql
stable
as $fn$
declare
  w text := public.properties_where(q, field, p_lists, p_mailed_from, p_mailed_to);
  n bigint;
begin
  if w = '' then
    select count(*) into n from public."BuyBox";
  else
    execute format('select count(*) from public."BuyBox" b where true %s', w) into n;
  end if;
  return n;
end
$fn$;

-- ---------------------------------------------------------------
-- The distress vocabulary.  The scan behind it costs ~11s on 286k rows,
-- so it is materialised; it only changes when BuyBox is reloaded, and
-- refresh_distress_vocab() is how you catch it up.
-- ---------------------------------------------------------------
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

create function public.refresh_distress_vocab() returns void
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
-- export_properties() : the same filter and order as the page, plus
-- each property's phone numbers, for building a CSV.
-- ---------------------------------------------------------------
create function public.export_properties(
  q             text   default null,
  field         text   default 'all',
  p_lists       text[] default null,
  max_rows      int    default 1000,
  skip          int    default 0,
  p_mailed_from date   default null,
  p_mailed_to   date   default null
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
  list_stack       int,
  phones           jsonb
)
language sql
stable
as $$
  select s.folio, s.county, s.full_name, s.first_name, s.last_name,
         s.property_address, s.property_city, s.property_state, s.property_zip,
         s.mailing_address, s.mailing_city, s.mailing_state, s.mailing_zip,
         s.lists, s.list_stack,
         coalesce(ph.j, '[]'::jsonb)
  from public.search_properties(q, max_rows, skip, field, p_lists, p_mailed_from, p_mailed_to) s
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
-- get_mail_history(folio) : rows from Mailed for the same parcel.
-- ---------------------------------------------------------------
create function public.get_mail_history(p_folio text)
returns table (folio text, check_no text, property_address text,
               vendor text, distress text, mailed_on date)
language sql
stable
as $$
  select m."FOLIO", m."Check", m."Property address",
         nullif(btrim(m."Vendor"), ''), nullif(btrim(m."Distress"), ''), m."Date"
  from public."Mailed" m
  where public.folio_norm(m."FOLIO") = public.folio_norm(p_folio)
  order by m."Date" desc nulls last
  limit 20;
$$;

-- ---------------------------------------------------------------
-- Row level security : this site is intentionally open to anyone
-- with the link (read BuyBox/Mailed, read+write phone rows).
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

revoke insert, update, delete, truncate on public."BuyBox", public."Mailed" from anon, authenticated;
grant  select on public."BuyBox", public."Mailed", public.distress_vocab to anon, authenticated;
grant  select, insert, update, delete on public.property_phones to anon, authenticated;
grant  usage on all sequences in schema public to anon, authenticated;
grant  execute on function public.search_properties(text, int, int, text, text[], date, date) to anon, authenticated;
grant  execute on function public.count_properties(text, text, text[], date, date)  to anon, authenticated;
grant  execute on function public.properties_where(text, text, text[], date, date)  to anon, authenticated;
grant  execute on function public.search_tokens(text)                              to anon, authenticated;
grant  execute on function public.fold_street_words(text)                          to anon, authenticated;
grant  execute on function public.addr_norm(text)                                  to anon, authenticated;
grant  execute on function public.list_distresses()                                to anon, authenticated;
grant  execute on function public.export_properties(text, text, text[], int, int, date, date) to anon, authenticated;
grant  execute on function public.get_property(text, text)                         to anon, authenticated;
grant  execute on function public.get_mail_history(text)                           to anon, authenticated;
grant  execute on function public.folio_norm(text)                                 to anon, authenticated;
grant  execute on function public.county_norm(text)                                to anon, authenticated;
grant  execute on function public.distress_norm(text)                              to anon, authenticated;
grant  execute on function public.distress_keys(text)                              to anon, authenticated;
grant  execute on function public.list_stack(text)                                 to anon, authenticated;

commit;
