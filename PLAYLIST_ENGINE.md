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
- LMS can show a `Custom Playlists` menu and start playback on the player currently selected in LMS.

**1. Configure The Engine**
Copy [playlist_engine_config.example.json](c:/Users/rickl/Desktop/cti_dagmix_v3/playlist_engine_config.example.json) to your real config file and adjust at least:

- `api.token`
- `lms.base_url`
- `lms.library_db`
- `lms.persist_db`
- `engine.playlists_dir`

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
  }
}
```

If `engine.auto_discover_playlists` is `true`, extra `.sql` files in the playlist folder are also picked up automatically.

`routing_windows` are evaluated in the engine host's local time. This lets one logical playlist switch source SQL during playback top-ups without starting a new LMS session.

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
```

**3. Homey Calls**
The stable Homey pattern is one flow per intent. Homey only has to call the engine API.

Start DagMix on Kantoor:

```text
POST http://<engine-host>:8787/api/start
Header: X-API-Key: <token>
Body: {"playlist":"DagMix","player_name":"Kantoor"}
```

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
4. Restart LMS.
5. Enable the plugin if LMS shows it in the plugin list.
6. Select a player in LMS and open `Custom Playlists`.

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

**Notes**
- The engine is the source of truth for managed sessions and endless refill.
- The LMS bridge is only a launcher.
- Seasonal rules such as Kerst and Sinterklaas remain best kept in SQL.
- Time-of-day switching such as DagMix at 16:00 and AvondMix after 18:00 can now live in the engine through `routing_windows`.
- Generic skip rules such as Live, Karaoke or minimum rating remain easier to manage in JSON.