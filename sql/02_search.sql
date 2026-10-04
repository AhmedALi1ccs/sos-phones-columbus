-- SOS Phones : search / lookup RPCs.  Safe to re-run.
begin;

drop function if exists public.export_properties(text, text, text[], int, int);
drop function if exists public.search_properties(text, int, int, text, text[]);
drop function if exists public.count_properties(text, text, text[]);
drop function if exists public.properties_where(text, text, text[]);
drop function if exists public.list_distresses();
drop function if exists public.refresh_distress_vocab();
drop function if exists public.get_property(text);

-- ---------------------------------------------------------------
-- properties_where() : the filter, as a SQL fragment over "Buybox b".
-- search_properties() and count_properties() both build on this, so a
-- page of results and its total can never disagree about the filter.
-- ---------------------------------------------------------------
create function public.properties_where(
  q        text,
  field    text   default 'all',
  p_lists  text[] default null
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
  t     text;
  pkey  text;
begin
  if p_lists is not null and array_length(p_lists, 1) > 0 then
    w := w || format(' and public.distress_keys(b."Lists") @> %L::text[]', p_lists);
  end if;

  -- a parcel number is not prose: match the normalised form
  if fld = 'parcel' then
    pkey := public.parcel_norm(q);
    if pkey is not null and length(pkey) >= 3 then
      w := w || format(' and public.parcel_norm(b."Parcel Number") like %L', '%' || pkey || '%');
    end if;
    return w;
  end if;

  scope := case fld
             when 'property' then blob_prop
             when 'name'     then blob_name
             when 'mailing'  then blob_mail
             else null
           end;

  foreach t in array public.search_words(q) loop
    -- blob_all is the indexed expression, so it always carries the search;
    -- the scoped blob then narrows the result to the chosen field.
    w := w || ' and ' || public.word_like(blob_all, t);
    if scope is not null then
      w := w || ' and ' || public.word_like(scope, t);
    end if;
  end loop;

  return w;
end
$fn$;

-- ---------------------------------------------------------------
-- search_properties() : one page of results.
--   field = all | property | name | mailing | parcel
--   p_lists = distress keys; a record must carry them all
-- With no query and no filter this browses everything, heaviest
-- "list stack" (number of distress reasons) first.
--
-- A typed search is ranked by how well each record matches -- unless it
-- matches more than rank_cap records. Ranking evaluates every match, and
-- "columbus" matches 240k of them: that is ~6s, past the public key's 3s
-- timeout. Past the cap the page walks buybox_stack_idx instead, heaviest
-- stack first, and says so (ranked = false).
-- ---------------------------------------------------------------
create function public.search_properties(
  q        text,
  max_rows int    default 15,
  skip     int    default 0,
  field    text   default 'all',
  p_lists  text[] default null
)
returns table (
  parcel           text,
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
  phone_count      bigint,
  ranked           boolean          -- true: best match first; false: heaviest stack first
)
language plpgsql
stable
-- runs as the owner: see "Why the search functions are SECURITY DEFINER" in README
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  blob_prop constant text :=
    $$lower(coalesce(b."Property address",'')||' '||coalesce(b."Property city",'')||' '||coalesce(b."Property zip",''))$$;
  blob_name constant text := $$lower(coalesce(b."Full Name",''))$$;
  blob_mail constant text :=
    $$lower(coalesce(b."Mailing address",'')||' '||coalesce(b."Mailing city",'')||' '||coalesce(b."Mailing zip",''))$$;

  cols constant text :=
    $$b."Parcel Number", b."Full Name", b."First Name", b."Last Name",
      b."Property address", b."Property city", b."Property state", b."Property zip",
      b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
      b."Lists", public.list_stack(b."Lists"),
      (select count(*) from public.property_phones p
        where p.parcel_key = public.parcel_norm(b."Parcel Number"))$$;

  rank_cap   constant int := 10000;
  -- nothing typed, or too much matched: the heaviest stack is the most
  -- interesting record. Matches buybox_stack_idx, so it is an index scan.
  by_stack   constant text := 'public.list_stack(b."Lists") desc, b."Parcel Number"';

  fld        text := lower(coalesce(field, 'all'));
  toks       text[] := public.search_words(q);
  where_sql  text := public.properties_where(q, field, p_lists);
  -- '0::int' not '0': a bare integer in ORDER BY is read as a column position
  addr_score text := '0::int';
  name_score text := '0::int';
  mail_score text := '0::int';
  t          text;
  n          int;
  is_ranked  boolean := false;
  order_sql  text := by_stack;
  lim        int  := greatest(1, least(coalesce(max_rows, 15), 5000));
  off        int  := greatest(0, coalesce(skip, 0));
begin
  if fld = 'parcel' and public.parcel_norm(q) is not null then
    -- exact parcel first, then prefix, then the rest
    is_ranked := true;
    order_sql := format(
      '(public.parcel_norm(b."Parcel Number") = %L) desc, (public.parcel_norm(b."Parcel Number") like %L) desc,
       public.list_stack(b."Lists") desc, b."Parcel Number"',
      public.parcel_norm(q), public.parcel_norm(q) || '%');

  elsif fld <> 'parcel' and cardinality(toks) > 0 then
    execute format('select count(*) from (select 1 from public."Buybox" b where true %s limit %s) x',
                   where_sql, rank_cap + 1) into n;

    if n <= rank_cap then
      is_ranked := true;
      foreach t in array toks loop
        addr_score := addr_score || format(' + (case when %s then 1 else 0 end)', public.word_like(blob_prop, t));
        name_score := name_score || format(' + (case when %s then 1 else 0 end)', public.word_like(blob_name, t));
        mail_score := mail_score || format(' + (case when %s then 1 else 0 end)', public.word_like(blob_mail, t));
      end loop;
      -- best match first; an address that starts with what was typed next;
      -- the list stack breaks ties
      order_sql := format(
        'greatest(%s, %s, %s) desc, (%s) desc,
         (lower(coalesce(b."Property address",'''')) like %L or lower(coalesce(b."Property address",'''')) like %L) desc,
         public.list_stack(b."Lists") desc, b."Property address" nulls last, b."Parcel Number"',
        addr_score, name_score, mail_score,
        case fld when 'name' then name_score when 'mailing' then mail_score else addr_score end,
        array_to_string(toks, '%') || '%',
        replace(public.fold_street_words(q), ' ', '%') || '%');
    end if;
  end if;

  -- Page the keys first, then fetch the columns for just those rows.
  -- The phone-count subquery in the target list is evaluated once per row the
  -- executor produces, so selecting it before OFFSET means a count for every
  -- skipped row on a deep page; this way it runs `lim` times.
  return query execute format(
    'with page as (
       select b."Parcel Number" as k from public."Buybox" b where true %s order by %s limit %s offset %s
     )
     select %s, %L::boolean from public."Buybox" b join page on page.k = b."Parcel Number" order by %s',
    where_sql,
    order_sql, lim, off,
    cols, is_ranked, order_sql);
end
$fn$;

-- ---------------------------------------------------------------
-- count_properties() : the exact size of that result set, for paging.
-- The no-filter branch is kept separate on purpose: folded into one
-- query with OR, the predicate stops being indexable.
-- ---------------------------------------------------------------
create function public.count_properties(
  q        text   default null,
  field    text   default 'all',
  p_lists  text[] default null
)
returns bigint
language plpgsql
stable
-- runs as the owner: see "Why the search functions are SECURITY DEFINER" in README
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  w text := public.properties_where(q, field, p_lists);
  n bigint;
begin
  if w = '' then
    select count(*) into n from public."Buybox";
  else
    execute format('select count(*) from public."Buybox" b where true %s', w) into n;
  end if;
  return n;
end
$fn$;

-- ---------------------------------------------------------------
-- The distress vocabulary.  The scan behind it is too slow to run on
-- every page load, so it is materialised; it only changes when Buybox
-- is reloaded, and refresh_distress_vocab() is how you catch it up.
-- ---------------------------------------------------------------
drop materialized view if exists public.distress_vocab cascade;
create materialized view public.distress_vocab as
  select public.distress_norm(v)                 as key,
         mode() within group (order by btrim(v)) as label,
         count(distinct b."Parcel Number")       as n_properties
  from public."Buybox" b,
       unnest(string_to_array(coalesce(b."Lists",''), ',')) v
  where public.distress_norm(v) is not null
  group by 1;

create unique index distress_vocab_key on public.distress_vocab (key);

-- the counts are only as fresh as the last refresh, so record when that was
-- and let the page say how old they are
create table if not exists public.vocab_meta (
  only_row     boolean primary key default true check (only_row),
  refreshed_at timestamptz not null default now()
);
insert into public.vocab_meta (only_row, refreshed_at) values (true, now())
  on conflict (only_row) do update set refreshed_at = now();

create function public.refresh_distress_vocab() returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  refresh materialized view concurrently public.distress_vocab;
  insert into public.vocab_meta (only_row, refreshed_at) values (true, now())
    on conflict (only_row) do update set refreshed_at = now();
end $$;

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
  q        text   default null,
  field    text   default 'all',
  p_lists  text[] default null,
  max_rows int    default 1000,
  skip     int    default 0
)
returns table (
  parcel           text,
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
  appraised_value  text,
  sale_date        text,
  sale_price       text,
  distress_lists   text,
  list_stack       int,
  phones           jsonb
)
language sql
stable
as $$
  select s.parcel, s.full_name, s.first_name, s.last_name,
         s.property_address, s.property_city, s.property_state, s.property_zip,
         s.mailing_address, s.mailing_city, s.mailing_state, s.mailing_zip,
         b."Appriased Value", b."Sale Date", b."Sale Price",
         s.lists, s.list_stack,
         coalesce(ph.j, '[]'::jsonb)
  from public.search_properties(q, max_rows, skip, field, p_lists) s
  join public."Buybox" b on b."Parcel Number" = s.parcel
  left join lateral (
    select jsonb_agg(jsonb_build_object(
             'phone', p.phone, 'type', p.phone_type, 'status', p.status)
           order by p.slot, p.id) as j
    from public.property_phones p
    where p.parcel_key = public.parcel_norm(s.parcel)
  ) ph on true;
$$;

-- ---------------------------------------------------------------
-- get_property(parcel) : the property page loads by parcel number,
-- in any spelling, so '01000000100' finds '010-000001-00'.
-- ---------------------------------------------------------------
create function public.get_property(p_parcel text)
returns table (
  parcel           text,
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
  appraised_value  text,
  sale_date        text,
  sale_price       text,
  lists            text,
  tags             text
)
language sql
stable
as $$
  select b."Parcel Number", b."Full Name", b."First Name", b."Last Name",
         b."Property address", b."Property city", b."Property state", b."Property zip",
         b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
         b."Appriased Value", b."Sale Date", b."Sale Price", b."Lists", b."Tags"
  from public."Buybox" b
  where public.parcel_norm(b."Parcel Number") = public.parcel_norm(p_parcel)
  limit 1;
$$;

commit;
