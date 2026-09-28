-- PlaylistName:DagMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- DagMix v3
-- Uses the LMS schema exposed to DynamicPlaylists4 on this PiCore install.
-- LMS keeps rating/playcount/lastplayed in persist.db, but exposes
-- tracks_persistent on the active SQLite connection used by playlist SQL.
-- DagMix does not rely on PlaylistTrackMinDuration or PlaylistLimit token
-- replacement, because this LMS/DPL combination does not replace them
-- reliably inside the main query.
-- No Tempo dependency yet.
--
-- Sinterklaas schedule (local LMS time):
-- Dec 5 only: 33% Sinterklaas
-- All other days: 0% Sinterklaas
--
-- Christmas schedule (local LMS time):
-- Dec 1-9   : 30% Christmas
-- Dec 10-19 : 65% Christmas
-- Dec 20-26 : 100% Christmas
-- Dec 27-Nov 30: 0% Christmas
--
-- Normal mix target:
-- Hits 35.0%, Other 65.0%
-- Oldies, Party and Fout are no longer explicit target buckets here.
-- They can still occur naturally through rating weight, with extra cooldowns
-- for Oldies and Fout to avoid over-rotation.
--
-- IMPORTANT:
-- Custom Skip primary filter switching is intentional here.
-- Keep the normal defaultfilterset.cs.xml with Kerst 100%.
-- Create dagmix.cs.xml (lowercase, exactly as that filename) with the
-- same exclusions EXCEPT Kerst and Sinterklaas.
-- The playlist switches to dagmix.cs.xml while active and restores
-- defaultfilterset.cs.xml when it stops.
-- PlaylistStartAction1:cli:customskip setfilter dagmix.cs.xml
-- PlaylistStopAction1:cli:customskip setfilter defaultfilterset.cs.xml

with
settings as (
    select
        case
            when strftime('%m-%d', 'now', 'localtime') = '12-05' then 0.33
            else 0.00
        end as sinterklaas_share,
        case
            when strftime('%m-%d', 'now', 'localtime') between '12-01' and '12-09' then 0.30
            when strftime('%m-%d', 'now', 'localtime') between '12-10' and '12-19' then 0.65
            when strftime('%m-%d', 'now', 'localtime') between '12-20' and '12-26' then 1.00
            else 0.00
        end as christmas_share
),
genre_flags as (
    select
        gt.track,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kerst,') > 0 then 1 else 0 end) as is_christmas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',sinterklaas,') > 0 then 1 else 0 end) as is_sinterklaas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',hits,') > 0 then 1 else 0 end) as is_hit,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',oldies,') > 0 then 1 else 0 end) as is_oldies,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',party,') > 0 then 1 else 0 end) as is_party,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',fout,') > 0 then 1 else 0 end) as is_fout,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',live,') > 0 then 1 else 0 end) as is_live,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',karaoke,') > 0 then 1 else 0 end) as is_karaoke,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kinderliedjes,') > 0 then 1 else 0 end) as is_kinderliedjes,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kindermuziek,') > 0 then 1 else 0 end) as is_kindermuziek,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',live,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',karaoke,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kinderliedjes,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kindermuziek,') > 0 then 1 else 0 end) as is_permanent_exclusion
    from genre_track gt
    join genres g on g.id = gt.genre
    group by gt.track
),
base_eligible as (
    select
        t.id,
        coalesce(pa.name, '') as primary_artist,
        tp.lastPlayed as last_played,
        coalesce(tp.rating, 0) as rating,
        coalesce(tp.playCount, 0) as play_count,
        s.sinterklaas_share,
        s.christmas_share,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 then 1
            else 0
        end as is_sinterklaas,
        coalesce(gf.is_christmas, 0) as is_christmas,
        coalesce(gf.is_oldies, 0) as is_oldies,
        coalesce(gf.is_fout, 0) as is_fout,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 and s.sinterklaas_share > 0 then 'Sinterklaas'
            when coalesce(gf.is_christmas, 0) = 1 and s.christmas_share > 0 then 'Christmas'
            when coalesce(gf.is_hit, 0) = 1 then 'Hits'
            else 'Other'
        end as category,
        case
            when coalesce(tp.rating, 0) >= 100 then 2.10
            when coalesce(tp.rating, 0) >= 90  then 1.95
            when coalesce(tp.rating, 0) >= 80  then 1.80
            when coalesce(tp.rating, 0) >= 70  then 1.50
            when coalesce(tp.rating, 0) >= 60  then 0.45
            when coalesce(tp.rating, 0) >= 50  then 0.12
            when coalesce(tp.rating, 0) >= 40  then 0.03
            else 0.20
        end as rating_weight,
        case
            when coalesce(tp.playCount, 0) = 0 then 1.30
            when coalesce(tp.playCount, 0) <= 5 then 1.15
            when coalesce(tp.playCount, 0) <= 20 then 1.00
            when coalesce(tp.playCount, 0) <= 50 then 0.92
            when coalesce(tp.playCount, 0) <= 100 then 0.84
            else 0.75
        end as play_count_weight
    from tracks t
    left join tracks_persistent tp on tp.urlmd5 = t.urlmd5
    left join contributors pa on pa.id = t.primary_artist
    left join genre_flags gf on gf.track = t.id
    left join dynamicplaylist_history dph on dph.id = t.id and dph.client = 'PlaylistPlayer'
    cross join settings s
    where
        t.audio = 1
        and t.secs >= 90

        -- Respect stored star ratings, but keep unrated tracks eligible.
        and (tp.rating is null or tp.rating = 0 or tp.rating >= 40)

        -- Permanent Custom Skip exclusions are also excluded here so DPL
        -- does not spend selection attempts on tracks that will be skipped.
        and coalesce(gf.is_permanent_exclusion, 0) = 0

        -- Avoid repeating tracks already added to the active DagMix session.
        and dph.id is null

        -- Kerst is only eligible during the Christmas schedule.
        and (
            s.christmas_share > 0
            or coalesce(gf.is_christmas, 0) = 0
        )

        -- Sinterklaas is only eligible on Dec 5.
        and (
            s.sinterklaas_share > 0
            or coalesce(gf.is_sinterklaas, 0) = 0
        )

),
eligible as (
    select
        *,
        rating_weight * play_count_weight as selection_weight
    from base_eligible
    where
        case
            when is_sinterklaas = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
            when is_christmas = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
            when is_fout = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 15724800)
            when is_oldies = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 1209600)
            when category = 'Hits' then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 18000)
            else last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
        end
),
eligible_pool as (
    select *
    from eligible

    union all

    select
        *,
        rating_weight * play_count_weight as selection_weight
    from base_eligible
    where not exists (select 1 from eligible)
),
category_totals as (
    select
        category,
        sum(selection_weight) as total_selection_weight
    from eligible_pool
    group by category
),
category_targets as (
    select
        ct.category,
        ct.total_selection_weight,
        case ct.category
            when 'Sinterklaas' then s.sinterklaas_share
            when 'Christmas'   then s.christmas_share
            when 'Hits'        then max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.350
            else                    max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.650
        end as target_share
    from category_totals ct
    cross join settings s
),
share_context as (
    select
        coalesce(sum(target_share), 0.0) as active_target_share
    from category_targets
),
weighted as (
    select
        e.*,
        case
            when sc.active_target_share > 0 then ct.target_share / sc.active_target_share
            when e.category = 'Hits'   then 0.350
            else                            0.650
        end as category_share,
        ct.total_selection_weight
    from eligible_pool e
    join category_targets ct on ct.category = e.category
    cross join share_context sc
),
scored as (
    select
        id,
        primary_artist,
        (
            (((random() & 9223372036854775807) + 1.0) / 9223372036854775808.0)
            / nullif(category_share * selection_weight / nullif(total_selection_weight, 0), 0)
        ) as selection_score
    from weighted
    where category_share > 0
)
select
    id,
    primary_artist
from scored
where selection_score is not null
order by selection_score;
