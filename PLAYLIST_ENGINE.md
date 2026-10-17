**Overview**
The SQL stays responsible for track selection.
The Python service in [playlist_engine.py](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine.py) is now the runtime layer for:

- starting a custom playlist on any LMS player
- keeping the queue filled indefinitely
- applying adjustable skip rules outside DynamicPlaylists4
- exposing a webhook API for Homey
- exposing a thin LMS menu bridge
- optionally routing one logical playlist to different SQL playlists by local time

The LMS bridge lives in [lms_plugin/PlaylistEngineBridge/Plugin.pm](c:/Users/rickl/Desktop/cti_dagmix_v3/lms_plugin/PlaylistEngineBridge/Plugin.pm).

**What Is Test-Ready**

- Multiple playlists are supported through the `playlists` section in [playlist_engine_config.example.json](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine_config.example.json).
- The API can target any player by `player_name` or `player_id`.
- The queue auto-top-up loop is active for every managed session.
- Managed sessions now stay attached to the player through brief disconnects and empty-queue failures.
- Manual `pause` or `stop` with a queue still present does not auto-restart playback.
- LMS can show a `Custom Playlists` menu and start playback on the player currently selected in LMS.
- The LMS bridge can also expose one direct home-page quick-start button for a fixed playlist such as `DagAvondMix`.

**1. Configure The Engine**
Copy [playlist_engine_config.example.json](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine_config.example.json) to your real config file and adjust at least:

- `api.token`
- `lms.base_url`
- `lms.library_db`
- `lms.persist_db`
- `engine.playlists_dir`
- `engine.player_recovery_*`

Example playlist catalog:

```json
"playlists": {
  "DagMix": {
    "title": "DagMix",
    "sql_file": "DagMix.sql",
    "description": "Dagelijkse mix met seizoens- en kwaliteitsregels.",
    "initial_count": 20,
    "topup_count": 10,
    "low_watermark": 5
  },
  "DagAvondMix": {
    "title": "DagAvondMix",
    "sql_file": "DagMix.sql",
    "description": "Schakelt lokaal om 07:00 naar DagMix en om 18:00 naar AvondMix.",
    "initial_count": 8,
    "topup_count": 4,
    "low_watermark": 2,
    "routing_windows": [
      {"start": "07:00", "end": "18:00", "playlist": "DagMix"},
      {"start": "18:00", "end": "07:00", "playlist": "AvondMix"}
    ]
  },
  "SummerMix": {
    "title": "SummerMix",
    "sql_file": "SummerMix.sql",
    "description": "Zomermix met 50% Summer/Lounge, 25% hits en 25% overig; 's avonds rustiger.",
    "start_with_genre": "Summer",
    "initial_count": 20,
    "topup_count": 10,
    "low_watermark": 5
  },
  "PartyMix": {
    "title": "PartyMix",
    "sql_file": "PartyMix.sql",
    "description": "Opzwepende feestmix met vooral Party en af en toe een snelle hit.",
    "start_with_genre": "Party",
    "initial_count": 20,
    "topup_count": 10,
    "low_watermark": 5
  }
}
```

`SummerMix` en `PartyMix` zijn aanvullende playlists: `DagMix`, `AvondMix` en `DagAvondMix` blijven ongewijzigd. Beide hebben geen extra Python-code nodig: `SummerMix.sql` regelt zelf de dag/avondwissel (geen TEMPO Fast/Very Fast na 18:00) en `PartyMix.sql` is een vast opzwepend profiel zonder seizoenslogica.

Daarnaast zijn er nog negen thema-playlists met dezelfde opzet als `PartyMix` (één filter, vlakke waarderingscurve, geen dag/avond- of seizoenslogica): `OldiesMix`, `80sMix`, `90sMix`, `00sMix`, `10sMix`, `20sMix`, `SpaansMix`, `NederlandstaligMix` en `KerstMix`. Zie `README.txt` voor de details en ze staan in `playlist_engine_config.example.json`.

If `engine.auto_discover_playlists` is `true`, extra `.sql` files in the playlist folder are also picked up automatically.

`routing_windows` are evaluated in the engine host's local time. This lets one logical playlist switch source SQL during playback top-ups without starting a new LMS session.

Managed-session recovery is controlled by these engine settings:

- `stalled_playback_detection_enabled`: detect players that remain in `play` but stop making real time progress
- `stalled_playback_grace_seconds`: how long that stalled state may persist before recovery runs
- `stalled_playback_progress_tolerance_seconds`: how much playback-time drift still counts as healthy progress
- `player_recovery_enabled`: keep sessions alive and try to recover after unintended player-side failures
- `player_recovery_grace_seconds`: wait before rebuilding an unexpectedly empty queue
- `player_recovery_cooldown_seconds`: minimum time between recovery attempts for the same player
- `queue_pruning_enabled`: remove already played queue entries during normal playback maintenance
- `queue_prune_keep_played_tracks`: how many played items to keep behind the current track
- `queue_prune_min_tracks`: minimum number of removable played items before pruning runs

**2. Run The Engine**
Run the service on the LMS host itself, or on a machine that has filesystem access to the LMS databases:

```bash
python3 playlist_engine.py --config playlist_engine_config.example.json --log-level INFO
```

Quick health check:

```text
GET http://<engine-host>:8787/api/health?token=<token>
```

List playlists:

```text
GET http://<engine-host>:8787/api/playlists?token=<token>
```

List players:

```text
GET http://<engine-host>:8787/api/players?token=<token>
```

Recovery behavior:

- if a player remains in `play` but the reported playback time stops advancing for too long, the engine can reopen the current queue entry to kick CastBridge/Chromecast back into playback
- if a managed player disconnects and later reconnects, the engine can resume playback or rebuild the queue
- if a managed queue disappears unexpectedly, the engine can rebuild it after the configured grace period
- if a user pauses or stops the player and the queue is still intact, the engine keeps the session suspended and does not auto-restart
- `POST /api/stop` still disables management for that player immediately

**PiCore Watchdog**
For PiCore or other lightweight installs, keep the engine behind a tiny shell watchdog instead of a one-shot `nohup` start.

The watchdog script in [playlist_engine_watchdog.sh](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine_watchdog.sh) does two things:

- restarts the engine if the Python process is gone
- restarts the engine if `/api/health` fails twice in a row

The checks are intentionally light:

- one local health request every 30 seconds
- one background shell loop
- no full library scan or extra database work

On PiCore, the recommended pattern is:

```sh
nohup /home/tc/playlist_engine/playlist_engine_watchdog.sh >/dev/null 2>&1 &
```

and let `bootlocal.sh` start the watchdog, not `playlist_engine.py` directly.

**Let op bij het opstarten (belangrijk)**

Start de watchdog altijd **boven** de regel met `pcp_startup.sh | tee -a /var/log/pcp_boot.log` in `/opt/bootlocal.sh`. Die regel komt namelijk nooit klaar: LMS en de bridges erven de pipe en houden hem open, dus `tee` blijft wachten en `bootlocal.sh` komt nooit verder. Alles wat daaronder staat wordt dus nooit uitgevoerd — met als gevolg dat de engine na een herstart niet terugkomt en de playlists blijven stilstaan zonder dat er iets in de logs staat.

De watchdog schrijft bij het opstarten een regel naar `playlist_engine/boot.log`, zodat je achteraf kunt zien of hij daadwerkelijk gestart is. Verwijder daarnaast vóór het starten het slotbestand `playlist_engine/.playlist_engine_watchdog.lock`: dat staat in de backup en kan dus van een vorige boot zijn.

````

**3. Homey Calls**
The stable Homey pattern is one flow per intent. Homey only has to call the engine API.

Start DagMix on Kantoor:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"DagMix","player_name":"Kantoor"}
````

Start DagMix on Woonkamer:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"DagMix","player_name":"Woonkamer"}
```

Start another playlist on Keuken:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"DagAvondMix","player_name":"Keuken"}
```

Start the summer mix on a warm day:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"SummerMix","player_name":"Kantoor"}
```

Start the party mix for a party or as upbeat work music:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"PartyMix","player_name":"Woonkamer"}
```

Preview 10 tracks for Beneden:

```text
GET http://<engine-host>:8787/api/preview?playlist=DagMix&player_name=Beneden&count=10&token=<token>
```

Stop the managed session on Kantoor:

```text
POST http://<engine-host>:8787/api/stop
Header: X-API-Key: <token>
Body: {"player_name":"Kantoor"}
```

Stop **after the current track** (the queue is trimmed to the song that is playing now;
playback ends when that song ends and the player is then powered off, so the bridge
releases the Cast device immediately and the screen returns to its own view right away
instead of showing the receiver for 30 s):

```text
POST http://<engine-host>:8787/api/stop
Header: X-API-Key: <token>
Body: {"player_name":"Kantoor","when":"track"}
```

`when` accepts `track`, `end-of-track`, `after-track` or `after_current_track`. Without
`when` (or with `when: now`) only the engine's management stops, as before.

Homey recommendation:

- Make one Flow per room if you want fixed buttons.
- Make one Advanced Flow that first chooses a player and then posts the corresponding `player_name`.
- Keep the playlist id stable, for example `DagMix`, even if the title shown in LMS changes later.

**4. Add Extra Playlists**
To add a new playlist:

1. Add a new SQL file to the playlist folder, for example `RustMix.sql`.
2. Add a new entry under `playlists` in [playlist_engine_config.example.json](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine_config.example.json).
3. Restart the engine.
4. Check `/api/playlists` to confirm it is visible.
5. Use the same playlist id in Homey and in the LMS menu.

That means the engine remains generic. Every new SQL file becomes another managed playlist without new Python code.

**5. LMS Button**
The LMS bridge is intentionally small. It does not own queue logic. It only shows playlists and calls the engine API.

Behavior:

- LMS shows a `Custom Playlists` menu.
- The user selects the normal LMS player at the top right first.
- Opening `Custom Playlists` shows all enabled playlists from the engine.
- Clicking one starts that playlist on the currently selected LMS player.

**Install The LMS Bridge**

1. Copy [lms_plugin/PlaylistEngineBridge](c:/Users/rickl/Desktop/cti_dagmix_v3/lms_plugin/PlaylistEngineBridge) to your LMS custom plugin directory.
2. Copy [lms_plugin/PlaylistEngineBridge/bridge_config.example.json](c:/Users/rickl/Desktop/cti_dagmix_v3/lms_plugin/PlaylistEngineBridge/bridge_config.example.json) to `bridge_config.json` in that same plugin folder.
3. Set `engine_base_url` and `api_token` in `bridge_config.json`.
4. Optionally set `quick_launch_playlist`, for example `DagAvondMix`, to add a direct start button on the LMS home page.
5. Restart LMS.
6. Enable the plugin if LMS shows it in the plugin list.
7. Select a player in LMS and open `Custom Playlists`.

Because the selected LMS player is passed as `player_id`, you do not need separate menu trees per player.

**6. First Test Sequence**

1. Start the Python engine.
2. Call `/api/health`.
3. Call `/api/playlists`.
4. Call `/api/players`.
5. Start DagMix with `/api/start` for one real player.
6. Check `/api/sessions`.
7. Let the queue run down and verify that tracks are added automatically.
8. Test the LMS menu button.
9. Test the same start action from Homey for a second player.

**Don't Stop The Music**

LMS has a built-in `Don't Stop The Music` (DSTM) feature that keeps adding tracks when a
queue runs out. That is useful when someone plays loose songs, a playlist or an album, but
it competes with the engine once an engine playlist is running.

The bridge therefore tells DSTM to stay away as long as the engine has a session for that
player, and DSTM behaves normally again as soon as that session is gone:

- `install.xml` declares `<canConflictWithDSTM>1</canConflictWithDSTM>`, the hook LMS
  provides for exactly this situation.
- `disableDSTM()` returns true while the engine reports a session for the player.
- Every 20 seconds a helper process fetches `/api/sessions` and stores the managed player
  ids in `/tmp/playlist_engine_bridge_sessions.json`. The helper never blocks the LMS main
  loop, and `disableDSTM()` only reads that small file.
- When the engine cannot be reached the cache expires after 120 seconds and DSTM is allowed
  again, so DSTM becomes the fallback instead of leaving the house silent.
- Set `suppress_dstm_when_engine_active` to `false` in `bridge_config.json` to disable this.

**Logging Which Client Changes The Queue**

To find out which component adds or removes queue entries, create this file:

    touch /tmp/playlist_engine_bridge_debug

The bridge then logs every `playlist` command that LMS executes, including its parameters and
source, plus every DSTM question (`engine actief = ja/nee`), to the LMS log. Delete the file to
stop logging.

**Dubbele of verouderde spelers na het opnieuw koppelen van een Cast-apparaat**

Een Chromecast/JBL die opnieuw aan Google Home wordt gekoppeld, krijgt soms een nieuwe UDN en
daarmee een nieuwe `cc:cc:xx` client-id in LMS. De oude client blijft in de prefs staan en het
oude `<device>`-blok blijft in `castbridge.xml` staan. Gevolg: dezelfde speaker verschijnt twee
keer, een oude naam (`KantoorSpeakerJBL`) blijft hangen, Homey-flows die op `player_name` matchen
vinden niets meer en de engine blijft op een verdwenen `player_id` pollen.

Opruimen:

1. Vergelijk de spelerslijst met de config:
   `curl -s -d '{"id":1,"method":"slim.request","params":["",["players",0,100]]}' http://127.0.0.1:9000/jsonrpc.js`
   en `grep -E "<(udn|name|mac)>" /usr/local/slimserver/prefs/castbridge.xml`.
2. LMS stoppen (`sudo /usr/local/etc/init.d/slimserver stop`, nooit via een pipe).
3. In `prefs/server.prefs` de sectie `_client:<oude-mac>:` verwijderen (loopt tot de volgende
   regel die niet met een spatie begint) en in `castbridge.xml` het bijbehorende `<device>`-blok.
4. LMS starten. De speler heet nu zoals de bridge hem aanmeldt; een afwijkende naam zet je goed
   met de CLI: `["<playerid>",["name","KantoorSpeaker"]]`. Dat schrijft de pref `playername`.
5. Een sessie van de engine op een verdwenen `player_id` kun je niet met `/api/stop` opruimen
   (de speler is niet meer te resolven). Verwijder de rij uit `playlist_engine_state.db`
   (`sessions` en `history`) en herstart de engine; de watchdog doet dat vanzelf.

**Let op:** `castbridge.xml` is regelgebaseerd. Bewerk het alleen line-based (één tag per regel) en
laat de bestaande `<common>`-sectie intact. Een bestand dat de bridge niet kan lezen wordt bij de
start volledig door defaults vervangen (`mode=thru`, `sample_rate=96000`, `binding=?`,
`stop_receiver=0`) en dan krijgen **alle** renderers nieuwe `cc:cc:`-macs, waardoor elke
engine-sessie stukloopt. Maak eerst een back-up en controleer na de start het `sendHELO` in de
bridge-log (`MaxSampleRate=`) en of `<binding>192.168.0.54</binding>` bewaard is gebleven.

**Notes**

- The SQL is the single source of truth for how often a track may be played: the
  rating is a playback-frequency, not a preference. See
  [WAARDERING_POOLS.md](WAARDERING_POOLS.md) for the rating pools, the weights per
  table (day/evening), the cooldowns and the seasonal exceptions.
- Measure the real mix with `python3 tools/rating_mix_report.py --samples 20`.

- The engine is the source of truth for managed sessions and endless refill.
- The LMS bridge is only a launcher.
- Seasonal rules such as Kerst and Sinterklaas remain best kept in SQL.
- Time-of-day switching such as DagMix at 16:00 and AvondMix after 18:00 can now live in the engine through `routing_windows`.
- Generic skip rules such as Live, Karaoke or minimum rating remain easier to manage in JSON.
