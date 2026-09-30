-- PlaylistName:SummerMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- SummerMix v1
-- Extra playlist naast de bestaande DagMix / AvondMix / DagAvondMix.
-- Die bestaande playlists blijven volledig ongewijzigd; deze mix is puur een
-- aanvulling die alleen gestart wordt wanneer Homey daar expliciet om vraagt
-- (bijvoorbeeld op een warme dag).
--
-- Doel:
-- - 50% van de nummers komt uit de genres Summer en Lounge samen.
--   Lounge bevat nog maar weinig tracks, daarom telt die mee in hetzelfde
--   zomerblok en krijgt een verse track (weinig playcount) extra gewicht.
-- - Hits 25% en de rest (Other) 25%; beide spelen daardoor minder vaak dan in
--   DagMix (dat 35% hits en 65% overig gebruikt).
-- - Overdag: hetzelfde karakter als DagMix, maar dan met de zomerbias.
-- - Avond (lokaal 18:00-07:00): rustiger. Geen TEMPO Fast of Very Fast meer en
--   een lagere BPM-voorkeur, terwijl Summer/Lounge net zo belangrijk blijven.
--
-- De dag/avond-keuze gebeurt volledig in deze SQL op basis van de lokale tijd,
-- dus de engine heeft geen routing-windows en geen extra Python-code nodig.
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
-- Normal mix target (buiten het seizoen):
-- Summer+Lounge 50.0%, Hits 25.0%, Other 25.0%
--
-- Cooldown:
-- Hits 5 uur, Summer/Lounge 12 uur, Oldies 14 dagen, Fout 182 dagen,
-- Sinterklaas/Kerst/Other 24 uur.

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
        end as christmas_share,
        case
            when cast(strftime('%H', 'now', 'localtime') as integer) >= 18
              or cast(strftime('%H', 'now', 'localtime') as integer) < 7 then 1
            else 0
        end as is_evening
),
genre_flags as (
    select
        gt.track,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kerst,') > 0 then 1 else 0 end) as is_christmas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',sinterklaas,') > 0 then 1 else 0 end) as is_sinterklaas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',hits,') > 0 then 1 else 0 end) as is_hit,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',oldies,') > 0 then 1 else 0 end) as is_oldies,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',fout,') > 0 then 1 else 0 end) as is_fout,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',summer,') > 0 then 1 else 0 end) as is_summer,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',zomer,') > 0 then 1 else 0 end) as is_zomer,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',lounge,') > 0 then 1 else 0 end) as is_lounge,
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
        s.is_evening,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 then 1
            else 0
        end as is_sinterklaas,
        coalesce(gf.is_christmas, 0) as is_christmas,
        coalesce(gf.is_oldies, 0) as is_oldies,
        coalesce(gf.is_fout, 0) as is_fout,
        case
            when coalesce(gf.is_summer, 0) = 1
              or coalesce(gf.is_zomer, 0) = 1
              or coalesce(gf.is_lounge, 0) = 1 then 1
            else 0
        end as is_summer,
        case
            when coalesce(gf.is_sinterklaas, 0) = 1 and s.sinterklaas_share > 0 then 'Sinterklaas'
            when coalesce(gf.is_christmas, 0) = 1 and s.christmas_share > 0 then 'Christmas'
            when coalesce(gf.is_summer, 0) = 1 or coalesce(gf.is_zomer, 0) = 1 or coalesce(gf.is_lounge, 0) = 1 then 'Summer'
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
        end as play_count_weight,
        case
            when s.is_evening = 0 then 1.00
            when coalesce(tf.is_slow, 0) = 1 then 1.80
            when coalesce(tf.is_very_slow, 0) = 1 then 1.00
            when coalesce(tf.is_moderate, 0) = 1 then 1.00
            when coalesce(tf.is_fast, 0) = 1 then 0.05
            when coalesce(tf.is_very_fast, 0) = 1 then 0.02
            when coalesce(t.bpm, 0) between 1 and 84 then 1.45
            when coalesce(t.bpm, 0) between 85 and 99 then 1.25
            when coalesce(t.bpm, 0) between 100 and 112 then 1.00
            when coalesce(t.bpm, 0) between 113 and 124 then 0.70
            when coalesce(t.bpm, 0) >= 125 then 0.35
            else 0.90
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

        -- Automatisch afspelen vereist een rating van minimaal 2 sterren.
        and tp.rating >= 40

        -- Permanente Custom Skip-uitsluitingen ook hier weren, zodat er geen
        -- selectiepogingen verloren gaan aan nummers die toch geskipt worden.
        and coalesce(gf.is_permanent_exclusion, 0) = 0

        -- Very Fast valt altijd af. In de avond vallen ook Fast en nummers
        -- zonder TEMPO-tag met een hoge BPM af.
        and coalesce(tf.is_very_fast, 0) = 0
        and (s.is_evening = 0 or coalesce(tf.is_fast, 0) = 0)
        and (
            s.is_evening = 0
            or coalesce(tf.is_slow, 0) = 1
            or coalesce(tf.is_very_slow, 0) = 1
            or coalesce(tf.is_moderate, 0) = 1
            or coalesce(tf.is_fast, 0) = 1
            or coalesce(tf.is_very_fast, 0) = 1
            or coalesce(t.bpm, 0) < 135
        )

        -- Voorkom herhaling van nummers die al in de actieve sessie zitten.
        and dph.id is null

        -- Kerst is alleen tijdens het kerstschema beschikbaar.
        and (
            s.christmas_share > 0
            or coalesce(gf.is_christmas, 0) = 0
        )

        -- Sinterklaas is alleen op 5 december beschikbaar.
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
            when is_fout = 1 then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 15724800)
            when category = 'Summer' then last_played is null or last_played < (cast(strftime('%s', 'now') as integer) - 43200)
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
            when 'Sinterklaas' then s.sinterklaas_share
            when 'Christmas'   then s.christmas_share
            when 'Summer'      then max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.500
            when 'Hits'        then max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.250
            else                    max(0.0, 1.0 - s.sinterklaas_share - s.christmas_share) * 0.250
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
            when e.category = 'Summer' then 0.500
            when e.category = 'Hits'   then 0.250
            else                            0.250
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
