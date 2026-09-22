-- SOS Phones : schema for property search + phone status tracking
-- Safe to re-run.  Run with:  psql -f sql/01_schema.sql
begin;

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------
-- 1. Search + lookup support on the existing BuyBox table.
--    Expression indexes only: the table itself is NOT altered, so bulk
--    COPY / INSERT loads into BuyBox keep working unchanged.
-- ---------------------------------------------------------------
create index if not exists buybox_search_trgm on public."BuyBox" using gin (
  lower(
    coalesce("Full Name",'')||' '||coalesce("First Name",'')||' '||coalesce("Last Name",'')||' '||
    coalesce("Property address",'')||' '||coalesce("Property city",'')||' '||coalesce("Property state",'')||' '||coalesce("Property zip",'')||' '||
    coalesce("Mailing address",'')||' '||coalesce("Mailing city",'')||' '||coalesce("Mailing state",'')||' '||coalesce("Mailing zip",'')
  ) gin_trgm_ops
);

-- how a FOLIO is compared: case-folded, with the cosmetic "F# " prefix and all
-- punctuation stripped,
-- so 'F# 0442207000', 'f#0442207000' and '0442207000' are the same parcel.
create or replace function public.folio_norm(f text) returns text
  language sql immutable parallel safe as
$$ select nullif(upper(regexp_replace(regexp_replace(coalesce(f,''), '^\s*[Ff]\s*#\s*', ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

create or replace function public.county_norm(c text) returns text
  language sql immutable parallel safe as
$$ select coalesce(lower(btrim(coalesce(c,''))), '') $$;

-- the real business key of a property: parcel number + county
create index if not exists buybox_folio_county_idx
  on public."BuyBox" (public.folio_norm("FOLIO"), public.county_norm("Property county"));
create index if not exists buybox_folio_idx on public."BuyBox" (public.folio_norm("FOLIO"));
-- lets "search by FOLIO" match a fragment, not just a prefix
create index if not exists buybox_folio_trgm on public."BuyBox"
  using gin (public.folio_norm("FOLIO") gin_trgm_ops);
create index if not exists mailed_folio_idx on public."Mailed" (public.folio_norm("FOLIO"));

-- ---------------------------------------------------------------
-- 2. Phone numbers : one row per phone, keyed to the property by
--    FOLIO + county rather than BuyBox.id, so the link survives a
--    full reload of BuyBox (ids get reassigned, parcel numbers do not).
-- ---------------------------------------------------------------
create table if not exists public.property_phones (
  id          bigint generated always as identity primary key,
  folio       text not null,                  -- as stored in BuyBox, e.g. 'F# 0442207000'
  county      text,                           -- parcel numbers repeat across counties
  folio_key   text generated always as (upper(regexp_replace(regexp_replace(coalesce(folio,''), '^\s*[Ff]\s*#\s*', ''), '[^A-Za-z0-9]', '', 'g'))) stored,
  county_key  text generated always as (lower(btrim(coalesce(county, ''))))                                   stored,
  phone       text not null,
  phone_norm  text generated always as (regexp_replace(coalesce(phone,''), '\D', '', 'g'))                    stored,
  slot        smallint,                       -- display order, 1..30
  phone_type  text check (phone_type is null or phone_type in ('landline','mobile')),
  status      text check (status is null or status in ('correct','wrong','dead')),
  note        text,
  updated_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint property_phones_folio_not_blank check (btrim(folio) <> '')
);

-- the same number cannot be listed twice on one parcel
create unique index if not exists property_phones_uniq
  on public.property_phones (folio_key, county_key, phone_norm);
create index if not exists property_phones_prop_idx
  on public.property_phones (folio_key, county_key, slot, id);
create index if not exists property_phones_norm_idx on public.property_phones (phone_norm);

-- keep updated_at honest
create or replace function public.tg_touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists property_phones_touch on public.property_phones;
create trigger property_phones_touch before update on public.property_phones
  for each row execute function public.tg_touch_updated_at();

-- cap at 30 phones per parcel
create or replace function public.tg_phone_cap() returns trigger language plpgsql as $$
declare n int;
begin
  select count(*) into n from public.property_phones p
   where p.folio_key  = upper(regexp_replace(regexp_replace(coalesce(new.folio,''), '^\s*[Ff]\s*#\s*', ''), '[^A-Za-z0-9]', '', 'g'))
     and p.county_key = lower(btrim(coalesce(new.county, '')));
  if n >= 30 then
    raise exception 'parcel % (% county) already has 30 phone numbers', new.folio, new.county
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists property_phones_cap on public.property_phones;
create trigger property_phones_cap before insert on public.property_phones
  for each row execute function public.tg_phone_cap();

-- ---------------------------------------------------------------
-- 3. Distress reasons.  "Lists" is a comma separated string whose values
--    arrive in several spellings (HIGH EQUITY / High equity / High Equity,
--    Tax Delinquent / Tax Del).  These fold them to one key per reason.
-- ---------------------------------------------------------------
create or replace function public.distress_norm(v text) returns text
  language sql immutable parallel safe as
$$ select case btrim(lower(regexp_replace(coalesce(v,''), '[^A-Za-z0-9]+', ' ', 'g')))
            when 'tax del' then 'tax delinquent'
            when ''        then null
            else btrim(lower(regexp_replace(coalesce(v,''), '[^A-Za-z0-9]+', ' ', 'g')))
          end $$;

create or replace function public.distress_keys(lists text) returns text[]
  language sql immutable parallel safe as
$$ select coalesce(array_agg(distinct k), '{}'::text[])
   from (select public.distress_norm(v) as k
         from unnest(string_to_array(coalesce(lists,''), ',')) v) t
   where k is not null $$;

-- containment index, so "show me every PROBATE + HIGH EQUITY record" is indexed
create index if not exists buybox_lists_gin
  on public."BuyBox" using gin (public.distress_keys("Lists"));

-- how many distinct distress reasons a record carries ("list stack").
-- Built on distress_keys so HIGH EQUITY + High equity counts once.
create or replace function public.list_stack(lists text) returns int
  language sql immutable parallel safe as
$$ select coalesce(cardinality(public.distress_keys(lists)), 0) $$;

-- Serves "everything, heaviest stack first" without sorting 286k rows.
-- INCLUDE ("Lists") is what makes it an INDEX ONLY scan: without the underlying
-- column in the index, deep pages fall back to a heap fetch per row and paging
-- to offset 150k costs ~7.5s instead of ~0.8s.
create index if not exists buybox_stack_idx
  on public."BuyBox" (public.list_stack("Lists") desc, id) include ("Lists");

-- ---------------------------------------------------------------
-- 4. Street-word folding, shared by address matching and by the search box.
--    The data stores USPS abbreviations; people type words. One list, so
--    the two can never disagree.
-- ---------------------------------------------------------------
create or replace function public.fold_street_words(a text) returns text
language sql immutable parallel safe as
$fn$
  -- One regexp pass, then a lookup per word. Doing it as ~90 sequential
  -- regexp_replace calls instead is slow enough that building the index on
  -- 286k rows exceeds the statement timeout.
  with cleaned as (
    select btrim(regexp_replace(lower(coalesce(a, '')), '[^a-z0-9]+', ' ', 'g')) as s
  ),
  words as (
    select t.w, t.ord
    from cleaned c, unnest(string_to_array(c.s, ' ')) with ordinality as t(w, ord)
    where c.s <> ''
  )
  select nullif(string_agg(coalesce(m.abbr, words.w), ' ' order by words.ord), '')
  from words
  left join (values
      ('street','st'),
      ('avenue','ave'),
      ('drive','dr'),
      ('road','rd'),
      ('lane','ln'),
      ('court','ct'),
      ('circle','cir'),
      ('boulevard','blvd'),
      ('place','pl'),
      ('terrace','ter'),
      ('parkway','pkwy'),
      ('highway','hwy'),
      ('trail','trl'),
      ('square','sq'),
      ('apartment','apt'),
      ('north','n'),
      ('south','s'),
      ('east','e'),
      ('west','w'),
      ('northeast','ne'),
      ('northwest','nw'),
      ('southeast','se'),
      ('southwest','sw'),
      ('meadows','mdws'),
      ('meadow','mdw'),
      ('heights','hts'),
      ('ridge','rdg'),
      ('creek','crk'),
      ('village','vlg'),
      ('villages','vlgs'),
      ('crossing','xing'),
      ('point','pt'),
      ('pointe','pt'),
      ('springs','spgs'),
      ('spring','spg'),
      ('landing','lndg'),
      ('valley','vly'),
      ('manor','mnr'),
      ('cove','cv'),
      ('bend','bnd'),
      ('gardens','gdns'),
      ('estates','ests'),
      ('forest','frst'),
      ('grove','grv'),
      ('hills','hls'),
      ('hill','hl'),
      ('junction','jct'),
      ('mount','mt'),
      ('mountain','mtn'),
      ('plaza','plz'),
      ('river','riv'),
      ('summit','smt'),
      ('station','sta'),
      ('turnpike','tpke'),
      ('view','vw'),
      ('crest','crst'),
      ('branch','br'),
      ('bridge','brg'),
      ('brook','brk'),
      ('bluff','blf'),
      ('center','ctr'),
      ('centre','ctr'),
      ('falls','fls'),
      ('fields','flds'),
      ('field','fld'),
      ('fork','frk'),
      ('fort','ft'),
      ('glen','gln'),
      ('green','grn'),
      ('harbor','hbr'),
      ('haven','hvn'),
      ('hollow','holw'),
      ('lakes','lks'),
      ('lake','lk'),
      ('lodge','ldg'),
      ('orchard','orch'),
      ('pines','pnes'),
      ('pine','pne'),
      ('plains','plns'),
      ('port','prt'),
      ('shoals','shls'),
      ('shores','shrs'),
      ('shore','shr'),
      ('trace','trce'),
      ('extension','ext'),
      ('cliff','clf'),
      ('knoll','knl'),
      ('island','is'),
      ('isle','is'),
      ('gateway','gtwy'),
      ('freeway','fwy'),
      ('expressway','expy'),
      ('causeway','cswy'),
      ('crescent','cres'),
      ('alley','aly')
  ) as m(word, abbr) on m.word = words.w
$fn$;

-- Address matching, for imports that carry an address instead of a FOLIO.
-- "2451 Juniper Drive" and "2451 JUNIPER DR" both become "2451 JUNIPER DR".
create or replace function public.addr_norm(a text) returns text
language sql immutable parallel safe as
$$ select upper(public.fold_street_words(a)) $$;

create index if not exists buybox_addr_norm_idx
  on public."BuyBox" (public.addr_norm("Property address"));

commit;
