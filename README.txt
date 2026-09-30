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
- Dec 1-9: 30%
- Dec 10-19: 65%
- Dec 20-26: 100%
- Dec 27-Nov 30: 0%

SINTERKLAAS SCHEDULE (local LMS time)
- Dec 5: 33%
- all other days: 0%

NORMAL MIX TARGET
- Hits: 35%
- Other: 65%
- Oldies, Party and Fout are no longer explicit target buckets in DagMix

RATING
- < 2 stars: excluded
- unrated: excluded from automatic playback
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
