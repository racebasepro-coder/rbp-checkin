-- QID photos (front and back) taken in the Swap tab, with what OCR read. Photos live in the private
-- checkin-signatures bucket under <event>/qid/...; only signed-in staff can read them.
create table if not exists checkin_qid_docs (
  id bigserial primary key, event_id text not null, bib integer not null,
  front_path text, back_path text, ocr jsonb not null default '{}', device text,
  created_at timestamptz not null default now());
alter table checkin_qid_docs enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'checkin_qid_docs' and policyname = 'staff read qid docs') then
    create policy "staff read qid docs" on checkin_qid_docs for select to authenticated using (checkin_staff());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'checkin_qid_docs' and policyname = 'staff add qid docs') then
    create policy "staff add qid docs" on checkin_qid_docs for insert to authenticated with check (checkin_staff());
  end if;
end $$;
grant select, insert on checkin_qid_docs to authenticated;
grant usage on sequence checkin_qid_docs_id_seq to authenticated;
