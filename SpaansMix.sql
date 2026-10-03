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
-- Waardering is het selectiegewicht, met een bewust VLAKKE curve:
--   5* = 2.00   4.5* = 1.80   4* = 1.60   3.5* = 1.40
--   3* = 1.20   2.5* = 1.00   2* = 0.80
-- Een hoger gewaardeerd nummer wordt dus vaker gekozen, maar niet altijd:
-- een 4,5-sterren hit komt echt niet bij elke selectie bovendrijven. Het gaat
-- om een gebalanceerde mix, niet om zwart/wit. Een nummer dat nog weinig
-- gedraaid is krijgt een klein extra duwtje, zodat de playlist blijft verversen.
--
-- Cooldown: 24 uur. Wat recent speelde valt even af; is de pool daardoor leeg,
-- dan pakt de query automatisch de volledige lijst.
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
        case
            when coalesce(tp.rating, 0) >= 100 then 2.00
            when coalesce(tp.rating, 0) >= 90  then 1.80
            when coalesce(tp.rating, 0) >= 80  then 1.60
            when coalesce(tp.rating, 0) >= 70  then 1.40
            when coalesce(tp.rating, 0) >= 60  then 1.20
            when coalesce(tp.rating, 0) >= 50  then 1.00
            when coalesce(tp.rating, 0) >= 40  then 0.80
            else 0.60
        end * case
            when coalesce(tp.playCount, 0) = 0 then 1.20
            when coalesce(tp.playCount, 0) <= 5 then 1.10
            when coalesce(tp.playCount, 0) <= 20 then 1.00
            when coalesce(tp.playCount, 0) <= 50 then 0.92
            when coalesce(tp.playCount, 0) <= 100 then 0.85
            else 0.75
        end as selection_weight
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
       or last_played < (cast(strftime('%s', 'now') as integer) - 86400)
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
