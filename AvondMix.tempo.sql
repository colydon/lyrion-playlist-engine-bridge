-- PlaylistName:AvondMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- AvondMix
-- Rustiger profiel voor de avond.
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
-- Hits 4.0%, Oldies 16.0%, Other 80.0%
--
-- Additional AvondMix rules:
-- - no Party tracks
-- - no Fout tracks
-- - avoid TEMPO Fast and Very Fast
-- - prefer TEMPO Slow, with some Moderate and Very Slow still allowed

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
tempo_flags as (
    select
        cta.track,
        max(case when lower(trim(cta.value)) = 'very slow' then 1 else 0 end) as is_very_slow,
        max(case when lower(trim(cta.value)) = 'slow' then 1 else 0 end) as is_slow,
        max(case when lower(trim(cta.value)) = 'moderate' then 1 else 0 end) as is_moderate,
        max(case when lower(trim(cta.value)) = 'fast' then 1 else 0 end) as is_fast,
        max(case when lower(trim(cta.value)) = 'very fast' then 1 else 0 end) as is_very_fast
    from customtagimporter_track_attributes cta
    where lower(cta.attr) = 'tempo'
    group by cta.track
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
            when coalesce(tf.is_slow, 0) = 1 then 'Slow'
            when coalesce(tf.is_very_slow, 0) = 1 then 'Very Slow'
            when coalesce(tf.is_moderate, 0) = 1 then 'Moderate'
            when coalesce(tf.is_fast, 0) = 1 then 'Fast'
            when coalesce(tf.is_very_fast, 0) = 1 then 'Very Fast'
            else ''
        end as tempo_bucket,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 then 1
            else 0
        end as is_sinterklaas,
        coalesce(gf.is_christmas, 0) as is_christmas,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 and s.sinterklaas_share > 0 then 'Sinterklaas'
            when coalesce(gf.is_christmas, 0) = 1 and s.christmas_share > 0 then 'Christmas'
            when coalesce(gf.is_hit, 0) = 1 then 'Hits'
            when coalesce(gf.is_oldies, 0) = 1 then 'Oldies'
            else 'Other'
        end as category,
        case
            when coalesce(tp.rating, 0) >= 100 then 0.28
            when coalesce(tp.rating, 0) >= 90  then 0.40
            when coalesce(tp.rating, 0) >= 80  then 0.70
            when coalesce(tp.rating, 0) >= 70  then 1.45
            when coalesce(tp.rating, 0) >= 60  then 1.20
            when coalesce(tp.rating, 0) >= 50  then 1.00
            when coalesce(tp.rating, 0) >= 40  then 0.25
            else 0.40
        end as rating_weight,
        case
            when coalesce(tp.playCount, 0) = 0 then 1.30
            when coalesce(tp.playCount, 0) <= 5 then 1.15
            when coalesce(tp.playCount, 0) <= 20 then 1.00
            when coalesce(tp.playCount, 0) <= 50 then 0.92
            when coalesce(tp.playCount, 0) <= 100 then 0.84
            else 0.75
        end as play_count_weight,
        case
            when coalesce(tf.is_slow, 0) = 1 then 2.40
            when coalesce(tf.is_very_slow, 0) = 1 then 1.10
            when coalesce(tf.is_moderate, 0) = 1 then 0.70
            else 0.85
        end as tempo_weight
    from tracks t
    left join tracks_persistent tp on tp.urlmd5 = t.urlmd5
    left join contributors pa on pa.id = t.primary_artist
    left join genre_flags gf on gf.track = t.id
    left join tempo_flags tf on tf.track = t.id
    left join dynamicplaylist_history dph on dph.id = t.id and dph.client = 'PlaylistPlayer'
    cross join settings s
    where
        t.audio = 1
        and t.secs >= 90
        and (tp.rating is null or tp.rating = 0 or tp.rating >= 40)
        and coalesce(gf.is_permanent_exclusion, 0) = 0
        and dph.id is null
        and coalesce(gf.is_party, 0) = 0
        and coalesce(gf.is_fout, 0) = 0
        and coalesce(tf.is_fast, 0) = 0
        and coalesce(tf.is_very_fast, 0) = 0
        and (
            s.christmas_share > 0
            or coalesce(gf.is_christmas, 0) = 0
        )
        and (
            s.sinterklaas_share > 0
            or coalesce(gf.is_sinterklaas, 0) = 0
        )
),
eligible as (
    select
        *,
        rating_weight * play_count_weight * tempo_weight as selection_weight
    from base_eligible
    where
        case
            when is_sinterklaas = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
            when is_christmas = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
            when category = 'Hits' then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 18000)
            when category = 'Oldies' then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 1209600)
            else last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
        end
),
eligible_pool as (
    select *
    from eligible

    union all

    select
        *,
        rating_weight * play_count_weight * tempo_weight as selection_weight
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
            when 'Hits'        then max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.040
            when 'Oldies'      then max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.160
            else                    max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.800
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
            when e.category = 'Hits'   then 0.040
            when e.category = 'Oldies' then 0.160
            else                            0.800
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