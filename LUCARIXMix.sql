-- PlaylistName:LUCARIXMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- LUCARIXMix v1
-- Uitsluitend nummers van LUCARIX, in een gevarieerde mix.
--
-- Deze playlist werkt volledig op zichzelf: geen dag/avondmodus en geen
-- routing. Start hem wanneer je wilt en hij blijft zichzelf verversen.
--
-- Selectie: alle tracks waar LUCARIX als artiest (of albumartiest) op staat,
-- via contributor_track. Daardoor doen ook de losse singles mee die niet op
-- een van de albums staan.
--
-- Kleine catalogus (ongeveer 30 nummers buiten de kerstperiode), dus KORTE
-- cooldowns. De hele lijst is in ongeveer twee uur rond en een nummer is
-- hooguit twee uur geblokkeerd:
--   5* 30 min, 4.5* 45 min, 4* 60 min, 3.5* 75 min,
--   3* 90 min, 2.5* 105 min, 2* 120 min.
-- Is de pool daardoor leeg, dan pakt de query automatisch de volledige lijst,
-- zodat de mix nooit stilvalt.
--
-- Kerst: de kerstnummers van LUCARIX doen alleen mee van 15 november t/m
-- 26 december (plaatselijke tijd). Daarbuiten vallen ze weg.
--
-- Altijd uitgesloten:
-- - Live, Karaoke, Kinderliedjes en Kindermuziek (permanente exclusions)
-- - Sinterklaas
-- - alles onder 2 sterren
--
-- Waardering: een bewust GEBALANCEERDE curve, zodat een kleinere catalogus
-- gevarieerd blijft. Een hoger gewaardeerd nummer komt vaker langs, maar
-- neemt de lijst niet over: 5* = 2.00, 4.5* = 1.80, 4* = 1.60,
-- 3.5* = 1.40, 3* = 1.20, 2.5* = 1.00, 2* = 0.80. Weinig gedraaide nummers
-- krijgen een klein extra duwtje.

with
genre_flags as (
    select
        gt.track,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kerst,') > 0 then 1 else 0 end) as is_christmas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',sinterklaas,') > 0 then 1 else 0 end) as is_sinterklaas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',live,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',karaoke,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kinderliedjes,') > 0 then 1 else 0 end)
        + max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kindermuziek,') > 0 then 1 else 0 end) as is_permanent_exclusion
    from genre_track gt
    join genres g on g.id = gt.genre
    group by gt.track
),
lucarix_tracks as (
    select distinct ct.track
    from contributor_track ct
    join contributors c on c.id = ct.contributor
    where replace(lower(trim(c.name)), ' ', '') = 'lucarix'
),
season as (
    select
        case
            when strftime('%m-%d', 'now', 'localtime') between '11-15' and '12-26' then 1
            else 0
        end as christmas_allowed
),
base_eligible as (
    select
        t.id,
        coalesce(nullif(pa.name, ''), 'LUCARIX') as primary_artist,
        tp.lastPlayed as last_played,
        -- GEBALANCEERDE WAARDERING (kleine catalogus, gevarieerde mix)
        case
            when coalesce(tp.rating, 0) >= 100 then 2.00
            when coalesce(tp.rating, 0) >= 90  then 1.80
            when coalesce(tp.rating, 0) >= 80  then 1.60
            when coalesce(tp.rating, 0) >= 70  then 1.40
            when coalesce(tp.rating, 0) >= 60  then 1.20
            when coalesce(tp.rating, 0) >= 50  then 1.00
            else 0.80
        end * case
            when coalesce(tp.playCount, 0) = 0 then 1.20
            when coalesce(tp.playCount, 0) <= 5 then 1.10
            when coalesce(tp.playCount, 0) <= 20 then 1.00
            when coalesce(tp.playCount, 0) <= 50 then 0.92
            when coalesce(tp.playCount, 0) <= 100 then 0.85
            else 0.75
        end as selection_weight,
        -- Korte adempauze per waarderingspool (minuten, geen dagen).
        case
            when coalesce(tp.rating, 0) >= 100 then 1800
            when coalesce(tp.rating, 0) >= 90  then 2700
            when coalesce(tp.rating, 0) >= 80  then 3600
            when coalesce(tp.rating, 0) >= 70  then 4500
            when coalesce(tp.rating, 0) >= 60  then 5400
            when coalesce(tp.rating, 0) >= 50  then 6300
            else 7200
        end as tier_cooldown
    from tracks t
    join lucarix_tracks lt on lt.track = t.id
    cross join season s
    left join tracks_persistent tp on tp.urlmd5 = t.urlmd5
    left join contributors pa on pa.id = t.primary_artist
    left join genre_flags gf on gf.track = t.id
    left join dynamicplaylist_history dph on dph.id = t.id and dph.client = 'PlaylistPlayer'
    where
        t.audio = 1
        and t.secs >= 90
        and tp.rating >= 40
        and coalesce(gf.is_permanent_exclusion, 0) = 0
        and coalesce(gf.is_sinterklaas, 0) = 0
        and (coalesce(gf.is_christmas, 0) = 0 or s.christmas_allowed = 1)
        and dph.id is null
),
eligible as (
    select *
    from base_eligible
    where last_played is null
       or last_played < (cast(strftime('%s', 'now') as integer) - tier_cooldown)
),
eligible_pool as (
    select *
    from eligible

    union all

    select *
    from base_eligible
    where not exists (select 1 from eligible)
),
scored as (
    select
        id,
        primary_artist,
        (
            (((random() & 9223372036854775807) + 1.0) / 9223372036854775808.0)
            / nullif(selection_weight, 0)
        ) as selection_score
    from eligible_pool
)
select
    id,
    primary_artist
from scored
where selection_score is not null
order by selection_score;
