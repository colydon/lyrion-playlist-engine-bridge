-- PlaylistName:SpaansMix
-- PlaylistGroups:Mixen
-- PlaylistCategory:songs
-- PlaylistUseCache: 1
-- PlaylistTrackOrder:ordered
--
-- SpaansMix v1
-- Alle Spaanstalige nummers (genre Spaans), in een gebalanceerde mix.
--
-- Deze playlist werkt volledig op zichzelf: geen seizoenslogica en geen
-- dag/avondmodus. Start hem wanneer je wilt en hij blijft zichzelf verversen.
--
-- Selectie: uitsluitend nummers met het genre Spaans.
--
-- Altijd uitgesloten:
-- - Live, Karaoke, Kinderliedjes en Kindermuziek (permanente exclusions)
-- - Kerst en Sinterklaas
-- - alles onder 2 sterren
--
-- Waardering = speelfrequentie, niet "hoe leuk": zie WAARDERING_POOLS.md,
-- tabel A "hits voorop".
--   5* = 4.00   4.5* = 2.20   4* = 1.25   3.5* = 0.60
--   3* = 0.35   2.5* = 0.12   2* = 0.04
-- Een hogere rating komt dus duidelijk vaker langs. Dat blijft wel dynamisch:
-- geen enkel nummer neemt de playlist over en de cooldown per pool houdt
-- herhaling binnen de dag tegen. Een nummer dat nog weinig gedraaid is krijgt
-- een klein extra duwtje, zodat de playlist blijft verversen.
--
-- Cooldown per pool (zie tier_cooldown): 5* 3 uur, 4.5* 5 uur, 4* 8 uur,
-- 3.5* 5 dagen, 3* 24 uur, 2.5* 8 dagen, 2* 21 dagen. Wat recent speelde valt
-- even af; is de pool daardoor leeg, dan pakt de query automatisch de volledige
-- lijst.
--
-- Artiesten volgen elkaar niet te snel op: dat regelt de engine met
-- artist_repeat_window_tracks, niet deze SQL.

with
genre_flags as (
    select
        gt.track,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',kerst,') > 0 then 1 else 0 end) as is_christmas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',sinterklaas,') > 0 then 1 else 0 end) as is_sinterklaas,
        max(case when instr(',' || replace(lower(g.name), ' ', '') || ',', ',spaans,') > 0 then 1 else 0 end) as is_spaans,
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
        -- WAARDERING = SPEELFREQUENTIE (zie WAARDERING_POOLS.md, tabel A)
        case
            when coalesce(tp.rating, 0) >= 100 then 4.00
            when coalesce(tp.rating, 0) >= 90  then 2.20
            when coalesce(tp.rating, 0) >= 80  then 1.25
            when coalesce(tp.rating, 0) >= 70  then 0.60
            when coalesce(tp.rating, 0) >= 60  then 0.35
            when coalesce(tp.rating, 0) >= 50  then 0.12
            when coalesce(tp.rating, 0) >= 40  then 0.04
            else 0.04
        end * case
            when coalesce(tp.playCount, 0) = 0 then 1.20
            when coalesce(tp.playCount, 0) <= 5 then 1.10
            when coalesce(tp.playCount, 0) <= 20 then 1.00
            when coalesce(tp.playCount, 0) <= 50 then 0.92
            when coalesce(tp.playCount, 0) <= 100 then 0.85
            else 0.75
        end as selection_weight,
        -- Adempauze per waarderingspool.
        case
            when coalesce(tp.rating, 0) >= 100 then 10800
            when coalesce(tp.rating, 0) >= 90  then 18000
            when coalesce(tp.rating, 0) >= 80  then 28800
            when coalesce(tp.rating, 0) >= 70  then 432000
            when coalesce(tp.rating, 0) >= 60  then 86400
            when coalesce(tp.rating, 0) >= 50  then 691200
            else 1814400
        end as tier_cooldown
    from tracks t
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
        and coalesce(gf.is_christmas, 0) = 0
        and dph.id is null
        and coalesce(gf.is_spaans, 0) = 1
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
