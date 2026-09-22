-- Changes applied to a database that already holds data.
-- 01_schema.sql is the source of truth for a fresh install; this file records
-- what had to be migrated in place, and each block is safe to re-run.

-- 2026-09-22 ------------------------------------------------------------
-- phone_norm only stripped non-digits, so 1-706-836-9448 and (706) 836-9448
-- produced different keys and the unique index did not see them as the same
-- number. The uploaders normalise before inserting, so nothing reached the
-- table twice, but anything writing directly could have.
do $$
begin
  if exists (
    select 1 from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where a.attrelid = 'public.property_phones'::regclass
      and a.attname = 'phone_norm'
      and pg_get_expr(d.adbin, d.adrelid) not like '%substr%'
  ) then
    alter table public.property_phones drop column phone_norm cascade;
    alter table public.property_phones add column phone_norm text generated always as (
      case when length(regexp_replace(coalesce(phone,''), '\D', '', 'g')) = 11
            and left(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 1) = '1'
           then substr(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 2)
           else regexp_replace(coalesce(phone,''), '\D', '', 'g')
      end) stored;
    create unique index property_phones_uniq on public.property_phones (folio_key, county_key, phone_norm);
    create index property_phones_norm_idx on public.property_phones (phone_norm);
    raise notice 'phone_norm migrated';
  else
    raise notice 'phone_norm already migrated';
  end if;
end $$;
