-- Give every event in one substitution batch the same created_at.
--
-- Before the clients stamped a whole commit with a single timestamp, each event in a
-- multi-player substitution got its own clock reading, so the Sub out / Sub in rows of one
-- batch differed by a few milliseconds and the play-by-play could not pair them.
-- A batch is: same user, sync space, game, team, period and clock, with consecutive (by
-- local_id) SUB_OUT / SUB_IN events whose created_at differ by at most 5 seconds. Every event
-- in a batch takes the batch's earliest created_at.

with ordered as (
  select user_id, sync_space, game_id, team_id, period, game_clock_ms, local_id, created_at,
    case
      when created_at - lag(created_at) over (
        partition by user_id, sync_space, game_id, team_id, period, game_clock_ms
        order by local_id
      ) > 5000 then 1
      else 0
    end as starts_batch
  from public.events
  where type in ('SUB_OUT', 'SUB_IN')
), batched as (
  select *,
    sum(starts_batch) over (
      partition by user_id, sync_space, game_id, team_id, period, game_clock_ms
      order by local_id
      rows between unbounded preceding and current row
    ) as batch_no
  from ordered
), aligned as (
  select user_id, sync_space, local_id, created_at,
    min(created_at) over (
      partition by user_id, sync_space, game_id, team_id, period, game_clock_ms, batch_no
    ) as batch_created_at
  from batched
)
update public.events as event
set created_at = aligned.batch_created_at
from aligned
where event.user_id = aligned.user_id
  and event.sync_space = aligned.sync_space
  and event.local_id = aligned.local_id
  and event.created_at <> aligned.batch_created_at;
