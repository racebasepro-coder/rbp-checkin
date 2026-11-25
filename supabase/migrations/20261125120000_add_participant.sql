-- New tab: a new participant on a free bib (ranges set per event in Settings). Called only by checkin-admin
-- (action "add"), which checks the bib is inside this event's free ranges. Logged in checkin_changes (old = {}).
create or replace function public.checkin_add(p_event text, p_bib integer, p_fields jsonb, p_device text)
returns void language plpgsql security definer set search_path = public as $$
declare o checkin_participants; f jsonb := '{}'::jsonb; k text; d date;
begin
  for k in select jsonb_object_keys(p_fields) loop
    if k not in ('first','last','sex','nat','dob','qid','email','phone','ice','icePhone','size','qidUrl','contest') then
      raise exception 'Field % cannot be set', k; end if;
    f := f || jsonb_build_object(k, coalesce(p_fields->>k, ''));
  end loop;
  if coalesce(f->>'first', '') = '' and coalesce(f->>'last', '') = '' then raise exception 'Give the new person a name'; end if;
  select * into o from checkin_participants where event_id = p_event and bib = p_bib for update;
  -- A bib that left the RR14 list without a pickup may be given out again.
  if o.bib is not null and (o.gone_at is null or o.sig_id is not null) then raise exception 'Bib % is already taken', p_bib; end if;
  d := nullif(f->>'dob', '')::date;
  insert into checkin_participants as t (event_id, bib, first_name, last_name, team, sex, nation, dob, yob, age_group, shirt_size,
    qid, email, phone, ice_name, ice_phone, package_issued, gone_at, updated_at)
  values (p_event, p_bib, coalesce(f->>'first', ''), coalesce(f->>'last', ''), '', nullif(f->>'sex', ''), upper(coalesce(f->>'nat', '')),
    d, extract(year from d)::int, '', upper(coalesce(f->>'size', '')), coalesce(f->>'qid', ''), coalesce(f->>'email', ''),
    coalesce(f->>'phone', ''), coalesce(f->>'ice', ''), coalesce(f->>'icePhone', ''), false, null, now())
  on conflict (event_id, bib) do update set first_name = excluded.first_name, last_name = excluded.last_name, team = '',
    sex = excluded.sex, nation = excluded.nation, dob = excluded.dob, yob = excluded.yob, age_group = '', shirt_size = excluded.shirt_size,
    qid = excluded.qid, email = excluded.email, phone = excluded.phone, ice_name = excluded.ice_name, ice_phone = excluded.ice_phone,
    sig_id = null, sig_time = null, sig_url = null, pickup_scope = null, collected_by = null, checkin_device = null,
    qatari_verified = null, package_issued = false, package_time = null, package_device = null, gone_at = null, updated_at = now();
  -- RR14: gender as m/f, nation and size upper case, everything else as typed (plus Contest when the event sets one).
  if f ? 'sex' then f := f || jsonb_build_object('sex', case f->>'sex' when 'W' then 'f' when 'M' then 'm' else '' end); end if;
  if f ? 'nat' then f := f || jsonb_build_object('nat', upper(f->>'nat')); end if;
  if f ? 'size' then f := f || jsonb_build_object('size', upper(f->>'size')); end if;
  insert into checkin_outbox (event_id, bib, fields) values (p_event, p_bib, f);
  insert into checkin_changes (event_id, bib, old, new, device) values (p_event, p_bib, '{}'::jsonb, p_fields, p_device);
end $$;
revoke execute on function public.checkin_add(text, integer, jsonb, text) from public, anon, authenticated;
grant execute on function public.checkin_add(text, integer, jsonb, text) to service_role;
