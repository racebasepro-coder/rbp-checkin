-- Bibs that disappear from the RR14 list are marked gone (hidden in the app unless signed), never deleted.
alter table checkin_participants add column if not exists gone_at timestamptz;
