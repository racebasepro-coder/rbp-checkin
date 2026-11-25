-- Year of birth from RR14 (its list may only carry YoB).
alter table checkin_participants add column if not exists yob integer;
