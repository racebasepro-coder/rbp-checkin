-- RaceBasePro Check-in: its own Supabase project (not shared with any other app).
-- Several events live side by side. One event is active at a time; every iPad follows it.
-- Each event has its own RR14 links, settings, participants, signatures and statistics.
-- The RR14 links are entered in the app (Settings, RBP admin only) and are never sent to the iPads.
-- Safe to run more than once.

-- ---------- upgrade from the first version: old tables are kept, renamed to checkin_v1_* ----------
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'checkin_participants')
     and not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'checkin_participants' and column_name = 'event_id') then
    alter table public.checkin_participants rename to checkin_v1_participants;
    alter table if exists public.checkin_signatures rename to checkin_v1_signatures;
    alter table if exists public.checkin_outbox rename to checkin_v1_outbox;
    alter table if exists public.checkin_config rename to checkin_v1_config;
    alter index if exists public.checkin_participants_team rename to checkin_v1_participants_team;
    alter index if exists public.checkin_participants_sig rename to checkin_v1_participants_sig;
    alter index if exists public.checkin_outbox_open rename to checkin_v1_outbox_open;
  end if;
end $$;

-- ---------- access ----------
-- Any account created in this project (Authentication -> Users) is staff. Turn public sign-up off.
create or replace function public.checkin_staff() returns boolean
language sql stable set search_path = public as $$ select auth.uid() is not null $$;
grant execute on function public.checkin_staff() to authenticated;

-- ---------- events ----------
create table if not exists public.checkin_events (
  id         text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,40}$'),   -- e.g. doha-marathon-2026
  name       text not null,
  active     boolean not null default false,
  settings   jsonb not null default '{}'::jsonb,   -- colours, stock, field names, slogan, date format
  sync       jsonb not null default '{}'::jsonb,   -- last RR14 sync result, written by checkin-sync
  created_at timestamptz not null default now()
);
create unique index if not exists checkin_events_one_active on public.checkin_events (active) where active;

-- RR14 links per event. No policies: only the functions (service role) read or write them.
create table if not exists public.checkin_event_rr (
  event_id   text primary key references public.checkin_events(id) on delete cascade,
  list_url   text,          -- Simple API list (JSON)
  write_url  text,          -- Simple API part/savefields
  updated_at timestamptz not null default now()
);

create or replace function public.checkin_active() returns text
language sql stable security definer set search_path = public as $$
  select id from checkin_events where active limit 1 $$;
grant execute on function public.checkin_active() to authenticated;

-- ---------- data (per event) ----------
create table if not exists public.checkin_participants (
  event_id       text not null references public.checkin_events(id) on delete cascade,
  bib            integer not null,
  first_name     text not null default '',
  last_name      text not null default '',
  team           text not null default '',        -- empty = solo
  sex            text check (sex in ('M','W')),
  nation         text not null default '',
  dob            date,
  age_group      text not null default '',        -- AgeGroup.Name from RR14
  shirt_size     text not null default '',
  qid            text not null default '',
  email          text not null default '',
  phone          text not null default '',
  ice_name       text not null default '',
  ice_phone      text not null default '',
  -- pickup state, owned by the app (a pull from RR14 never overwrites it)
  sig_id         text,
  sig_time       timestamptz,
  sig_url        text,
  pickup_scope   text check (pickup_scope in ('SOLO','SELF','TEAM')),
  collected_by   integer,
  checkin_device text,
  qatari_verified text check (qatari_verified in ('Yes','Check','No')),
  package_issued boolean not null default false,
  package_time   timestamptz,
  package_device text,
  rr_synced_at   timestamptz,
  updated_at     timestamptz not null default now(),
  primary key (event_id, bib)
);
create index if not exists checkin_participants_team on public.checkin_participants (event_id, team);
create index if not exists checkin_participants_sig  on public.checkin_participants (sig_id);

-- Signature files are in Storage (bucket checkin-signatures, folder per event).
create table if not exists public.checkin_signatures (
  id         text primary key,                    -- s201-1764050000000
  event_id   text not null references public.checkin_events(id) on delete cascade,
  collector  integer not null,
  bibs       integer[] not null,
  path       text not null,
  token      text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  device     text,
  created_at timestamptz not null default now()
);
create index if not exists checkin_signatures_event on public.checkin_signatures (event_id, created_at desc);

-- Writes waiting for RR14 (app field keys; checkin-sync renames them with the event's field map).
create table if not exists public.checkin_outbox (
  id         bigint generated always as identity primary key,
  event_id   text not null references public.checkin_events(id) on delete cascade,
  bib        integer not null,
  fields     jsonb not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  attempts   integer not null default 0,
  last_error text
);
create index if not exists checkin_outbox_open on public.checkin_outbox (event_id, id) where sent_at is null;

-- Tablet slots, shared by all events: one iPad per name ("Tablet 1", "Tablet 1_1", ...).
create table if not exists public.checkin_devices (
  id      text primary key,
  name    text not null,
  holder  text,
  seen_at timestamptz,
  kicked  text
);

create table if not exists public.checkin_secret (
  id       boolean primary key default true check (id),
  pin_hash text,                                  -- bcrypt, checked in checkin-admin only
  cron_key text default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')  -- lets pg_cron start checkin-sync
);
alter table public.checkin_secret add column if not exists cron_key text;
update public.checkin_secret set cron_key = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where cron_key is null;
insert into public.checkin_secret (id) values (true) on conflict do nothing;

-- ---------- actions (each one transaction, always on the active event) ----------
create or replace function public.checkin_ev() returns text
language plpgsql stable security definer set search_path = public as $$
declare e text;
begin
  if not checkin_staff() then raise exception 'Not allowed'; end if;
  select id into e from checkin_events where active;
  if e is null then raise exception 'No active event. The RBP admin picks one in Settings.'; end if;
  return e;
end $$;

create or replace function public.checkin_claim_device(p_id text, p_name text, p_holder text, p_fresh boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare d public.checkin_devices;
begin
  if not checkin_staff() then raise exception 'Not allowed'; end if;
  select * into d from checkin_devices where id = p_id for update;
  if found and not p_fresh and d.kicked = p_holder then return 'kicked'; end if;
  if found and d.holder is not null and d.holder <> p_holder and d.seen_at > now() - interval '45 seconds' then
    return 'busy';
  end if;
  insert into checkin_devices (id, name, holder, seen_at, kicked) values (p_id, p_name, p_holder, now(), null)
  on conflict (id) do update set name = excluded.name, holder = excluded.holder, seen_at = now(),
    kicked = case when p_fresh then null else checkin_devices.kicked end;
  return 'ok';
end $$;

create or replace function public.checkin_release_device(p_id text, p_holder text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not checkin_staff() then raise exception 'Not allowed'; end if;
  update checkin_devices set holder = null, seen_at = null where id = p_id and holder = p_holder;
end $$;

-- Bib pickup: the signature is already in Storage at p_path. Returns the RR14 signature link.
create or replace function public.checkin_collect(
  p_collector integer, p_bibs integer[], p_sig_id text, p_path text, p_link_base text,
  p_device text, p_scope text, p_qv jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(); b integer; tok text; url text; taken integer[]; t text;
begin
  select array_agg(bib order by bib) into taken from checkin_participants
    where event_id = ev and bib = any(p_bibs) and sig_time is not null;
  if taken is not null then raise exception 'Already collected: #%', array_to_string(taken, ', #'); end if;
  insert into checkin_signatures (id, event_id, collector, bibs, path, device)
    values (p_sig_id, ev, p_collector, p_bibs, p_path, p_device) returning token into tok;
  url := p_link_base || '?id=' || p_sig_id || '&t=' || tok;
  t := to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
  foreach b in array p_bibs loop
    update checkin_participants set sig_id = p_sig_id, sig_time = now(), sig_url = url,
      pickup_scope = p_scope, collected_by = p_collector, checkin_device = p_device,
      qatari_verified = coalesce(p_qv->>b::text, 'No'), updated_at = now()
    where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, jsonb_build_object(
      'sigUrl', url, 'sigTime', t, 'scope', p_scope, 'by', p_collector::text,
      'desk', p_device, 'qv', coalesce(p_qv->>b::text, 'No')));
  end loop;
  if p_scope = 'TEAM' then
    insert into checkin_outbox (event_id, bib, fields) values (ev, p_collector,
      jsonb_build_object('forList', array_to_string(p_bibs, ',')));
  end if;
  return url;
end $$;

create or replace function public.checkin_undo(p_sig_id text)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(); b integer; c integer;
begin
  if exists (select 1 from checkin_participants where event_id = ev and sig_id = p_sig_id and package_issued) then
    raise exception 'Package already issued';
  end if;
  select collector into c from checkin_signatures where id = p_sig_id and event_id = ev;
  for b in select bib from checkin_participants where event_id = ev and sig_id = p_sig_id loop
    update checkin_participants set sig_id = null, sig_time = null, sig_url = null, pickup_scope = null,
      collected_by = null, checkin_device = null, qatari_verified = null, updated_at = now()
    where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, jsonb_build_object(
      'sigUrl', '', 'sigTime', '', 'scope', '', 'by', '', 'desk', '', 'qv', ''));
  end loop;
  if c is not null then insert into checkin_outbox (event_id, bib, fields) values (ev, c, jsonb_build_object('forList', '')); end if;
end $$;

create or replace function public.checkin_issue(p_sig_id text, p_on boolean, p_device text)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(); b integer; t text := to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
begin
  for b in select bib from checkin_participants where event_id = ev and sig_id = p_sig_id loop
    update checkin_participants set package_issued = p_on, package_time = case when p_on then now() end,
      package_device = case when p_on then p_device end, updated_at = now() where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, jsonb_build_object(
      'merch', case when p_on then '1' else '0' end,
      'merchTime', case when p_on then t else '' end,
      'merchDesk', case when p_on then p_device else '' end));
  end loop;
end $$;

create or replace function public.checkin_edit(p_bib integer, p_fields jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(); k text; out jsonb := '{}'::jsonb;
begin
  for k in select jsonb_object_keys(p_fields) loop
    if k not in ('dob','nat','qid','ice','icePhone','email','phone') then raise exception 'Field % cannot be edited', k; end if;
    out := out || jsonb_build_object(k, coalesce(p_fields->>k, ''));
  end loop;
  update checkin_participants set
    dob       = case when out ? 'dob' then nullif(out->>'dob','')::date else dob end,
    nation    = case when out ? 'nat' then upper(out->>'nat') else nation end,
    qid       = case when out ? 'qid' then out->>'qid' else qid end,
    ice_name  = case when out ? 'ice' then out->>'ice' else ice_name end,
    ice_phone = case when out ? 'icePhone' then out->>'icePhone' else ice_phone end,
    email     = case when out ? 'email' then out->>'email' else email end,
    phone     = case when out ? 'phone' then out->>'phone' else phone end,
    updated_at = now()
  where event_id = ev and bib = p_bib;
  if not found then raise exception 'No participant #%', p_bib; end if;
  if out <> '{}'::jsonb then insert into checkin_outbox (event_id, bib, fields) values (ev, p_bib, out); end if;
end $$;

revoke execute on function public.checkin_active, public.checkin_ev, public.checkin_claim_device, public.checkin_release_device,
  public.checkin_collect, public.checkin_undo, public.checkin_issue, public.checkin_edit from public, anon;
grant execute on function public.checkin_ev, public.checkin_claim_device, public.checkin_release_device,
  public.checkin_collect, public.checkin_undo, public.checkin_issue, public.checkin_edit to authenticated;

-- ---------- table access (works whether or not "Grant API access to new tables" is on) ----------
grant usage on schema public to authenticated, service_role;
grant all on public.checkin_events, public.checkin_event_rr, public.checkin_participants, public.checkin_signatures,
  public.checkin_outbox, public.checkin_devices, public.checkin_secret to service_role;
grant usage, select on all sequences in schema public to service_role;
grant select on public.checkin_events, public.checkin_participants, public.checkin_signatures,
  public.checkin_outbox, public.checkin_devices to authenticated;
revoke all on public.checkin_events, public.checkin_event_rr, public.checkin_participants, public.checkin_signatures,
  public.checkin_outbox, public.checkin_devices, public.checkin_secret from anon;
revoke all on public.checkin_event_rr, public.checkin_secret from authenticated;

-- ---------- row level security: staff read, writes only through the functions ----------
alter table public.checkin_events       enable row level security;
alter table public.checkin_event_rr     enable row level security;   -- no policies: functions only
alter table public.checkin_participants enable row level security;
alter table public.checkin_signatures   enable row level security;
alter table public.checkin_outbox       enable row level security;
alter table public.checkin_devices      enable row level security;
alter table public.checkin_secret       enable row level security;   -- no policies: functions only

drop policy if exists "checkin staff read" on public.checkin_events;
create policy "checkin staff read" on public.checkin_events for select to authenticated using (checkin_staff());
drop policy if exists "checkin staff read" on public.checkin_participants;
create policy "checkin staff read" on public.checkin_participants for select to authenticated using (checkin_staff());
drop policy if exists "checkin staff read" on public.checkin_signatures;
create policy "checkin staff read" on public.checkin_signatures for select to authenticated using (checkin_staff());
drop policy if exists "checkin staff read" on public.checkin_outbox;
create policy "checkin staff read" on public.checkin_outbox for select to authenticated using (checkin_staff());
drop policy if exists "checkin staff read" on public.checkin_devices;
create policy "checkin staff read" on public.checkin_devices for select to authenticated using (checkin_staff());

-- ---------- live updates ----------
do $$
declare t text;
begin
  foreach t in array array['checkin_participants','checkin_devices','checkin_events'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then raise notice 'Realtime %: %', t, sqlerrm;
    end;
  end loop;
end $$;

-- ---------- signature files: private bucket ----------
insert into storage.buckets (id, name, public) values ('checkin-signatures', 'checkin-signatures', false)
on conflict (id) do nothing;
drop policy if exists "checkin staff upload signatures" on storage.objects;
create policy "checkin staff upload signatures" on storage.objects for insert to authenticated
  with check (bucket_id = 'checkin-signatures' and public.checkin_staff());
drop policy if exists "checkin staff read signatures" on storage.objects;
create policy "checkin staff read signatures" on storage.objects for select to authenticated
  using (bucket_id = 'checkin-signatures' and public.checkin_staff());
