-- SOS Phones : when each record was actually mailed.  Safe to re-run.
--
-- Each Mailed row is one campaign for one parcel ("DM-OLM-Stack Aug26"), so the
-- date the mailing house reports belongs on the row, not on the parcel.
begin;

alter table public."Mailed"
  add column if not exists mailed_on  date,
  add column if not exists mailed_src text;          -- where the date came from

-- the property list filters on "mailed between these dates", which is an
-- EXISTS correlated on the parcel, so the parcel comes first in the index
create index if not exists mailed_folio_date_idx
  on public."Mailed" (public.folio_norm("FOLIO"), mailed_on);
create index if not exists mailed_date_idx
  on public."Mailed" (mailed_on) where mailed_on is not null;

-- ---------------------------------------------------------------
-- mail_date_bounds() : what the date pickers should offer.
-- ---------------------------------------------------------------
drop function if exists public.mail_date_bounds();
create function public.mail_date_bounds()
returns table (first_mailed date, last_mailed date, n_dated bigint, n_undated bigint)
language sql
stable
as $$
  select min(mailed_on), max(mailed_on),
         count(*) filter (where mailed_on is not null),
         count(*) filter (where mailed_on is null)
  from public."Mailed";
$$;

grant execute on function public.mail_date_bounds() to anon, authenticated;

commit;
