-- SOS Phones : moving records out of BuyBox.  Safe to re-run.
--
-- Records are never deleted outright: they move to notBuyBox with a note of
-- when, by whom and on what match, so a mistaken removal can be undone.
begin;

-- ---------------------------------------------------------------
-- notBuyBox : the same shape as BuyBox, plus who removed it and why.
-- LIKE copies the columns but not the identity, which is deliberate:
-- the archive keeps the original id rather than minting a new one.
-- ---------------------------------------------------------------
create table if not exists public."notBuyBox" (like public."BuyBox");

alter table public."notBuyBox"
  add column if not exists removed_at          timestamptz not null default now(),
  add column if not exists removed_by          text,
  add column if not exists removed_match_field text,
  add column if not exists removed_match_value text;

create index if not exists notbuybox_removed_at on public."notBuyBox" (removed_at desc);
create index if not exists notbuybox_folio      on public."notBuyBox" (public.folio_norm("FOLIO"));
create index if not exists notbuybox_batch      on public."notBuyBox" (removed_match_field, removed_match_value);

-- a removal by zip touches tens of thousands of rows; make it indexable
create index if not exists buybox_zip_idx on public."BuyBox" (btrim("Property zip"));

-- ---------------------------------------------------------------
-- count_removal() : how many records a removal would take.
-- Shown in the confirmation before anything happens.
--
-- The branches are separate statements on purpose. Folded into one
-- query with OR/CASE over the field name, none of the three could use
-- an index and every check would scan 286k rows.
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

  if f = 'folio' then
    select count(*) into n from public."BuyBox"
     where public.folio_norm("FOLIO") = public.folio_norm(v);
  elsif f = 'address' then
    select count(*) into n from public."BuyBox"
     where public.addr_norm("Property address") = public.addr_norm(v);
  elsif f = 'zip' then
    select count(*) into n from public."BuyBox"
     where btrim(coalesce("Property zip", '')) = v;
  else
    raise exception 'field must be one of parcel number, address, zip (got %)', p_field
      using errcode = 'invalid_parameter_value';
  end if;

  return coalesce(n, 0);
end
$fn$;

-- ---------------------------------------------------------------
-- remove_from_buybox() : move the matching records to notBuyBox.
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
-- rights on BuyBox itself. Granting those rights directly would let anyone
-- delete records outright; going through here, the only way out of BuyBox
-- is into notBuyBox. search_path is pinned so the body cannot be captured
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

  if f = 'folio' then
    with moved as (
      delete from public."BuyBox" b
       where public.folio_norm(b."FOLIO") = public.folio_norm(v)
      returning b.*
    )
    insert into public."notBuyBox"
    select m.*, now(), p_by, f, v from moved m;
  elsif f = 'address' then
    with moved as (
      delete from public."BuyBox" b
       where public.addr_norm(b."Property address") = public.addr_norm(v)
      returning b.*
    )
    insert into public."notBuyBox"
    select m.*, now(), p_by, f, v from moved m;
  elsif f = 'zip' then
    with moved as (
      delete from public."BuyBox" b
       where btrim(coalesce(b."Property zip", '')) = v
      returning b.*
    )
    insert into public."notBuyBox"
    select m.*, now(), p_by, f, v from moved m;
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
-- OVERRIDING SYSTEM VALUE because BuyBox.id is an identity column and
-- the record should return under the id it left with.
-- ---------------------------------------------------------------
create or replace function public.restore_to_buybox(
  p_field text,
  p_value text
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare n bigint;
begin
  with back as (
    delete from public."notBuyBox" nb
     where nb.removed_match_field = lower(btrim(coalesce(p_field, '')))
       and nb.removed_match_value = btrim(coalesce(p_value, ''))
    returning nb.*
  )
  insert into public."BuyBox" overriding system value
  select b.id, b."FOLIO", b."Full Name", b."First Name", b."Last Name",
         b."Property address", b."Property city", b."Property state", b."Property zip",
         b."Property county", b."Mailing address", b."Mailing city", b."Mailing state",
         b."Mailing zip", b."Sale Date", b."Sale Price", b."Lists", b."Tag"
  from back b;

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
  from public."notBuyBox"
  where removed_match_field is not null
  group by 1, 2
  order by max(removed_at) desc
  limit greatest(1, least(coalesce(max_rows, 25), 200));
$$;

-- ---------------------------------------------------------------
-- The settings page is on the open website, by explicit choice: it has
-- no login, so anyone with the link can remove records. Nothing is
-- destroyed -- removals move to notBuyBox and restore_to_buybox() puts
-- a batch back -- which is what makes that survivable.
-- ---------------------------------------------------------------
alter table public."notBuyBox" enable row level security;
drop policy if exists notbuybox_read on public."notBuyBox";
create policy notbuybox_read on public."notBuyBox"
  for select to anon, authenticated using (true);

grant select on public."notBuyBox" to anon, authenticated;
grant execute on function public.count_removal(text, text)            to anon, authenticated;
grant execute on function public.remove_from_buybox(text, text, text) to anon, authenticated;
grant execute on function public.restore_to_buybox(text, text)        to anon, authenticated;
grant execute on function public.list_removals(int)                   to anon, authenticated;

commit;
