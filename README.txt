DagMix v3

IMPORTANT: v2 should be removed before installing this version. v3 fixes the
Custom Skip filename/case issue and substantially simplifies the SQL by building
the genre flags once instead of repeatedly querying genres for every track.

This build also adds a dedicated Sinterklaas schedule:
- Dec 5: 33%
- all other days: 0%

CUSTOM SKIP
Keep your current defaultfilterset.cs.xml exactly as it is, including:
- Kerst 100%
- Live 100%
- Karaoke 100%
- Kinderliedjes 100%
- Kindermuziek 100%
- Sinterklaas 100%
- Rated below 2 stars 100%

Create/use a second filter set with the exact filename:
    dagmix.cs.xml
It should contain the same rules EXCEPT:
- Genre: Kerst
- Genre: Sinterklaas

The SQL uses these valid DPL actions:
    PlaylistStartAction1:cli:customskip setfilter dagmix.cs.xml
    PlaylistStopAction1:cli:customskip setfilter defaultfilterset.cs.xml

DPL switches the primary Custom Skip filter while DagMix is active and restores
the normal filter when it stops. Other playlists do not need to be edited.

CHRISTMAS SCHEDULE (local LMS time)
- Dec 5: 0% (Sinterklaas only, never combine the two)
- Dec 1-4 and Dec 6-9: 30%
- Dec 10-19: 65%
- Dec 20-26: 100%
- Dec 27-Nov 30: 0%

SINTERKLAAS SCHEDULE (local LMS time)
- Dec 5: 33%
- all other days: 0%

On Dec 5 the Sinterklaas tracks are also allowed without a rating, because all
19 of them are unrated and would otherwise never be selected at all.

NORMAL MIX TARGET
- Hits: 35%
- Other: 65%
- Oldies, Party and Fout are no longer explicit target buckets in DagMix

RATING
- < 2 stars: excluded
- unrated: excluded from automatic playback, except Sinterklaas tracks on the
  Sinterklaas day itself (see SINTERKLAAS SCHEDULE)
- 5 stars: weight 8
- 4.5 stars: weight 6
- 4 stars: weight 4
- 3.5 stars: weight 3
- 3 stars: weight 2
- 2.5 stars: weight 1
- 2 stars: weight 0.7

COOLDOWN
- Hits: 5 hours
- Oldies: 14 days
- Fout: 182 days
- Sinterklaas: 24 hours
- Christmas: 24 hours
- Other: 24 hours

The category percentages are target probabilities over time, not exact quotas
in every small DPL batch. Missing/temporarily exhausted categories naturally
allow the remaining categories to fill the batch.

AvondMix now uses the Custom Tag Importer `TEMPO` tag when available:
- excludes `Fast` and `Very Fast`
- strongly prefers `Slow`
- still allows some `Moderate` and `Very Slow`
- falls back gracefully when a track has no imported `TEMPO` value

STANDALONE PLAYLIST ENGINE
For a stable long-term setup with multiple playlists, queue top-up and webhook
control, use the Python engine in this folder:

    python3 playlist_engine.py --config playlist_engine_config.example.json

It keeps the SQL-based selection logic, but replaces the unreliable runtime
parts of DynamicPlaylists4/DynamicMix with a dedicated service that:
- starts a playlist on any LMS player
- keeps adding suitable tracks when the queue runs low
- can keep a managed player session alive through reconnects or an unexpectedly empty queue
- can reopen the current queue item when a managed player stays in play mode but playback time stops advancing
- blijft dezelfde track daarna weer midden in het nummer hangen, dan slaat de engine die track over
  in plaats van nog een power-cycle (een vastloper op één track zit in die track, niet in de receiver)
- kan ook een handmatig gestart liedje redden: blijft een Cast-speler op 0 s hangen, dan power-cyclet de engine de receiver eenmalig (ook zonder engine-sessie)
- does not auto-restart when a user has paused or stopped a player that still has its queue
- exposes a webhook API for Homey or other automation
- keeps skip rules adjustable in JSON instead of hardwiring them into plugins
- supports an explicit playlist catalog so extra SQL playlists can be added cleanly
- can be launched from LMS itself through a thin custom plugin bridge

See also:
    PLAYLIST_ENGINE.md

The preferred stable architecture is now:
- SQL files such as DagMix.sql define the selection logic
- playlist_engine.py owns playback start, queue refill and session state
- Homey calls the HTTP API
- LMS uses the thin bridge in lms_plugin\PlaylistEngineBridge

Quick examples:

    POST /api/start with {"playlist":"DagMix","player_name":"Kantoor"}
    POST /api/start with {"playlist":"DagMix","player_name":"Woonkamer"}
    POST /api/stop with {"player_name":"Kantoor"}

To add another managed playlist later:
- add a new SQL file, for example RustMix.sql
- add it under "playlists" in playlist_engine_config.example.json
- restart the engine
- it will become available to both Homey and the LMS bridge

RATINGS UIT DE BESTANDSTAGS (MusicBee -> LMS)
Nieuwe muziek wordt in MusicBee beoordeeld en die rating staat als POPM-tag in
het mp3-bestand. CustomTagImporter kan die tag naar LMS schrijven, maar versie
1.3.3 doet dat kapot (schrijft "ARRAY(0x...)" als waarde en zet daarna ALLE
ratings op 0). Daarom staat `writeratingstodb` in
prefs/plugin/customtagimporter.prefs op '0' en doet `sync_ratings.py` het werk:

    /home/tc/playlist_engine/sync_ratings.py        (bron: tools/sync_ratings_from_tags.py)

- houdt in `rating_sync.db` bij welke tag-waarde het per nummer laatst zag;
- de TAG is leidend: met `--correct` (wat de watchdog gebruikt) wordt elke
  LMS-rating die afwijkt van de tag meteen rechtgezet, ook als het bestand niet
  is aangeraakt. Zonder die vlag worden alleen nieuwe nummers en gewijzigde
  tags bijgewerkt;
- vult nummers zonder rating en zet nooit iets op 0;
- schrijft via `ratingslight setratingpercentnoclient`, zodat LMS-cache en
  historie (lastRated/prevRating) kloppen;
- dwingt ook de GENRES af: een genre dat niet meer in de TCON-tag staat wordt
  uit LMS verwijderd (LMS zelf laat zo'n oude koppeling staan), en genres die
  daarna nergens meer aan hangen worden opgeruimd. De placeholder
  "Geen genre" blijft staan. Genres toevoegen doet LMS zelf bij de scan.

Conversie (gemeten op deze bibliotheek): de bestanden bevatten zowel de klassieke
WMP-waarden als de waarden die MusicBee zelf voor halve sterren schrijft. Een
lineaire byte/255-formule is dus fout (128 zou dan 2,5 ster worden terwijl
MusicBee 3 ster toont). Daarom een tabel:

    byte  13 -> 0,5 ster       byte 186 -> 3,5 ster
    byte  64 -> 2 ster         byte 196 -> 4 ster
    byte 118 -> 2,5 ster       byte 242 -> 4,5 ster
    byte 128 -> 3 ster         byte 255 -> 5 ster

Tussenliggende bytes worden lineair geinterpoleerd.

LET OP: omdat de tag leidend is, wordt een rating die je in LMS zelf zet (bijv.
via de telefoon) bij de volgende sync weer teruggezet naar de tag. Beoordeel
dus in MusicBee en sla de tags op.

Wanneer draait het: automatisch zodra een bibliotheekscan klaar is (2 minuten
later, zodat LMS zijn nasleep afmaakt), met een dagelijkse run als vangnet. De
watchdog regelt dat; log: `rating_sync.log`.

Let op: een nieuw bestand krijgt pas een rating/genre-controle nadat de
bibliotheekscan het heeft ingelezen (nachtscan 03:00, of handmatig `rescan`);
daarna pakt de sync het op.

Wat hebben we nog van de plugins nodig?
- CustomTagImporter: alleen voor de custom tags (TEMPO/TBPM) die de engine
  gebruikt. `writeratingstodb` moet '0' blijven, anders wist hij ratings.
- RatingsLight: voor de rating-CLI en de dagelijkse back-ups in
  prefs/RatingsLight (die back-ups gebruik je om ratings te herstellen).
- Rescan: de nachtelijke scan.

Herinstallatie van Lyrion (kort):
1. piCorePlayer + LMS, muziekshare op /mnt/music (CIFS), library.db in Cache/.
2. Plugins: CastBridge, PlaylistEngineBridge (lms_plugin/), RatingsLight,
   CustomTagImporter, Rescan. Zet in prefs/plugin/customtagimporter.prefs
   `writeratingstodb: '0'` (enkele quotes!) en doe de castbridge.xml-instellingen
   per device (mp3, sample_rate bij groepen, stop_receiver).
3. Deploy playlist_engine.py + playlist_engine_config.json + watchdog +
   sync_ratings.py in /home/tc/playlist_engine en start de watchdog uit
   /opt/bootlocal.sh.
4. Eenmalig `python3 sync_ratings.py` (ongeveer 10 min: leest alle tags en zet
   de baseline), daarna is elke run enkele seconden.

TIME-ROUTED PLAYLISTS
The engine can also expose one logical playlist that switches source SQL by
local time during queue top-ups. The example config now includes:

- DagAvondMix
    - 07:00-18:00: DagMix
    - 18:00-07:00: AvondMix

Because Kerst and Sinterklaas already live in the SQL, those seasonal changes
still switch automatically at the right date boundaries inside the selected
day or evening profile.

SUMMER MIX (ADDITIONAL PLAYLIST)
SummerMix is an extra playlist next to DagMix, AvondMix and DagAvondMix. The
existing playlists are not changed in any way: SummerMix is only used when
Homey (or the LMS menu) starts it explicitly, for example on a warm day.

Normal days keep using DagAvondMix, so nothing changes there.

What SummerMix does:
- forces roughly 50% of the tracks from the genres Summer and Lounge together
  (Lounge is still a small genre, so it rides along in the same summer block)
- sets Hits to 25% and the remaining Other group to 25%
  (DagMix uses 35% hits and 65% other, so both groups play less often here)
- keeps the rating and playcount weighting of DagMix
- excludes Very Fast at all times, just like DagMix

Note about the Hits percentage: the library currently contains only about 50
tracks tagged with the Hits genre (about 45 eligible after the rating and
cooldown rules). With only one Hits track every 5 hours, the Hits share in
practice tops out around 10%, no matter what target is configured. The 25%
target therefore means "use every Hits track as often as the cooldown allows".
The leftover share flows to Summer/Lounge and Other. As soon as more tracks are
tagged with the Hits genre, SummerMix grows into the 25% on its own.

Evening behaviour (local LMS time 18:00-07:00) is handled inside the SQL:
- no TEMPO Fast or Very Fast tracks anymore
- a mild BPM preference for slower tracks
- Summer and Lounge stay just as important as during the day

Because the day/evening switch is part of SummerMix.sql, this playlist needs
no routing_windows in the config and no extra Python code.

Cooldown:
- Hits: 5 hours
- Summer + Lounge: 12 hours
- Oldies: 14 days
- Fout: 182 days
- Sinterklaas / Christmas / Other: 24 hours

Start SummerMix through the same API:
    POST /api/start with {"playlist":"SummerMix","player_name":"Kantoor"}

PARTY MIX (ADDITIONAL PLAYLIST)
PartyMix is the fifth playlist and, like SummerMix, purely additive: the other
playlists are untouched. It is meant for a party, or as an upbeat background
while working.

What PartyMix does:
- mainly Party tracks (target 80%)
- occasionally a hit (target 20%), but only an energetic one:
  TEMPO Fast or Very Fast, or a BPM of 122 or higher as long as the track is
  not tagged Slow or Very Slow. That BPM rule also applies when a track has no
  TEMPO tag at all.
- rating stays decisive: a higher rating is played clearly more often
- a mild tempo nudge towards fast/very fast, never stronger than a rating step

Always excluded:
- Kerst and Sinterklaas (PartyMix is not seasonal)
- Live, Karaoke, Kinderliedjes and Kindermuziek
- everything below 2 stars

Cooldown:
- Hits: 5 hours
- Party: 24 hours
- Oldies: 14 days
- Fout: 182 days

Note about the hit share: the library has 443 usable Party tracks but only
about 25 hits that are energetic enough. In a normal batch of candidates the
hits land around 15%, and later in a session they taper off simply because
there are no more of them. That matches "now and then a hit".

PartyMix has no day/evening and no seasonal logic: it is always the same
upbeat profile.

Start PartyMix through the same API:
    POST /api/start with {"playlist":"PartyMix","player_name":"Woonkamer"}

EXTRA PLAYLISTS (THEMA-MIXEN)
Naast de dag/avond/seizoen-mixen zijn er twaalf extra playlists die je los kunt
starten wanneer je daar zin in hebt. Ze hebben allemaal dezelfde opzet:

- ze werken volledig op zichzelf: geen dag/avondmodus en geen seizoenslogica,
  dus je kunt ze op elk moment starten
- ze blijven zichzelf verversen (24-uurs cooldown op wat recent speelde)
- Kerst, Sinterklaas, Live, Karaoke, Kinderliedjes en Kindermuziek vallen af.
  Alleen bij KerstMix is Kerst juist de selectie.
- minimaal 2 sterren
- een bewust VLAKKE waarderingscurve: 5* = 2.00, 4.5* = 1.80, 4* = 1.60,
  3.5* = 1.40, 3* = 1.20, 2.5* = 1.00, 2* = 0.80
  Een hoger gewaardeerd nummer wordt dus vaker gekozen, maar niet altijd:
  een 4,5-sterren hit komt echt niet bij elke selectie bovendrijven. Het gaat
  om een gebalanceerde mix, niet om zwart/wit.
- weinig gedraaide nummers krijgen een klein extra duwtje, zodat de playlist
  blijft verversen
- artiesten volgen elkaar niet te snel op: dat regelt de engine met
  artist_repeat_window_tracks (30 nummers), niet de SQL

De twaalf playlists:

    OldiesMix           alle nummers met het genre Oldies
    80sMix              jaartal 1980-1989
    90sMix              jaartal 1990-1999
    00sMix              jaartal 2000-2009
    10sMix              jaartal 2010-2019
    20sMix              jaartal 2020-2029
    SpaansMix           genre Spaans
    NederlandstaligMix  genre Nederlandstalig
    KerstMix            genre Kerst (speelt uitsluitend kerstmuziek)
    LUCARIXMix          alle nummers van LUCARIX
    LoveMix             alle nummers met het genre Love
    HitsMix             de hits van nu (genre Hits)

Wat er in de bibliotheek beschikbaar is (na alle filters):
    OldiesMix 752 | 80sMix 330 | 90sMix 570 | 00sMix 1033 | 10sMix 1184
    20sMix 1120 | SpaansMix 356 | NederlandstaligMix 657 | KerstMix 283
    LUCARIXMix 29 (42 in de kerstperiode) | LoveMix 139 | HitsMix 59

LUCARIXMix is een uitzondering op de andere thema-mixen: de catalogus is klein
(ongeveer 30 nummers buiten de kerstperiode). Daarom gebruikt deze lijst korte
cooldowns (30-120 minuten in plaats van uren tot dagen) en staat de
artiestenblokkade van de engine uit via "artist_repeat_window_tracks": 0 in de
config. Anders zou de engine na het eerste nummer alle andere LUCARIX-tracks
als "dezelfde artiest" wegfilteren. De kerstnummers van LUCARIX doen alleen
mee van 15 november t/m 26 december (plaatselijke tijd).

Starten gaat net als bij de andere playlists:
    POST /api/start with {"playlist":"KerstMix","player_name":"Woonkamer"}
Ze staan ook gewoon in het LMS-menu onder Eigen Playlists.

DIRECT RUNNER ALTERNATIVE
If DynamicPlaylists4 keeps failing even though DagMix.sql returns rows, use the
PowerShell runner in this folder instead:

    .\Invoke-DagMix.ps1

By default it:
- resolves player Kantoor on LMS
- executes the current local DagMix.sql directly against LMS
- attaches persist.db automatically
- replaces the current queue with the first result
- adds the remaining DagMix tracks to the queue
- starts playback directly through LMS

Useful examples:

    .\Invoke-DagMix.ps1 -PlayerName Kantoor
    .\Invoke-DagMix.ps1 -PlayerName Woonkamer -Count 30
    .\Invoke-DagMix.ps1 -PlayerName Kantoor -PreviewOnly

Optional if you still want the DagMix-specific Custom Skip filter before queueing:

    .\Invoke-DagMix.ps1 -PlayerName Kantoor -CustomSkipFilter dagmix.cs.xml

This bypasses DynamicPlaylists4/DynamicMix entirely and is the simplest route
if the SQL itself is correct but the plugin stack remains unreliable.

DON'T STOP THE MUSIC
LMS vult zelf de queue aan als die leegloopt: "Don't Stop The Music" (DSTM). Dat is
handig als iemand losse liedjes, een album of een gewone playlist afspeelt, maar het
zit de engine in de weg zodra een engine-playlist loopt.

De bridge regelt dat nu automatisch:
- zolang de engine een sessie heeft voor die speler houdt DSTM zich stil;
- zodra die sessie weg is (playlist gestopt of de engine is onbereikbaar) doet DSTM
  weer gewoon mee;
- er worden geen voorkeuren van spelers of van jou aangepast.

Techniek: <canConflictWithDSTM> in install.xml plus disableDSTM() in Plugin.pm, de
officiele hook die LMS hiervoor heeft. De bridge haalt elke 20 seconden /api/sessions
op en onthoudt welke spelers de engine beheert. Is de engine langer dan 120 seconden
onbereikbaar, dan valt DSTM weer bij (beter dan stilte).

Uitzetten: zet "suppress_dstm_when_engine_active": false in bridge_config.json en
herstart LMS.

ZIEN WIE DE QUEUE AANPAST (diagnose)
    touch /tmp/playlist_engine_bridge_debug
Daarna schrijft de bridge elk playlist-commando (met parameters, bron en speler) plus
elke DSTM-vraag naar /var/log/slimserver/server.log. Uitzetten:
    rm /tmp/playlist_engine_bridge_debug

WAARDERING = SPEELFREQUENTIE
De rating zegt niet hoe leuk een nummer is, maar hoe vaak het langs mag komen. Alle
playlists werken daarom met pools: 5,0* / 4,5* / 4,0* zijn de hits van nu (samen
meestal zo'n 50 nummers), dan 3,5* (ex-hits), dan de grote 3,0*-basis, dan 2,5*
(oldies/rustig, overdag laag en 's avonds juist vaak) en 2,0* als verrassing.
Binnen de pools geldt een vaste tabel; zie WAARDERING_POOLS.md voor de gewichten,
cooldowns, uitzonderingen (kerst, sinterklaas, fout) en het onderhoud.

Meten wat er echt uit komt:
    python3 tools/rating_mix_report.py --samples 20

LOUNGE ALLEEN IN SUMMERMIX
Het genre Lounge staat in alle mixen uit (DagMix, AvondMix, PartyMix en de
themaplaylists). SummerMix heeft er een eigen categorie van 15%: regelmatig
langskomen, maar nooit overheersend. Omdat het een percentage is en geen vast
aantal nummers, blijft dat ook kloppen als er veel meer lounge-nummers bij komen
(het aandeel blijft 15%, elk nummer wordt zeldzamer).
Handmatig queueen kan gewoon: het is een selectieregel in de SQL, geen filter in
LMS of Custom Skip. Aanpassen: `gf.is_lounge` in de betreffende .sql-bestanden.

CASTBRIDGE: WELKE SPELER WELKE MODUS
Deze Pi heeft geen mp3-encoder en geen mp3-decoder: LMS heeft alleen de eigen
binaries sox, flac, faad, mac en wvunpack. De muziekbibliotheek is volledig mp3
(5200+ bestanden), waarvan een groot deel 48 kHz is.

Instellingen in /usr/local/slimserver/prefs/castbridge.xml (14-10-2026):

- Beneden, Hele Huis, WoonkamerCombo -> <mode>mp3</mode> + <sample_rate>96000</sample_rate>
  Deze spelers hebben last van de flac-stroom: Kantoor gaf http-fouten en de
  Cast-groepen accepteren geen flac. mp3 wordt 1-op-1 doorgegeven.
  Let op: een nieuwe groep erft de <common>-instellingen (flc/48k) en slaat dan
  het eerste nummer over of stopt na het tweede. Zet hem dan ook op mp3 + 96000.
- WoonkamerCombo heeft daarnaast <send_metadata>1</send_metadata> en
  <send_coverart>1</send_coverart>, zodat de Nest Hub in de groep titel, artiest
  en hoesje toont. Omdat een mp3-stroom geen lengte meedraagt, blijft de
  voortgangsbalk/afstandsbediening daar wel achterwege.
- WoonkamerCombo heeft ook <stop_receiver>0</stop_receiver>. Zonder dat stopt de
  bridge bij elke sprong in een nummer de Cast-receiver en start hem daarna
  opnieuw; de Nest Hub laat dan steeds zijn "verbonden"-geluidje horen. Met 0
  blijft de sessie leven: een seek hervat in ~1,5-3 s in plaats van ~6 s. Staat
  alleen in het device-blok van de groep; de losse speakers houden de
  <common>-waarde (1). Let op: dit is geen instelling die de plugin-UI kent, dus
  na het opslaan van de CastBridge-instellingen in LMS kan hij verdwijnen -
  controleer dan castbridge.xml.
- KantoorSpeaker (JBL) -> <mode>mp3</mode>, zonder <sample_rate> (erft 48000), plus
  <send_metadata>0</send_metadata> en <send_coverart>0</send_coverart>.
  De JBL heeft geen scherm; metadata en hoesjes kosten hem bij elke trackwissel
  extra werk. Sinds die twee uit staan zijn de lange stiltes bij een wissel
  (14-15 s) niet meer gezien; gemeten wissels: 1,5-5 s.
  Nadeel: een mp3-stroom heeft geen lengte, dus op een Nest Hub met scherm tonen
  deze spelers geen voortgangsbalk en geen afstandsbediening.
  Let op: een nieuw toegevoegde speaker erft de <common>-instellingen (flc/48k).
  Stopt een nieuw apparaat na een paar seconden? Zet hem dan ook op mp3 + 96000.

- Woonkamer, Slaapkamer, Keuken, TV, TV Slaapkamer -> <mode>flc</mode> +
  <sample_rate>48000</sample_rate> (als default in het <common>-blok).
  Flac draagt wel een lengte mee, dus het scherm toont de voortgangsbalk, de
  eindtijd en de vorige/volgende-knoppen. 48000 in plaats van de oude 96000
  halveert het verkeer.

Regel: zet nooit een <sample_rate> die LAGER is dan de bron. Bij 44,1 kHz- en
48 kHz-bestanden met een lagere doelwaarde moet LMS omrekenen, en dat kan zonder
mp3-encoder niet:

    Error: Couldn't create command line for mp3 playback for [file:///...]

Gevolg: het afspelen stopt na een of twee nummers. 48000 of hoger is veilig;
voor de mp3-spelers is 96000 de bewezen waarde.

Controle:
    grep -c "Couldn't create command line" /var/log/slimserver/server.log
    # moet 0 blijven

Bij twijfel de config terugzetten kan met:
    /usr/local/slimserver/prefs/castbridge.xml.bak-20261011-rate


STOPPEN NA HET HUIDIGE NUMMER (via de API / Homey)
    POST http://192.168.0.54:8787/api/stop
    Header: X-API-Key: <token>
    Body: {"player_name":"Slaapkamer","when":"track"}

De engine knipt de wachtrij dan af tot het nummer dat nu speelt: dat nummer loopt
gewoon af, daarna stopt het en zet de engine de speler uit. Daardoor laat de bridge
het Cast-apparaat meteen los en keert het scherm direct terug naar zijn eigen
weergave (zonder de 30 s durende "receiver"-melding).
De engine bewaakt dat ook: stop/afknippen en het bijvullen van de wachtrij kunnen
ekaar niet meer kruisen. Komt er toch een track bij terwijl de stop al wacht (bijv.
van buiten de engine), dan knipt hij de wachtrij in de volgende ronde opnieuw af
en logt hij "Queue for ... grew while a stop was pending".
Zonder "when" (of met "when":"now") stopt alleen het beheer van de engine, zoals
voorheen. In Homey: een HTTP-request-kaartje met bovenstaande body.

DIRECT STOPPEN (hard)
    POST http://192.168.0.54:8787/api/stop
    Header: X-API-Key: <token>
    Body: {"player_name":"Slaapkamer","when":"hard"}

Dit stopt de weergave meteen: stop, wachtrij leeg, speler uit en de engine-sessie
opgeruimd. Daarna kan niets de stream nog hervatten. "now" laat alleen het beheer
los; "hard" (ook "hard-stop", "immediate", "force" of "stop") stopt echt.

ÉÉN KNOP, DRIE STANDEN (aanbevolen voor Homey)
    POST http://192.168.0.54:8787/api/toggle
    Header: X-API-Key: <token>
    Body: {"player_name":"Slaapkamer","playlist":"DagAvondMix"}

De engine kent de stand en beslist, dus Homey hoeft geen toestand bij te houden:

- geen sessie            -> playlist starten            (state: playing)
- sessie, geen vlag      -> stoppen na dit nummer        (state: stopping_after_track)
- sessie met die vlag    -> direct alles stoppen         (state: stopped)

Elke druk op de fysieke knop stuurt dus dezelfde POST, ongeacht de stand van de
virtuele schakelaar. De response bevat "state" en "stop_pending" als je de
schakelaar wilt bijwerken; de knopflow hoeft er niets mee te doen.

SNELHEID VAN EEN START
De engine logt per start één regel met de opbouw:
    Start DagMix on cc:cc:...: select 1.97s, receiver 0.01s, queue 0.26s, total 2.24s
- select   : playlist-SQL en trackkeuze (dit is normaal het grootste deel)
- receiver : power-on of, alleen als de receiver aan stond maar lang niets deed,
             een power-cycle; staat de speler al uit, dan kost dit vrijwel niets
- queue    : eerste track starten en de rest in één verzoek toevoegen
Zo zie je meteen waar tijd verloren gaat als een start weer langzaam voelt.

SPEELT ER IETS? (voor notificaties en andere flows)
    GET http://192.168.0.54:8787/api/state?player_name=KantoorSpeaker&token=<token>
    -> {"player_id":"...","player_name":"KantoorSpeaker","playing":true,
        "session":true,"stop_pending":false,"state":"playing",
        "playlist":"DagAvondMix","mode":"play","power":1}

Voor de simpelste vergelijking in een Advanced Flow is er ook platte tekst:
    GET http://192.168.0.54:8787/api/playing?player_name=KantoorSpeaker&token=<token>
    -> true
    -> false

Betekenis van de velden:
- session      : de engine beheert een playlist op deze speler (dit is precies
                 wat de oude virtuele schakelaar "aan" betekende)
- playing      : LMS speelt nu daadwerkelijk af (ook als dat buiten de engine om gaat)
- stop_pending : er loopt een "stop na dit nummer"
- state        : idle | external | playing | suspended | stopping_after_track

Advies voor notificaties:
- wil je "playlist actief" aanhouden zoals vroeger -> gebruik session
- wil je "er is nu geluid" -> gebruik playing

Voorbeeld in Homey (Advanced Flow): HTTP GET met "JSON" aan, daarna een
logica-kaart op de tag playing of session. Of gebruik /api/playing en vergelijk
de tekst met true.
