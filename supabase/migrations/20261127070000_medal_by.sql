alter table checkin_finishers add column if not exists medal_by integer;
-- The older 4-argument checkin_medal stays in place (unused); the app always calls this 5-argument one.
-- Medals handed over (or taken back). For a team the operator picks the member who takes them (p_by).
-- RR14 gets MedalTime, MedalBib, MedalDevice on every member of the team (or on the solo bib).
create or replace function public.checkin_medal(p_event text, p_bib integer, p_device text, p_on boolean, p_by integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(p_event); f checkin_finishers; tm text; b integer;
  t text := to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
begin
  select * into f from checkin_finishers where event_id = ev and bib = p_bib for update;
  if f.bib is null then raise exception 'Bib % has not finished', p_bib; end if;
  if p_on and f.medal_at is not null then
    return jsonb_build_object('already', true, 'by', f.medal_by, 'time', f.medal_at, 'device', f.medal_device);
  end if;
  select coalesce(nullif(team, ''), nullif(f.team, '')) into tm from checkin_participants where event_id = ev and bib = p_bib;
  if tm is null then tm := nullif(f.team, ''); end if;
  if p_on and tm is not null and p_by is null then raise exception 'Pick the team member who takes the medals'; end if;
  update checkin_finishers set medal_at = case when p_on then now() end, medal_device = case when p_on then p_device end,
    medal_by = case when p_on then coalesce(p_by, p_bib) end, updated_at = now()
    where event_id = ev and bib = p_bib;
  for b in select bib from checkin_participants where event_id = ev and gone_at is null
      and (bib = p_bib or (tm is not null and team = tm)) loop
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, case when p_on
      then jsonb_build_object('MedalTime', t, 'MedalBib', coalesce(p_by, p_bib)::text, 'MedalDevice', coalesce(p_device, ''))
      else jsonb_build_object('MedalTime', '', 'MedalBib', '', 'MedalDevice', '') end);
  end loop;
  return jsonb_build_object('already', false, 'by', coalesce(p_by, p_bib), 'time', now(), 'device', p_device);
end $$;
revoke execute on function public.checkin_medal(text, integer, text, boolean, integer) from public, anon;
grant execute on function public.checkin_medal(text, integer, text, boolean, integer) to authenticated;
