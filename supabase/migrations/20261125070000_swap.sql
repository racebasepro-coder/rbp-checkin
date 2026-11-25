-- Swap all personal data of two participants (bib, pickup and package state stay on their bib numbers).
-- Called only by checkin-admin (action "swap").
alter table checkin_secret add column if not exists swap_pin_hash text; -- unused: the swap needs no PIN

create table if not exists checkin_swaps (
  id bigserial primary key, event_id text not null, bib_a integer not null, bib_b integer not null,
  device text, created_at timestamptz not null default now());
alter table checkin_swaps enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'checkin_swaps' and policyname = 'staff read swaps') then
    create policy "staff read swaps" on checkin_swaps for select to authenticated using (checkin_staff());
  end if;
end $$;
grant select on checkin_swaps to authenticated;

create or replace function public.checkin_swap(p_event text, p_a integer, p_b integer, p_device text)
returns void language plpgsql security definer set search_path = public as $$
declare a checkin_participants; b checkin_participants;
begin
  if p_a = p_b then raise exception 'Pick two different bibs'; end if;
  select * into a from checkin_participants where event_id = p_event and bib = p_a for update;
  select * into b from checkin_participants where event_id = p_event and bib = p_b for update;
  if a.bib is null or b.bib is null then raise exception 'Bib not found'; end if;
  update checkin_participants set first_name = b.first_name, last_name = b.last_name, team = b.team, sex = b.sex,
    nation = b.nation, dob = b.dob, yob = b.yob, age_group = b.age_group, shirt_size = b.shirt_size, qid = b.qid,
    email = b.email, phone = b.phone, ice_name = b.ice_name, ice_phone = b.ice_phone, updated_at = now()
  where event_id = p_event and bib = p_a;
  update checkin_participants set first_name = a.first_name, last_name = a.last_name, team = a.team, sex = a.sex,
    nation = a.nation, dob = a.dob, yob = a.yob, age_group = a.age_group, shirt_size = a.shirt_size, qid = a.qid,
    email = a.email, phone = a.phone, ice_name = a.ice_name, ice_phone = a.ice_phone, updated_at = now()
  where event_id = p_event and bib = p_b;
  -- RR14 gets both bibs with the swapped data (field names: checkin-sync WRITE_DEFAULT / Settings).
  insert into checkin_outbox (event_id, bib, fields) values
    (p_event, p_a, jsonb_build_object('first', coalesce(b.first_name,''), 'last', coalesce(b.last_name,''), 'team', coalesce(b.team,''),
      'sex', case b.sex when 'W' then 'f' when 'M' then 'm' else '' end, 'nat', coalesce(b.nation,''), 'dob', coalesce(b.dob::text,''),
      'qid', coalesce(b.qid,''), 'email', coalesce(b.email,''), 'phone', coalesce(b.phone,''), 'ice', coalesce(b.ice_name,''),
      'icePhone', coalesce(b.ice_phone,''), 'size', coalesce(b.shirt_size,''))),
    (p_event, p_b, jsonb_build_object('first', coalesce(a.first_name,''), 'last', coalesce(a.last_name,''), 'team', coalesce(a.team,''),
      'sex', case a.sex when 'W' then 'f' when 'M' then 'm' else '' end, 'nat', coalesce(a.nation,''), 'dob', coalesce(a.dob::text,''),
      'qid', coalesce(a.qid,''), 'email', coalesce(a.email,''), 'phone', coalesce(a.phone,''), 'ice', coalesce(a.ice_name,''),
      'icePhone', coalesce(a.ice_phone,''), 'size', coalesce(a.shirt_size,'')));
  insert into checkin_swaps (event_id, bib_a, bib_b, device) values (p_event, p_a, p_b, p_device);
end $$;
revoke execute on function public.checkin_swap(text, integer, integer, text) from public, anon, authenticated;
grant execute on function public.checkin_swap(text, integer, integer, text) to service_role;
