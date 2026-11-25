-- RBP admin removes a wrong check-in (also after the package was issued). Called only by checkin-admin (service role).
-- p_bib null: the whole pickup; otherwise only that bib leaves the pickup.
create or replace function public.checkin_admin_remove(p_event text, p_sig_id text, p_bib integer default null)
returns integer language plpgsql security definer set search_path = public as $$
declare b integer; c integer; n integer := 0; rest integer[];
begin
  select collector into c from checkin_signatures where id = p_sig_id and event_id = p_event;
  for b in select bib from checkin_participants where event_id = p_event and sig_id = p_sig_id and (p_bib is null or bib = p_bib) loop
    update checkin_participants set sig_id = null, sig_time = null, sig_url = null, pickup_scope = null,
      collected_by = null, checkin_device = null, qatari_verified = null,
      package_issued = false, package_time = null, package_device = null, updated_at = now()
    where event_id = p_event and bib = b;
    insert into checkin_outbox (event_id, bib, fields) values (p_event, b, jsonb_build_object(
      'sigUrl', '', 'sigTime', '', 'scope', '', 'by', '', 'desk', '', 'qv', '', 'merch', '0', 'merchTime', '', 'merchDesk', ''));
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
