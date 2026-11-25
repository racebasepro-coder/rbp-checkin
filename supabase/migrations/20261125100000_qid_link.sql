-- QID photos get a private link for RR14 (field QIDPhoto), like the signature link.
alter table checkin_qid_docs add column if not exists token text;
alter table checkin_qid_docs add column if not exists both_path text; -- front above back, one JPEG

create or replace function public.checkin_change(p_event text, p_bib integer, p_fields jsonb, p_device text)
returns void language plpgsql security definer set search_path = public as $$
declare o checkin_participants; f jsonb := '{}'::jsonb; k text; d date;
begin
  select * into o from checkin_participants where event_id = p_event and bib = p_bib for update;
  if o.bib is null then raise exception 'Bib not found'; end if;
  for k in select jsonb_object_keys(p_fields) loop
    if k not in ('first','last','sex','nat','dob','qid','email','phone','ice','icePhone','size','qidUrl') then
      raise exception 'Field % cannot be changed', k; end if;
    f := f || jsonb_build_object(k, coalesce(p_fields->>k, ''));
  end loop;
  if f ? 'dob' and f->>'dob' <> '' then d := (f->>'dob')::date; end if;
  update checkin_participants set
    first_name = case when f ? 'first' then f->>'first' else first_name end,
    last_name = case when f ? 'last' then f->>'last' else last_name end,
    sex = case when f ? 'sex' then nullif(f->>'sex', '') else sex end,
    nation = case when f ? 'nat' then upper(f->>'nat') else nation end,
    dob = case when f ? 'dob' then d else dob end,
    yob = case when f ? 'dob' then extract(year from d)::int else yob end,
    qid = case when f ? 'qid' then f->>'qid' else qid end,
    email = case when f ? 'email' then f->>'email' else email end,
    phone = case when f ? 'phone' then f->>'phone' else phone end,
    ice_name = case when f ? 'ice' then f->>'ice' else ice_name end,
    ice_phone = case when f ? 'icePhone' then f->>'icePhone' else ice_phone end,
    shirt_size = case when f ? 'size' then upper(f->>'size') else shirt_size end,
    updated_at = now()
  where event_id = p_event and bib = p_bib;
  -- RR14: gender as m/f, the rest as typed.
  if f ? 'sex' then f := f || jsonb_build_object('sex', case f->>'sex' when 'W' then 'f' when 'M' then 'm' else '' end); end if;
  if f ? 'nat' then f := f || jsonb_build_object('nat', upper(f->>'nat')); end if;
  if f ? 'size' then f := f || jsonb_build_object('size', upper(f->>'size')); end if;
  insert into checkin_outbox (event_id, bib, fields) values (p_event, p_bib, f);
  insert into checkin_changes (event_id, bib, old, new, device) values (p_event, p_bib,
    jsonb_build_object('first', o.first_name, 'last', o.last_name, 'sex', o.sex, 'nat', o.nation, 'dob', o.dob, 'qid', o.qid,
      'email', o.email, 'phone', o.phone, 'ice', o.ice_name, 'icePhone', o.ice_phone, 'size', o.shirt_size), p_fields, p_device);
end $$;
revoke execute on function public.checkin_change(text, integer, jsonb, text) from public, anon, authenticated;
grant execute on function public.checkin_change(text, integer, jsonb, text) to service_role;
