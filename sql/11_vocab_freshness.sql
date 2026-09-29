-- SOS Phones : make the distress counts' age visible.  Safe to re-run.
--
-- The chips read distress_vocab, a materialised view, because computing the
-- vocabulary live is a ~6s scan of 286k rows. That means the numbers are only
-- as fresh as the last refresh -- and when they go stale they are silently
-- wrong: Pre-Probate read 476 while the table held 6,660, and Garnishment did
-- not appear at all. Filtering was never affected; it has always run live off
-- the containment index.
begin;

create table if not exists public.vocab_meta (
  only_row     boolean primary key default true check (only_row),
  refreshed_at timestamptz not null default now()
);

insert into public.vocab_meta (only_row) values (true) on conflict do nothing;

-- refreshing now records when, so the page can say how old the counts are
create or replace function public.refresh_distress_vocab() returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  refresh materialized view concurrently public.distress_vocab;
  insert into public.vocab_meta (only_row, refreshed_at) values (true, now())
    on conflict (only_row) do update set refreshed_at = now();
end $$;

alter table public.vocab_meta enable row level security;
drop policy if exists vocab_meta_read on public.vocab_meta;
create policy vocab_meta_read on public.vocab_meta
  for select to anon, authenticated using (true);

grant select on public.vocab_meta to anon, authenticated;

commit;
