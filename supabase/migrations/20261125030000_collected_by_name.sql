-- RR14 CollectedBy gets the collector's name instead of the bib number.
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
      'desk', p_device, 'qv', coalesce(p_qv->>b::text, 'No')));
  end loop;
  if p_scope = 'TEAM' then
    insert into checkin_outbox (event_id, bib, fields) values (ev, p_collector,
      jsonb_build_object('forList', array_to_string(p_bibs, ',')));
  end if;
  return url;
end $function$;
