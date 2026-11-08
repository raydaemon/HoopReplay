-- Replay videos are served through short-lived signed URLs instead of a public bucket, and the
-- generation count per game is recorded so a failing game cannot be retried without limit.

update storage.buckets set public = false where id = 'replay-videos';

alter table public.replay_videos add column if not exists attempts integer not null default 1;
