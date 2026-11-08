-- Player and team highlight videos (spec: docs/superpowers/specs/2026-10-04-video-highlights-design.md).
-- The mp4 files live in Cloudflare R2; this table only records them. Clients never touch it
-- directly: /api/highlights checks that the caller can see the game through accessible_games,
-- writes rows with the service role and hands out presigned R2 URLs.

create table if not exists public.highlight_videos (
  id uuid primary key default gen_random_uuid(),
  game_uuid text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- "player:<local player id>" or "team:<local team id>"; one highlight per target and source.
  target_key text not null check (target_key ~ '^(player|team):[0-9]+$'),
  target_label text not null,
  source text not null check (source in ('phone', 'cloud')),
  object_key text not null,
  duration_ms bigint not null default 0,
  clip_count integer not null default 0,
  created_at timestamptz not null default now(),
  unique (game_uuid, target_key, source)
);

create index if not exists highlight_videos_game_uuid_idx on public.highlight_videos (game_uuid);

alter table public.highlight_videos enable row level security;
revoke all on public.highlight_videos from anon, authenticated;

-- Whole-game recordings uploaded to R2 (phase 3): where each segment's file is and how far its upload got.
alter table public.segments add column if not exists object_key text;
alter table public.segments add column if not exists upload_status text not null default 'pending'
  check (upload_status in ('pending', 'uploading', 'uploaded', 'failed'));
