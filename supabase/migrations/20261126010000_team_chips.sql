-- Chips tab (teams only): every team has one chip, TeamChipID from the RR14 list. The first member who comes
-- takes it; the time, the member's bib and the iPad are stored on every member of the team and sent to RR14.
alter table checkin_participants add column if not exists chip_id text not null default '';
alter table checkin_participants add column if not exists chip_time timestamptz;
alter table checkin_participants add column if not exists chip_by integer;
alter table checkin_participants add column if not exists chip_device text;

create or replace function public.checkin_chip(p_event text, p_bib integer, p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(p_event); p checkin_participants; f checkin_participants;
  t text := to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS'); b integer;
begin
  select * into p from checkin_participants where event_id = ev and bib = p_bib and gone_at is null;
  if p.bib is null then raise exception 'Bib % not found', p_bib; end if;
  if p.team = '' then raise exception 'Bib % is solo: chips are for teams only', p_bib; end if;
  perform 1 from checkin_participants where event_id = ev and team = p.team for update;
  select * into f from checkin_participants where event_id = ev and team = p.team and chip_time is not null
    order by chip_time limit 1;
  if f.bib is not null then
    return jsonb_build_object('already', true, 'by', f.chip_by, 'time', f.chip_time, 'device', f.chip_device);
  end if;
  for b in select bib from checkin_participants where event_id = ev and team = p.team and gone_at is null loop
    update checkin_participants set chip_time = now(), chip_by = p_bib, chip_device = p_device, updated_at = now()
      where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b,
      jsonb_build_object('chipTime', t, 'chipBy', p_bib::text, 'chipDesk', coalesce(p_device, '')));
  end loop;
  return jsonb_build_object('already', false, 'by', p_bib, 'time', now(), 'device', p_device);
end $$;

-- A chip given by mistake: clear it for the whole team (and in RR14).
create or replace function public.checkin_chip_undo(p_event text, p_bib integer)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(p_event); tm text; b integer;
begin
  select team into tm from checkin_participants where event_id = ev and bib = p_bib;
  if coalesce(tm, '') = '' then raise exception 'Bib % is not in a team', p_bib; end if;
  for b in select bib from checkin_participants where event_id = ev and team = tm and chip_time is not null loop
    update checkin_participants set chip_time = null, chip_by = null, chip_device = null, updated_at = now()
      where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, jsonb_build_object('chipTime', '', 'chipBy', '', 'chipDesk', ''));
  end loop;
end $$;
revoke execute on function public.checkin_chip(text, integer, text) from public, anon;
revoke execute on function public.checkin_chip_undo(text, integer) from public, anon;
grant execute on function public.checkin_chip(text, integer, text) to authenticated;
grant execute on function public.checkin_chip_undo(text, integer) to authenticated;
