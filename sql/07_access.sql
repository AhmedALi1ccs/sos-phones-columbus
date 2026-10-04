-- SOS Phones : who may read and write what.  Safe to re-run.
-- Run last: it grants on objects the earlier files create.
--
-- This site is intentionally open to anyone with the link: the publishable key
-- ships in config.js. It can read Buybox / Mail / SMS / ColdCalling, read and
-- write phone numbers, and move records out of Buybox (only into notBuybox, and
-- only through remove_from_buybox()). It cannot write Buybox, Mail or SMS
-- directly. To close it off later, swap `anon` for `authenticated` below and
-- add Supabase login.
begin;

alter table public."Buybox"          enable row level security;
alter table public."Mail"            enable row level security;
alter table public."SMS"             enable row level security;
alter table public."ColdCalling"     enable row level security;
alter table public."notBuybox"       enable row level security;
alter table public.property_phones   enable row level security;
alter table public.vocab_meta        enable row level security;

drop policy if exists buybox_read on public."Buybox";
create policy buybox_read on public."Buybox" for select to anon, authenticated using (true);

drop policy if exists mail_read on public."Mail";
create policy mail_read on public."Mail" for select to anon, authenticated using (true);

drop policy if exists sms_read on public."SMS";
create policy sms_read on public."SMS" for select to anon, authenticated using (true);

-- the website reads this list; only the uploader writes it
drop policy if exists coldcalling_read on public."ColdCalling";
create policy coldcalling_read on public."ColdCalling" for select to anon, authenticated using (true);

drop policy if exists notbuybox_read on public."notBuybox";
create policy notbuybox_read on public."notBuybox" for select to anon, authenticated using (true);

drop policy if exists vocab_meta_read on public.vocab_meta;
create policy vocab_meta_read on public.vocab_meta for select to anon, authenticated using (true);

drop policy if exists phones_read   on public.property_phones;
drop policy if exists phones_insert on public.property_phones;
drop policy if exists phones_update on public.property_phones;
drop policy if exists phones_delete on public.property_phones;
create policy phones_read   on public.property_phones for select to anon, authenticated using (true);
create policy phones_insert on public.property_phones for insert to anon, authenticated with check (true);
create policy phones_update on public.property_phones for update to anon, authenticated using (true) with check (true);
create policy phones_delete on public.property_phones for delete to anon, authenticated using (true);

revoke insert, update, delete, truncate
  on public."Buybox", public."Mail", public."SMS", public."ColdCalling", public."notBuybox", public.vocab_meta
  from anon, authenticated;
grant select
  on public."Buybox", public."Mail", public."SMS", public."ColdCalling", public."notBuybox",
     public.vocab_meta, public.distress_vocab
  to anon, authenticated;
grant select, insert, update, delete on public.property_phones to anon, authenticated;
grant usage on all sequences in schema public to anon, authenticated;

-- search
grant execute on function public.search_properties(text, int, int, text, text[])   to anon, authenticated;
grant execute on function public.count_properties(text, text, text[])              to anon, authenticated;
grant execute on function public.properties_where(text, text, text[])              to anon, authenticated;
grant execute on function public.export_properties(text, text, text[], int, int)   to anon, authenticated;
grant execute on function public.list_distresses()                                 to anon, authenticated;
grant execute on function public.get_property(text)                                to anon, authenticated;
grant execute on function public.search_words(text)                                to anon, authenticated;
grant execute on function public.word_like(text, text)                             to anon, authenticated;
grant execute on function public.fold_street_words(text)                           to anon, authenticated;
grant execute on function public.addr_norm(text)                                   to anon, authenticated;
grant execute on function public.parcel_norm(text)                                 to anon, authenticated;
grant execute on function public.distress_norm(text)                               to anon, authenticated;
grant execute on function public.distress_keys(text)                               to anon, authenticated;
grant execute on function public.list_stack(text)                                  to anon, authenticated;
-- refreshing the counts is for whoever loads Buybox, not the website
revoke execute on function public.refresh_distress_vocab() from public, anon, authenticated;

-- mailing
grant execute on function public.month_num(text)                                   to anon, authenticated;
grant execute on function public.year_num(text)                                    to anon, authenticated;
grant execute on function public.period_of(text, text)                             to anon, authenticated;
grant execute on function public.mail_period(text)                                 to anon, authenticated;
grant execute on function public.list_mail_tags()                                  to anon, authenticated;
grant execute on function public.list_mail_periods()                               to anon, authenticated;
grant execute on function public.mail_where(text, text, date)                      to anon, authenticated;
grant execute on function public.search_mail(text, text, date, int, int)           to anon, authenticated;
grant execute on function public.count_mail(text, text, date)                      to anon, authenticated;
grant execute on function public.get_mail_history(text)                            to anon, authenticated;

-- sms
grant execute on function public.list_sms_approaches()                             to anon, authenticated;
grant execute on function public.list_sms_periods()                                to anon, authenticated;
grant execute on function public.sms_where(text, text, date)                       to anon, authenticated;
grant execute on function public.search_sms(text, text, date, int, int)            to anon, authenticated;
grant execute on function public.count_sms(text, text, date)                       to anon, authenticated;
grant execute on function public.get_sms_history(text)                             to anon, authenticated;

-- cold calling
grant execute on function public.list_call_sources()                               to anon, authenticated;
grant execute on function public.calls_where(text, text)                           to anon, authenticated;
grant execute on function public.search_calls(text, text, int, int)                to anon, authenticated;
grant execute on function public.count_calls(text, text)                           to anon, authenticated;

-- removal: no login, by choice -- see README "Settings"
grant execute on function public.count_removal(text, text)                         to anon, authenticated;
grant execute on function public.remove_from_buybox(text, text, text)              to anon, authenticated;
grant execute on function public.restore_to_buybox(text, text, int)                to anon, authenticated;
grant execute on function public.list_removals(int)                                to anon, authenticated;

commit;
