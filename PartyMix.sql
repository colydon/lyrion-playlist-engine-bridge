-- PlaylistName:PartyMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- PartyMix v1
-- Extra playlist naast DagMix / AvondMix / DagAvondMix / SummerMix.
-- Die playlists blijven ongewijzigd; PartyMix is puur een aanvulling voor een
-- feestje, of als opzwepende achtergrond tijdens het werk.
--
-- Doel:
-- - Vooral nummers met het genre Party (doel 80%).
-- - Af en toe een hit (doel 20%), maar alleen als die ook echt energiek is:
--   TEMPO Fast of Very Fast, of een hoge BPM vanaf 122 zolang het nummer niet
--   als Slow/Very Slow staat getagd. Die BPM-grens geldt ook als er geen
--   TEMPO-tag aanwezig is.
-- - Rating blijft bepalend: hogere rating wordt duidelijk vaker afgespeeld.
-- - Een milde tempo-weging duwt richting fast/very fast en dempt slow, maar
--   weegt nooit zwaarder dan een ratingverschil.
--
-- Altijd uitgesloten:
-- - Kerst en Sinterklaas (PartyMix is niet seizoensgebonden).
-- - Live, Karaoke, Kinderliedjes en Kindermuziek (permanente exclusions).
-- - Alles onder 2 sterren.
--
-- Cooldown:
-- Hits 5 uur, Party 24 uur, Oldies 14 dagen, Fout 182 dagen.
--
-- PartyMix heeft geen seizoens- en geen dag/avondlogica: het is altijd
-- hetzelfde opzwepende profiel.

with
genre_flags as (
    select
        gt.track,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',party,') > 0 then 1 else 0 end) as is_party,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',hits,') > 0 then 1 else 0 end) as is_hit,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kerst,') > 0 then 1 else 0 end) as is_christmas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',sinterklaas,') > 0 then 1 else 0 end) as is_sinterklaas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',oldies,') > 0 then 1 else 0 end) as is_oldies,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',fout,') > 0 then 1 else 0 end) as is_fout,
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
        coalesce(gf.is_oldies, 0) as is_oldies,
        coalesce(gf.is_fout, 0) as is_fout,
        case
            when coalesce(gf.is_party, 0) = 1 then 'Party'
            else 'Hits'
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
        end as play_count_weight,
        case
            when coalesce(tf.is_very_fast, 0) = 1 then 1.30
            when coalesce(tf.is_fast, 0) = 1 then 1.25
            when coalesce(tf.is_moderate, 0) = 1 then 1.00
            when coalesce(tf.is_slow, 0) = 1 then 0.70
            when coalesce(tf.is_very_slow, 0) = 1 then 0.45
            when coalesce(t.bpm, 0) >= 125 then 1.20
            when coalesce(t.bpm, 0) between 115 and 124 then 1.05
            when coalesce(t.bpm, 0) between 100 and 114 then 0.95
            when coalesce(t.bpm, 0) between 1 and 99 then 0.70
            else 1.00
        end as tempo_weight
    from tracks t
    left join tracks_persistent tp on tp.urlmd5 = t.urlmd5
    left join contributors pa on pa.id = t.primary_artist
    left join genre_flags gf on gf.track = t.id
    left join tempo_flags tf on tf.track = t.id
    left join dynamicplaylist_history dph on dph.id = t.id and dph.client = 'PlaylistPlayer'
    where
        t.audio = 1
        and t.secs >= 90

        -- Automatisch afspelen vereist een rating van minimaal 2 sterren.
        and tp.rating >= 40

        -- Live, Karaoke, Kinderliedjes en Kindermuziek vallen altijd af.
        and coalesce(gf.is_permanent_exclusion, 0) = 0

        -- PartyMix is niet seizoensgebonden: nooit Kerst of Sinterklaas.
        and coalesce(gf.is_christmas, 0) = 0
        and coalesce(gf.is_sinterklaas, 0) = 0

        -- Voorkom herhaling van nummers die al in de actieve sessie zitten.
        and dph.id is null

        -- Alleen Party, of een hit die aantoonbaar energiek is.
        and (
            coalesce(gf.is_party, 0) = 1
            or (
                coalesce(gf.is_hit, 0) = 1
                and (
                    coalesce(tf.is_fast, 0) = 1
                    or coalesce(tf.is_very_fast, 0) = 1
                    or (
                        coalesce(t.bpm, 0) >= 122
                        and coalesce(tf.is_slow, 0) = 0
                        and coalesce(tf.is_very_slow, 0) = 0
                    )
                )
            )
        )
),
eligible as (
    select
        *,
        rating_weight * play_count_weight * tempo_weight as selection_weight
    from base_eligible
    where
        case
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
            when 'Party' then 0.800
            else              0.200
        end as target_share
    from category_totals ct
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
            when e.category = 'Party' then 0.800
            else                          0.200
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
