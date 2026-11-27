-- Medals tab: finishers come from an RR14 finishers list (Bib, FinishTOD, Team Members), pulled every 10 s.
-- The link is kept with the other RR14 links (functions only). Medal state belongs to the app.
alter table checkin_event_rr add column if not exists finish_url text;

create table if not exists checkin_finishers (
  event_id text not null references checkin_events(id) on delete cascade,
  bib integer not null,
  finish_tod text not null default '',
  finish_sec double precision,
  members integer not null default 1,
  name text not null default '',
  team text not null default '',
  seen_at timestamptz not null default now(),
  gone_at timestamptz,
  medal_at timestamptz,
  medal_device text,
  updated_at timestamptz not null default now(),
  primary key (event_id, bib)
);
alter table checkin_finishers enable row level security;
revoke all on checkin_finishers from anon, authenticated;
grant select on checkin_finishers to authenticated;
grant all on checkin_finishers to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'checkin_finishers' and policyname = 'checkin staff read') then
    create policy "checkin staff read" on checkin_finishers for select to authenticated using (checkin_staff());
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'checkin_finishers') then
    alter publication supabase_realtime add table public.checkin_finishers;
  end if;
end $$;

create or replace function public.checkin_medal(p_event text, p_bib integer, p_device text, p_on boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(p_event);
begin
  update checkin_finishers set medal_at = case when p_on then coalesce(medal_at, now()) end,
    medal_device = case when p_on then coalesce(medal_device, p_device) end, updated_at = now()
    where event_id = ev and bib = p_bib;
  if not found then raise exception 'Bib % has not finished', p_bib; end if;
end $$;
revoke execute on function public.checkin_medal(text, integer, text, boolean) from public, anon;
grant execute on function public.checkin_medal(text, integer, text, boolean) to authenticated;
alter table checkin_event_rr add column if not exists finish_sync jsonb;
-- Finishers are pulled every 2 s, apart from the 30 s participant sync.
select cron.schedule('checkin-finish','2 seconds', $c$
      select net.http_post(
        url := 'https://pmkwyppjeoxhtravtutv.supabase.co/functions/v1/checkin-sync?mode=finish',
        headers := jsonb_build_object('Content-Type','application/json',
                     'x-cron-key', (select cron_key from public.checkin_secret limit 1)),
        body := '{}'::jsonb,
        timeout_milliseconds := 9000)
    $c$);
