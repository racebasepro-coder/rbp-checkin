-- The signature log shows removed check-ins: deleted_at when the whole pickup is gone, removed = bibs taken out of it.
alter table checkin_signatures add column if not exists deleted_at timestamptz;
alter table checkin_signatures add column if not exists deleted_how text;
alter table checkin_signatures add column if not exists removed integer[] not null default '{}';

create or replace function public.checkin_admin_remove(p_event text, p_sig_id text, p_bib integer default null)
returns integer language plpgsql security definer set search_path = public as $$
declare b integer; c integer; n integer := 0; rest integer[]; gone integer[] := '{}';
  t text := 'Deleted ' || to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
begin
  select collector into c from checkin_signatures where id = p_sig_id and event_id = p_event;
  for b in select bib from checkin_participants where event_id = p_event and sig_id = p_sig_id and (p_bib is null or bib = p_bib) loop
    update checkin_participants set sig_id = null, sig_time = null, sig_url = null, pickup_scope = null,
      collected_by = null, checkin_device = null, qatari_verified = null,
      package_issued = false, package_time = null, package_device = null, updated_at = now()
    where event_id = p_event and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (p_event, b, jsonb_build_object(
      'sigUrl', '', 'sigTime', '', 'scope', '', 'by', '', 'desk', '', 'qv', '', 'merch', '0', 'merchTime', '', 'merchDesk', '', 'deleted', t));
    gone := gone || b; n := n + 1;
  end loop;
  select array_agg(bib order by bib) into rest from checkin_participants where event_id = p_event and sig_id = p_sig_id;
  update checkin_signatures set removed = (select array_agg(distinct x order by x) from unnest(removed || gone) x),
    deleted_at = case when rest is null then now() else deleted_at end,
    deleted_how = case when rest is null then 'admin' else deleted_how end
  where id = p_sig_id and event_id = p_event;
  if c is not null then
    insert into checkin_outbox (event_id, bib, fields) values (p_event, c,
      jsonb_build_object('forList', case when coalesce(array_length(rest, 1), 0) > 1 then array_to_string(rest, ',') else '' end));
  end if;
  return n;
end $$;
revoke execute on function public.checkin_admin_remove(text, text, integer) from public, anon, authenticated;
grant execute on function public.checkin_admin_remove(text, text, integer) to service_role;

create or replace function public.checkin_undo(p_event text, p_sig_id text)
returns void language plpgsql security definer set search_path = public as $$
declare ev text := checkin_ev(p_event); b integer; c integer;
  t text := 'Deleted ' || to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
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
      'sigUrl', '', 'sigTime', '', 'scope', '', 'by', '', 'desk', '', 'qv', '', 'deleted', t));
  end loop;
  update checkin_signatures set deleted_at = now(), deleted_how = 'undo' where id = p_sig_id and event_id = ev;
  if c is not null then insert into checkin_outbox (event_id, bib, fields) values (ev, c, jsonb_build_object('forList', '')); end if;
end $$;

-- Earlier removals (before this log existed): signatures whose bibs no longer point at them.
update checkin_signatures s set deleted_at = coalesce(s.deleted_at, now()), deleted_how = coalesce(s.deleted_how, 'earlier')
where s.deleted_at is null and not exists (select 1 from checkin_participants p where p.event_id = s.event_id and p.sig_id = s.id);
