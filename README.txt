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
Naast de dag/avond/seizoen-mixen zijn er negen extra playlists die je los kunt
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

De negen playlists:

    OldiesMix           alle nummers met het genre Oldies
    80sMix              jaartal 1980-1989
    90sMix              jaartal 1990-1999
    00sMix              jaartal 2000-2009
    10sMix              jaartal 2010-2019
    20sMix              jaartal 2020-2029
    SpaansMix           genre Spaans
    NederlandstaligMix  genre Nederlandstalig
    KerstMix            genre Kerst (speelt uitsluitend kerstmuziek)

Wat er in de bibliotheek beschikbaar is (na alle filters):
    OldiesMix 752 | 80sMix 330 | 90sMix 570 | 00sMix 1033 | 10sMix 1184
    20sMix 1120 | SpaansMix 356 | NederlandstaligMix 657 | KerstMix 283

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

- Kantoor, Beneden, Hele Huis, KantoorSpeaker -> <mode>mp3</mode> + <sample_rate>96000</sample_rate>
  Deze spelers hebben last van de flac-stroom: Kantoor gaf http-fouten, de
  Cast-groepen accepteren geen flac, en de JBL KantoorSpeaker stopte na ~30 s met
  een "http parsing error" in de bridge (tijd bleef op ~31 s staan, daarna stil).
  mp3 wordt 1-op-1 doorgegeven.
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
Zonder "when" (of met "when":"now") stopt alleen het beheer van de engine, zoals
voorheen. In Homey: een HTTP-request-kaartje met bovenstaande body.
