-- SOS Phones : schema for property search + phone status tracking
-- Run with:  psql -f sql/01_schema.sql
begin;

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------
-- 1. Search support on the existing BuyBox table
--    Expression index only: the table itself is NOT altered, so bulk
--    COPY / INSERT loads into BuyBox keep working unchanged.
-- ---------------------------------------------------------------
create index if not exists buybox_search_trgm on public."BuyBox" using gin (
  lower(
    coalesce("Full Name",'')||' '||coalesce("First Name",'')||' '||coalesce("Last Name",'')||' '||
    coalesce("Property address",'')||' '||coalesce("Property city",'')||' '||coalesce("Property state",'')||' '||coalesce("Property zip",'')||' '||
    coalesce("Mailing address",'')||' '||coalesce("Mailing city",'')||' '||coalesce("Mailing state",'')||' '||coalesce("Mailing zip",'')
  ) gin_trgm_ops
);

create index if not exists buybox_folio_idx on public."BuyBox" ("FOLIO");
create index if not exists mailed_folio_idx on public."Mailed" ("FOLIO");
create index if not exists mailed_addr_idx  on public."Mailed" (lower("Property address"), lower("Property zip"));

-- ---------------------------------------------------------------
-- 2. Phone numbers : one row per phone, hung off BuyBox.id
-- ---------------------------------------------------------------
create table if not exists public.property_phones (
  id          bigint generated always as identity primary key,
  property_id bigint not null references public."BuyBox"(id) on delete cascade,
  phone       text   not null,
  phone_norm  text   generated always as (regexp_replace(coalesce(phone,''), '\D', '', 'g')) stored,
  slot        smallint,                       -- display order, 1..30
  label       text,                           -- Mobile / Landline / VOIP ...
  status      text check (status is null or status in ('correct','wrong','dead')),
  note        text,
  updated_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists property_phones_uniq on public.property_phones (property_id, phone_norm);
create index if not exists property_phones_prop_idx on public.property_phones (property_id, slot, id);
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

-- cap at 30 phones per property
create or replace function public.tg_phone_cap() returns trigger language plpgsql as $$
declare n int;
begin
  select count(*) into n from public.property_phones where property_id = new.property_id;
  if n >= 30 then
    raise exception 'property % already has 30 phone numbers', new.property_id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists property_phones_cap on public.property_phones;
create trigger property_phones_cap before insert on public.property_phones
  for each row execute function public.tg_phone_cap();

commit;
