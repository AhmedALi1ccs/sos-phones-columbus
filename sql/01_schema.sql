-- SOS Phones : schema for property search + phone status tracking
-- Safe to re-run.  Run with:  psql -f sql/01_schema.sql
begin;

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------
-- 1. Search + lookup support on the existing Buybox table.
--    Expression indexes only: the table itself is NOT altered, so bulk
--    COPY / INSERT loads into Buybox keep working unchanged.
-- ---------------------------------------------------------------
create index if not exists buybox_search_trgm on public."Buybox" using gin (
  lower(
    coalesce("Full Name",'')||' '||coalesce("First Name",'')||' '||coalesce("Last Name",'')||' '||
    coalesce("Property address",'')||' '||coalesce("Property city",'')||' '||coalesce("Property state",'')||' '||coalesce("Property zip",'')||' '||
    coalesce("Mailing address",'')||' '||coalesce("Mailing city",'')||' '||coalesce("Mailing state",'')||' '||coalesce("Mailing zip",'')
  ) extensions.gin_trgm_ops
);

-- how a parcel number is compared: case-folded, with all punctuation stripped,
-- so '010-000001-00', '01000000100' and '010 000001 00' are the same parcel.
create or replace function public.parcel_norm(p text) returns text
  language sql immutable parallel safe as
$$ select nullif(upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')), '') $$;

create index if not exists buybox_parcel_idx on public."Buybox" (public.parcel_norm("Parcel Number"));
-- lets "search by Parcel Number" match a fragment, not just a prefix
create index if not exists buybox_parcel_trgm on public."Buybox"
  using gin (public.parcel_norm("Parcel Number") extensions.gin_trgm_ops);
create index if not exists mail_parcel_idx on public."Mail" (public.parcel_norm("Parcel Number"));
create index if not exists sms_parcel_idx  on public."SMS"  (public.parcel_norm("parcel number"));

-- ---------------------------------------------------------------
-- 2. Phone numbers : one row per phone, keyed to the property by its
--    normalised parcel number.  Not a foreign key on purpose: a record
--    removed from Buybox (or reloaded) keeps its numbers.
-- ---------------------------------------------------------------
create table if not exists public.property_phones (
  id          bigint generated always as identity primary key,
  parcel      text not null,                  -- as stored in Buybox, e.g. '010-000001-00'
  parcel_key  text generated always as (upper(regexp_replace(coalesce(parcel,''), '[^A-Za-z0-9]', '', 'g'))) stored,
  phone       text not null,
  -- digits only, with a leading country code dropped, so that 614-555-1234,
  -- (614) 555-1234 and 1-614-555-1234 are one number and the unique index
  -- below actually catches the duplicate
  phone_norm  text generated always as (
                case when length(regexp_replace(coalesce(phone,''), '\D', '', 'g')) = 11
                      and left(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 1) = '1'
                     then substr(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 2)
                     else regexp_replace(coalesce(phone,''), '\D', '', 'g')
                end) stored,
  slot        smallint,                       -- display order, 1..30
  phone_type  text check (phone_type is null or phone_type in ('landline','mobile')),
  status      text check (status is null or status in ('correct','wrong','dead')),
  note        text,
  updated_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint property_phones_parcel_not_blank check (btrim(parcel) <> '')
);

-- the same number cannot be listed twice on one parcel
create unique index if not exists property_phones_uniq
  on public.property_phones (parcel_key, phone_norm);
create index if not exists property_phones_prop_idx
  on public.property_phones (parcel_key, slot, id);
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
   where p.parcel_key = upper(regexp_replace(coalesce(new.parcel,''), '[^A-Za-z0-9]', '', 'g'));
  if n >= 30 then
    raise exception 'parcel % already has 30 phone numbers', new.parcel
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists property_phones_cap on public.property_phones;
create trigger property_phones_cap before insert on public.property_phones
  for each row execute function public.tg_phone_cap();

-- ---------------------------------------------------------------
-- 3. Distress reasons.  "Lists" is a comma separated string whose values
--    may arrive in several spellings (HIGH EQUITY / High equity,
--    Tax Delinquent / Tax Del).  These fold them to one key per reason.
-- ---------------------------------------------------------------
create or replace function public.distress_norm(v text) returns text
  language sql immutable parallel safe as
$$ select case btrim(lower(regexp_replace(coalesce(v,''), '[^A-Za-z0-9]+', ' ', 'g')))
            when 'tax del' then 'tax delinquent'
            when ''        then null
            else btrim(lower(regexp_replace(coalesce(v,''), '[^A-Za-z0-9]+', ' ', 'g')))
          end $$;

-- The distinct reasons on a record, in the order they first appear.
-- PL/pgSQL rather than SQL on purpose: a SQL function with an aggregate cannot
-- be inlined, so Postgres re-plans it on every call (~29us a row), and this
-- runs once per row whenever a distress filter is rechecked or a filtered set
-- is sorted by stack. This version is ~4us. It folds each value exactly as
-- distress_norm() does -- keep the two in step.
create or replace function public.distress_keys(lists text) returns text[]
  language plpgsql immutable parallel safe as
$$
declare
  v   text;
  k   text;
  acc text[] := '{}';
begin
  if lists is null or lists = '' then
    return acc;
  end if;
  foreach v in array string_to_array(lists, ',') loop
    k := btrim(lower(regexp_replace(v, '[^A-Za-z0-9]+', ' ', 'g')));
    if k = 'tax del' then
      k := 'tax delinquent';
    end if;
    if k <> '' and not (k = any(acc)) then
      acc := acc || k;
    end if;
  end loop;
  return acc;
end
$$;

-- containment index, so "show me every PROBATE + HIGH EQUITY record" is indexed
create index if not exists buybox_lists_gin
  on public."Buybox" using gin (public.distress_keys("Lists"));

-- how many distinct distress reasons a record carries ("list stack").
-- Built on distress_keys so HIGH EQUITY + High equity counts once.
create or replace function public.list_stack(lists text) returns int
  language sql immutable parallel safe as
$$ select coalesce(cardinality(public.distress_keys(lists)), 0) $$;

-- Serves "everything, heaviest stack first" without sorting 418k rows.
-- INCLUDE ("Lists") is what makes it an INDEX ONLY scan: without the underlying
-- column in the index, deep pages fall back to a heap fetch per skipped row.
create index if not exists buybox_stack_idx
  on public."Buybox" (public.list_stack("Lists") desc, "Parcel Number") include ("Lists");

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
  -- 418k rows exceeds the statement timeout.
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

-- Address matching, for imports that carry an address instead of a parcel.
-- "1570 Franklin Avenue" and "1570 FRANKLIN AVE" both become "1570 FRANKLIN AVE".
create or replace function public.addr_norm(a text) returns text
language sql immutable parallel safe as
$$ select upper(public.fold_street_words(a)) $$;

create index if not exists buybox_addr_norm_idx
  on public."Buybox" (public.addr_norm("Property address"));

-- ---------------------------------------------------------------
-- 5. The search box.  This data abbreviates street suffixes (st, ave, dr)
--    but spells out the words in street names (Summit, Creek, Ridge), so a
--    typed word matches either as typed or as its abbreviation: "avenue"
--    finds "ave", and "summit" still finds "summit st".
-- ---------------------------------------------------------------
create or replace function public.search_words(q text) returns text[]
language sql immutable parallel safe as
$$ select coalesce(regexp_split_to_array(
            nullif(btrim(regexp_replace(lower(coalesce(q, '')), '[^a-z0-9]+', ' ', 'g')), ''), ' '),
          '{}'::text[]) $$;

-- the SQL fragment "expr contains this word, or its abbreviation"
create or replace function public.word_like(expr text, word text) returns text
language plpgsql immutable parallel safe as
$fn$
declare
  abbr text := public.fold_street_words(word);
begin
  if abbr is null or abbr = word then
    return format('%s like %L', expr, '%' || word || '%');
  end if;
  return format('(%s like %L or %s like %L)', expr, '%' || word || '%', expr, '%' || abbr || '%');
end
$fn$;

commit;
