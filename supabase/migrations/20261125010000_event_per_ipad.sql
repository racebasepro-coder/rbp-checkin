-- Each iPad picks its own event among the open ones. Several events can be open at the same time.
-- Applied to "Race Check IN" on 2026-11-25. See the Supabase migration history for the full function bodies.
alter table public.checkin_events add column if not exists open boolean not null default true;
-- checkin_ev(p_event), checkin_collect(p_event, ...), checkin_undo(p_event, ...), checkin_issue(p_event, ...),
-- checkin_edit(p_event, ...): same as before, but on the event the iPad passes (it must be open).
