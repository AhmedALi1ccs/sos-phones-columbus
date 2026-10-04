-- SOS Phones : moving records out of Buybox.  Safe to re-run.
--
-- Records are never deleted outright: they move to notBuybox with a note of
-- when, by whom and on what match, so a mistaken removal can be undone.
begin;

-- ---------------------------------------------------------------
-- notBuybox : the same columns as Buybox, plus who removed it and why.
-- LIKE copies the columns but not the primary key, which is deliberate:
-- the same parcel can be removed, restored and removed again.
-- ---------------------------------------------------------------
create table if not exists public."notBuybox" (like public."Buybox");

alter table public."notBuybox"
  add column if not exists removed_at          timestamptz not null default now(),
  add column if not exists removed_by          text,
  add column if not exists removed_match_field text,
  add column if not exists removed_match_value text;

create index if not exists notbuybox_removed_at on public."notBuybox" (removed_at desc);
create index if not exists notbuybox_parcel     on public."notBuybox" (public.parcel_norm("Parcel Number"));
create index if not exists notbuybox_batch      on public."notBuybox" (removed_match_field, removed_match_value);

-- a removal by zip touches thousands of rows; make it indexable. The
-- expression must be exactly the one count_removal()/remove_from_buybox() use.
create index if not exists buybox_zip_idx on public."Buybox" (btrim(coalesce("Property zip", '')));

-- ---------------------------------------------------------------
-- count_removal() : how many records a removal would take.
-- Shown in the confirmation before anything happens.
--
-- The branches are separate statements on purpose. Folded into one
-- query with OR/CASE over the field name, none of the three could use
-- an index and every check would scan 418k rows.
-- ---------------------------------------------------------------
create or replace function public.count_removal(p_field text, p_value text)
returns bigint
language plpgsql
stable
as $fn$
declare
  f text := lower(btrim(coalesce(p_field, '')));
  v text := btrim(coalesce(p_value, ''));
  n bigint;
begin
  if v = '' then
    return 0;
  end if;

  if f = 'parcel' then
    select count(*) into n from public."Buybox"
     where public.parcel_norm("Parcel Number") = public.parcel_norm(v);
  elsif f = 'address' then
    select count(*) into n from public."Buybox"
     where public.addr_norm("Property address") = public.addr_norm(v);
  elsif f = 'zip' then
    select count(*) into n from public."Buybox"
     where btrim(coalesce("Property zip", '')) = v;
  else
    raise exception 'field must be one of parcel number, address, zip (got %)', p_field
      using errcode = 'invalid_parameter_value';
  end if;

  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- remove_from_buybox() : move the matching records to notBuybox.
-- Returns how many moved.  Phone numbers are left alone -- they are
-- keyed on the parcel and are worth keeping if the record comes back.
-- ---------------------------------------------------------------
create or replace function public.remove_from_buybox(
  p_field text,
  p_value text,
  p_by    text default null
)
returns bigint
language plpgsql
volatile
-- SECURITY DEFINER so the public key can call this without holding delete
-- rights on Buybox itself. Granting those rights directly would let anyone
-- delete records outright; going through here, the only way out of Buybox
-- is into notBuybox. search_path is pinned so the body cannot be captured
-- by objects in another schema.
security definer
set search_path = public, pg_temp
as $fn$
declare
  f text := lower(btrim(coalesce(p_field, '')));
  v text := btrim(coalesce(p_value, ''));
  n bigint;
begin
  if v = '' then
    raise exception 'nothing to match on' using errcode = 'invalid_parameter_value';
  end if;

  -- Archive first, then delete exactly what was archived, in one statement.
  -- The other way round (DELETE ... RETURNING feeding the INSERT) is ~5x
  -- slower: a 3,424-record zip took 3.1s, past the public key's timeout.
  if f = 'parcel' then
    with archived as (
      insert into public."notBuybox"
      select b.*, now(), p_by, f, v from public."Buybox" b
       where public.parcel_norm(b."Parcel Number") = public.parcel_norm(v)
      returning "Parcel Number"
    )
    delete from public."Buybox" b using archived a where b."Parcel Number" = a."Parcel Number";
  elsif f = 'address' then
    with archived as (
      insert into public."notBuybox"
      select b.*, now(), p_by, f, v from public."Buybox" b
       where public.addr_norm(b."Property address") = public.addr_norm(v)
      returning "Parcel Number"
    )
    delete from public."Buybox" b using archived a where b."Parcel Number" = a."Parcel Number";
  elsif f = 'zip' then
    with archived as (
      insert into public."notBuybox"
      select b.*, now(), p_by, f, v from public."Buybox" b
       where btrim(coalesce(b."Property zip", '')) = v
      returning "Parcel Number"
    )
    delete from public."Buybox" b using archived a where b."Parcel Number" = a."Parcel Number";
  else
    raise exception 'field must be one of parcel number, address, zip (got %)', p_field
      using errcode = 'invalid_parameter_value';
  end if;

  get diagnostics n = row_count;
  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- restore_to_buybox() : put a removal back, so a wrong one is undoable.
--
-- Restores at most max_rows per call and returns how many it put back; the
-- page calls it until that is 0. Inserting into Buybox is slow -- ~1.5ms a
-- row, almost all of it the trigram search index -- so a 3,424-record zip in
-- one call takes 5s, past the public key's 3s timeout.
--
-- A parcel that has since been loaded into Buybox again is left in the
-- archive rather than colliding with the primary key and failing the lot.
-- ---------------------------------------------------------------
drop function if exists public.restore_to_buybox(text, text);
create or replace function public.restore_to_buybox(
  p_field  text,
  p_value  text,
  max_rows int default 500
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare n bigint;
begin
  with pick as (
    select nb.ctid as rid
    from public."notBuybox" nb
    where nb.removed_match_field = lower(btrim(coalesce(p_field, '')))
      and nb.removed_match_value = btrim(coalesce(p_value, ''))
      and not exists (select 1 from public."Buybox" b where b."Parcel Number" = nb."Parcel Number")
    limit greatest(1, least(coalesce(max_rows, 500), 2000))
  ),
  back as (
    delete from public."notBuybox" nb using pick where nb.ctid = pick.rid
    returning nb.*
  )
  insert into public."Buybox" (
    "Parcel Number", "Full Name", "First Name", "Last Name",
    "Property address", "Property city", "Property state", "Property zip",
    "Mailing address", "Mailing city", "Mailing state", "Mailing zip",
    "Appriased Value", "Sale Date", "Sale Price", "Lists", "Tags")
  select distinct on (b."Parcel Number")
         b."Parcel Number", b."Full Name", b."First Name", b."Last Name",
         b."Property address", b."Property city", b."Property state", b."Property zip",
         b."Mailing address", b."Mailing city", b."Mailing state", b."Mailing zip",
         b."Appriased Value", b."Sale Date", b."Sale Price", b."Lists", b."Tags"
  from back b
  order by b."Parcel Number", b.removed_at desc;

  get diagnostics n = row_count;
  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- list_removals() : recent removals, grouped into the batch they were
-- made as, so one can be picked out and put back.
-- ---------------------------------------------------------------
create or replace function public.list_removals(max_rows int default 25)
returns table (
  match_field text,
  match_value text,
  n_records   bigint,
  removed_at  timestamptz,
  removed_by  text
)
language sql
stable
as $$
  select removed_match_field, removed_match_value, count(*),
         max(removed_at), min(removed_by)
  from public."notBuybox"
  where removed_match_field is not null
  group by 1, 2
  order by max(removed_at) desc
  limit greatest(1, least(coalesce(max_rows, 25), 200));
$$;

commit;
