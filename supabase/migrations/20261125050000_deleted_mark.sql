-- A removed or undone check-in clears Signature, SignatureTime and CollectedBy in RR14
-- and writes "Deleted <time>" to CheckinDeleted. A new pickup clears that mark.
create or replace function public.checkin_collect(p_event text, p_collector integer, p_bibs integer[], p_sig_id text, p_path text, p_link_base text, p_device text, p_scope text, p_qv jsonb)
 returns text language plpgsql security definer set search_path to 'public' as $function$
declare ev text := checkin_ev(p_event); b integer; tok text; url text; taken integer[]; t text; who text;
begin
  select array_agg(bib order by bib) into taken from checkin_participants
    where event_id = ev and bib = any(p_bibs) and sig_time is not null;
  if taken is not null then raise exception 'Already collected: #%', array_to_string(taken, ', #'); end if;
  insert into checkin_signatures (id, event_id, collector, bibs, path, device)
    values (p_sig_id, ev, p_collector, p_bibs, p_path, p_device) returning token into tok;
  url := p_link_base || '?id=' || p_sig_id || '&t=' || tok;
  t := to_char(now() at time zone 'Asia/Qatar', 'YYYY-MM-DD HH24:MI:SS');
  select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') into who
    from checkin_participants where event_id = ev and bib = p_collector;
  who := coalesce(who, '#' || p_collector);
  foreach b in array p_bibs loop
    update checkin_participants set sig_id = p_sig_id, sig_time = now(), sig_url = url,
      pickup_scope = p_scope, collected_by = p_collector, checkin_device = p_device,
      qatari_verified = coalesce(p_qv->>b::text, 'No'), updated_at = now()
    where event_id = ev and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (ev, b, jsonb_build_object(
      'sigUrl', url, 'sigTime', t, 'scope', p_scope, 'by', who,
      'desk', p_device, 'qv', coalesce(p_qv->>b::text, 'No'), 'deleted', ''));
  end loop;
  if p_scope = 'TEAM' then
    insert into checkin_outbox (event_id, bib, fields) values (ev, p_collector,
      jsonb_build_object('forList', array_to_string(p_bibs, ',')));
  end if;
  return url;
end $function$;

create or replace function public.checkin_admin_remove(p_event text, p_sig_id text, p_bib integer default null)
returns integer language plpgsql security definer set search_path = public as $$
declare b integer; c integer; n integer := 0; rest integer[];
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
    n := n + 1;
  end loop;
  if c is not null then
    select array_agg(bib order by bib) into rest from checkin_participants where event_id = p_event and sig_id = p_sig_id;
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
  if c is not null then insert into checkin_outbox (event_id, bib, fields) values (ev, c, jsonb_build_object('forList', '')); end if;
end $$;
