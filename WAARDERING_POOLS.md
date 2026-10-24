# Waarderingsmodel en pools

Dit document legt vast hoe de **waardering (sterren)** in alle playlists wordt
gebruikt. Het is de referentie bij het aanpassen van de SQL-bestanden.

## 1. Kernidee

De waardering zegt **niet** hoe leuk een nummer gevonden wordt, maar **hoe vaak
het langs mag komen**. Een nummer met 5 sterren is dus niet "leuker" dan een met
3 sterren; het is een nummer dat vaker gedraaid moet worden. Alles wat met
"hoeveel airplay" te maken heeft, hangt aan de rating.

Daarom werkt elke playlist met **pools op basis van de waardering**, elk met een
eigen gewicht (hoe vaak een nummer uit die pool gekozen wordt) en een eigen
cooldown (hoe snel het terug mag komen).

## 2. De pools

| Pool     | Rol                                                                           | Aantal op 11-10-2026                       |
| -------- | ----------------------------------------------------------------------------- | ------------------------------------------ |
| 5,0 ster | hits van dit moment, duidelijk het vaakst                                     | 94 (waarvan 93 kerst, buiten kerst maar 1) |
| 4,5 ster | hits van dit moment                                                           | 119 (waarvan 84 kerst, buiten kerst 35)    |
| 4,0 ster | hits van dit moment                                                           | 107 (waarvan 87 kerst, buiten kerst 20)    |
| 3,5 ster | geen hit meer, maar recent wel hits geweest; mag vaker mee dan de bulk        | 1182 (wordt waarschijnlijk ~500)           |
| 3,0 ster | "best of the rest", de grote basis die blijft groeien                         | 1380                                       |
| 2,5 ster | rustiger; vooral oldies. Overdag weinig, 's avonds juist oververtegenwoordigd | 1844 (waarvan 726 oldies)                  |
| 2,0 ster | sporadische verrassing                                                        | 92                                         |
| < 2 ster | doet niet mee (uitzondering: Sinterklaas op 5 december)                       | 220                                        |

De hits zijn samen **buiten het kerstseizoen ongeveer 56 nummers** (20 × 4,0*,
35 × 4,5*, 1 × 5,0\*) — vandaar "meestal een stuk of 50". In december komen daar
de 284 kerstnummers bij, die vrijwel allemaal 4,0–5,0 ster zijn.

## 3. Twee lagen

Elke playlist kent dezelfde twee lagen:

1. **Karakter (categorieën met een doelpercentage).** Bepaalt waar de playlist
   over gaat. Bijvoorbeeld DagMix: hits 35%, overig 65%. AvondMix: hits 6%,
   oldies 18%, overig 76%. Deze percentages zijn in de vorige versies al
   vastgesteld en zijn **niet** veranderd.
2. **Waarderingspool (gewicht binnen een categorie).** Bepaalt hoe vaak een
   nummer binnen zijn categorie gekozen wordt.

Die tweede laag is nieuw en zit in alle playlists. Verderop staat precies welke
tabel (A of B) elke playlist gebruikt.

## 4. De twee tabellen

**Tabel A — "hits voorop" (dag, themaplaylists, party, summer, kerst)**

| Rating   | Gewicht |
| -------- | ------- |
| 5,0 ster | 4,00    |
| 4,5 ster | 2,20    |
| 4,0 ster | 1,25    |
| 3,5 ster | 0,60    |
| 3,0 ster | 0,35    |
| 2,5 ster | 0,12    |
| 2,0 ster | 0,04    |

**Tabel B — "avond/rustig" (AvondMix)**

| Rating   | Gewicht |
| -------- | ------- |
| 5,0 ster | 3,00    |
| 4,5 ster | 1,70    |
| 4,0 ster | 1,00    |
| 3,5 ster | 0,70    |
| 3,0 ster | 0,55    |
| 2,5 ster | 0,30    |
| 2,0 ster | 0,08    |

Verschil tussen A en B: in de avond zijn de sprongen kleiner en is 2,5 ster
(lees: oldies) duidelijk hoger. Daardoor komt dezelfde 2,5-ster-pool 's avonds
ongeveer vier keer zo vaak langs als overdag, terwijl de volgorde (hoge
waardering = vaker) hetzelfde blijft.

De verhoudingen binnen de hits zijn bewust groot: 5,0* → 4,5* is factor 1,8 en
4,5* → 4,0* ook. Een individueel 5-sterrennummer komt dus duidelijk vaker langs
dan een 4,5-sterrennummer. Omdat het er maar één tot drie zijn, kan het nooit de
playlist overnemen: in de praktijk draagt de zwaarste 10 nummers maar een paar
procent van het totale gewicht.

## 5. Cooldowns per pool

De cooldown (in de SQL: `tier_cooldown`) is de minimale tijd tussen twee
draaibeurten van hetzelfde nummer. Hij begrenst herhaling en houdt de mix fris.

| Pool           | Cooldown                              | Reden                                                          |
| -------------- | ------------------------------------- | -------------------------------------------------------------- |
| 5,0 ster       | 3 uur                                 | hit van nu: mag vaker terug, maar niet twee keer achter elkaar |
| 4,5 ster       | 5 uur                                 |                                                                |
| 4,0 ster       | 8 uur                                 |                                                                |
| 3,5 ster       | 5 dagen                               | ex-hit, hoeft niet elke dag                                    |
| 3,0 ster       | 24 uur                                | grote pool, dus zelden aan de beurt                            |
| 2,5 ster       | 8 dagen (dag) / 24 uur (avond)        | overdag rustig, 's avonds juist wel                            |
| 2,0 ster       | 21 dagen                              | blijft een verrassing                                          |
| oldies (genre) | 14 dagen (DagMix) / 24 uur (AvondMix) | zie hierboven                                                  |
| kerst          | volgt de pool                         | 5-sterren-kerst mag in december vaak terug                     |
| sinterklaas    | 24 uur                                | alleen op 5 december                                           |

Als een pool door de cooldown leegraakt, pakt de query automatisch de volledige
lijst: de playlist valt nooit stil.

## 6. Uitzonderingen

- **Kerst** heeft hoge ratings (meestal 4–5 ster) juist om vaker gedraaid te
  worden. Binnen kerst geldt dezelfde tabel, dus 5-sterren-kerst komt het
  vaakst langs en 4-sterren-kerst het minst vaak van de drie. De
  seizoenspercentages (30% in de eerste dagen van december, 65% daarna, 100%
  van 20 t/m 26 december) zijn onveranderd.
- **Sinterklaas** komt alleen op 5 december langs (33%), nooit samen met kerst.
  Die nummers zijn onbeoordeeld en mogen daarom alleen op die dag mee.
- **Fout**: een fout nummer met 4,0 ster of hoger gedraagt zich als een hit en
  mag overdag gewoon langskomen (cooldown 8 uur). Lager gewaardeerde
  fout-nummers blijven een uitzondering (21 dagen). In **AvondMix** blijven
  fout-nummers altijd buiten beeld.
- **Permanent uitgesloten** in elke playlist: Live, Karaoke, Kinderliedjes en
  Kindermuziek.
- **Lounge** komt alleen in SummerMix voor. In alle andere mixen (DagMix, AvondMix,
  PartyMix en alle themaplaylists) staat het genre uit, omdat het te vaak
  terugkwam. In SummerMix is Lounge een **eigen categorie met een aandeel van
  15%**: regelmatig aanwezig, maar nooit overheersend. Omdat het om een
  _percentage_ gaat en niet om een vast aantal nummers, blijft die verhouding
  ook kloppen als er in de toekomst veel meer lounge-nummers bijkomen: het
  aandeel blijft 15% en elk afzonderlijk nummer wordt vanzelf zeldzamer.
  Handmatig queueen blijft mogelijk: dit is een selectieregel in de SQL, geen
  filter in LMS of Custom Skip.
- **Tempo**: DagMix en SummerMix sluiten _Very Fast_ uit; in de avond vallen ook
  _Fast_ en nummers zonder TEMPO-tag met een hoge BPM af (AvondMix, SummerMix)
  of krijgen ze een laag gewicht (PartyMix, SummerMix).
- **Party** valt buiten AvondMix.
- **Onder 2 ster** doet niet mee, met Sinterklaas als enige uitzondering.

## 7. Per playlist

| Playlist                                                         | Tabel | Categorie-doelen                                   | Seizoen               |
| ---------------------------------------------------------------- | ----- | -------------------------------------------------- | --------------------- |
| DagMix                                                           | A     | hits 35%, overig 65%                               | kerst + sinterklaas   |
| AvondMix                                                         | B     | hits 6%, oldies 18%, overig 76%                    | kerst + sinterklaas   |
| DagAvondMix                                                      | A/B   | volgt de klok: 07:00–18:00 DagMix, daarna AvondMix | idem                  |
| SummerMix                                                        | A     | summer/lounge 50%, hits 25%, overig 25%            | kerst + sinterklaas   |
| PartyMix                                                         | A     | party 80%, hits 20%                                | geen                  |
| OldiesMix, 80s/90s/00s/10s/20sMix, SpaansMix, NederlandstaligMix, LoveMix, HitsMix | A     | één pool: het thema                                | geen                  |
| KerstMix                                                         | A     | één pool: kerst                                    | n.v.t. (altijd kerst) |

De themaplaylists hebben geen categorie-laag: daar is het thema het filter en
verdeelt tabel A de frequentie binnen dat thema.

## 8. Gemeten resultaat (11-10-2026)

Gemeten met `tools/rating_mix_report.py` (steeds één trekking per keer, precies
wat de engine doet):

| Playlist | 5,0\* | 4,5\* | 4,0\* | 3,5\* | 3,0\* | 2,5\* |
| -------- | ----- | ----- | ----- | ----- | ----- | ----- |
| DagMix   | –     | 24%   | 14%   | 28%   | 26%   | 8%    |
| AvondMix | –     | –     | –     | 24%   | 40%   | 36%   |
| KerstMix | 60%   | 18%   | 22%   | 2%    | 1%    | –     |

- DagMix: samen 38% hits, daarna de ex-hits en de basis. Precies de bedoeling.
- AvondMix: 2,5 ster (oldies) van 8% naar 36% — 's avonds duidelijk
  oververtegenwoordigd, overdag juist laag.
- KerstMix: 5 sterren ruim het vaakst, daarna 4,5 en 4 — binnen kerst werkt de
  waardering dus precies zoals bedoeld.
- Per nummer is het verschil nog groter: een 4,5-sterrennummer komt tientallen
  keren vaker langs dan een individueel 3-sterrennummer, puur omdat die pool zo
  groot is.

## 9. Onderhoud

**Waar zit wat**

- Waarderingsgewichten: het `case ... as rating_weight`-blok in `DagMix.sql`,
  `AvondMix.sql`, `SummerMix.sql`, `PartyMix.sql`; in de themaplaylists zit
  dezelfde tabel direct in `selection_weight`.
- Cooldowns: het `case ... as tier_cooldown`-blok in hetzelfde bestand.
- Categorie-doelen: het `case ... as target_share`-blok (DagMix, AvondMix,
  SummerMix) of `category_targets` (PartyMix).
- Seizoenspercentages: de `settings`-CTE bovenaan.

**Als je ratings gaat veranderen** (bijvoorbeeld de 3,5-sterrenpool verkleinen
naar ~500 en de rest naar 3,0 ster): je hoeft niets aan de SQL te doen. De
gewichten zijn per pool gedefinieerd, niet per aantal. Wat er gebeurt:

- De 3,5-sterrenpool wordt kleiner, dus die groep levert minder selecties, maar
  per nummer blijft hij vaker aan de beurt dan een 3,0-sterrennummer.
- De 3,0- en 2,5-sterrenpools groeien, dus die worden als groep groter en per
  nummer juist zeldzamer. Dat is precies de bedoeling: "best of the rest" die
  af en toe verrast.

**Valkuil bij het aanpassen van de SQL**

De engine strippt zelf commentaar voordat de query wordt uitgevoerd, maar zet
commentaar **op een eigen regel** en niet achter code op dezelfde regel. Een
`--` achter een `then 10800` commentarieert na het samenvoegen van de regels de
rest van de query weg. In de oudere DPL/SQLPlayList-route wordt alleen
commentaar op een eigen regel gestript; daar gaat het dus zeker mis.

**Controleren**

```sh
python3 tools/rating_mix_report.py                 # 15 trekkingen per playlist
python3 tools/rating_mix_report.py --samples 40 --playlists DagMix,AvondMix
```

Of, als je de SQL zelf wilt droogtesten: voer het bestand uit tegen
`library.db` met `persist.db` attached en kijk of de query loopt en of de
eerste regels zinnige ids geven.

**Uitrollen**

1. SQL-bestanden aanpassen in de repo.
2. Kopieer ze naar `/home/tc/playlist_engine/` (daar leest de engine ze bij elke
   selectie opnieuw in; een herstart is niet nodig).
3. Controleren met `rating_mix_report.py`.

## 10. Waarom geen vaste quota per pool?

De categorie-laag (hits 35% in DagMix) houdt de hits ook als **groep** op peil,
hoe hard de 2,5- en 3,0-sterrenpools ook groeien. Binnen die categorie doet het
gewicht het werk. Zo blijft de mix hetzelfde karakter houden zonder dat een
groeiende pool de rest wegdrukt.
