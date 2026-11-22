"""Lokale rooktest voor /api/control en /api/zone met een nep-LMS.

Draaien vanaf de repo-root:  python3 tools/test_control_api.py
Schrijft alleen tijdelijke bestanden in .tmp/ (gitignored).
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

import playlist_engine as pe  # noqa: E402

TMP = REPO / ".tmp"
TMP.mkdir(exist_ok=True)


class FakeLms(BaseHTTPRequestHandler):
    players = {
        "aa:aa": {"playerid": "aa:aa", "name": "Kantoor", "modelname": "CastBridge", "connected": 1, "power": 1, "isplaying": 0},
        "bb:bb": {"playerid": "bb:bb", "name": "Laptop", "modelname": "Squeezelite-X", "connected": 1, "power": 1, "isplaying": 1},
    }
    state = {
        "aa:aa": {"mode": "stop", "power": 1, "mixer volume": 40, "playlist_tracks": 0, "playlist_cur_index": 0, "time": 0},
        "bb:bb": {"mode": "play", "power": 1, "mixer volume": 42, "playlist_tracks": 6, "playlist_cur_index": 1, "time": 12.0},
    }
    commands = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length).decode())
        ref, params = payload["params"][0], payload["params"][1]
        FakeLms.commands.append((ref, params))

        if params[0] == "players":
            body = {"result": {"count": 2, "players_loop": list(FakeLms.players.values())}}
        elif params[0] == "status":
            body = {"result": dict(FakeLms.state[ref], connected=1)}
        elif params[0] == "mixer" and params[1] == "volume":
            value = params[2]
            current = FakeLms.state[ref]["mixer volume"]
            new = current + int(value) if value[0] in "+-" else int(value)
            FakeLms.state[ref]["mixer volume"] = max(0, min(100, new))
            body = {"result": {}}
        elif params[0] == "mixer" and params[1] == "muting":
            current = FakeLms.state[ref]["mixer volume"]
            fake = {"toggle": None}
            if params[2] == "toggle":
                FakeLms.state[ref]["mixer volume"] = -abs(current) if current > 0 else abs(current)
            else:
                FakeLms.state[ref]["mixer volume"] = -abs(current) if params[2] == "1" else abs(current)
            body = {"result": {}}
        elif params[0] == "pause":
            FakeLms.state[ref]["mode"] = "pause" if params[1] == "1" else "play"
            body = {"result": {}}
        elif params[0] == "play":
            FakeLms.state[ref]["mode"] = "play"
            body = {"result": {}}
        elif params[0] == "playlist" and params[1] == "index":
            step = int(params[2])
            FakeLms.state[ref]["playlist_cur_index"] += 1 if step > 0 else -1
            body = {"result": {}}
        else:
            body = {"result": {}}

        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass


def build_engine(port: int) -> pe.PlaylistEngineApp:
    config_path = TMP / "test_engine_config.json"
    config_path.write_text(
        json.dumps(
            {
                "api": {"host": "127.0.0.1", "port": 0, "token": "x"},
                "lms": {"base_url": f"http://127.0.0.1:{port}"},
                "engine": {
                    "playlists_dir": str(REPO),
                    "auto_discover_playlists": False,
                    "state_db": str(TMP / "test_state.db"),
                },
                "rooms": {
                    "Kantoor": {"players": ["Kantoor", "Laptop"], "default": "Kantoor", "volume_step": 5},
                    "Zolder": ["Niemand"],
                },
            }
        ),
        encoding="utf-8",
    )
    state_db = TMP / "test_state.db"
    if state_db.exists():
        state_db.unlink()
    return pe.PlaylistEngineApp(pe.EngineConfig.load(config_path))


def check(label, condition, extra=""):
    print(("PASS " if condition else "FAIL ") + label + (f"  {extra}" if extra else ""))
    if not condition:
        raise SystemExit(1)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeLms)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]

    app = build_engine(port)
    manager = app.session_manager

    zone = manager.zone_state("Kantoor")
    check("zone kiest de spelende speler", zone["player_name"] == "Laptop", zone["resolved_by"])
    check("zone leest volume", zone["volume"] == 42 and zone["muted"] is False, str(zone["volume"]))

    result = manager.control_player("volume_up", room="Kantoor")
    check("volume_up -> 47", result["volume"] == 47, str(result["volume"]))
    absolute = ("bb:bb", ["mixer", "volume", "47"]) in FakeLms.commands
    check("volume_up stuurt absolute waarde", absolute, str(FakeLms.commands[-3:]))

    result = manager.control_player("volume", room="Kantoor", delta=-10)
    check("volume delta -10 -> 37", result["volume"] == 37, str(result["volume"]))

    result = manager.control_player("mute", room="Kantoor")
    check("mute -> muted True", result["muted"] is True and result["volume"] == 37, str(result["muted"]))

    result = manager.control_player("mute", room="Kantoor")
    check("mute nog eens -> unmuted", result["muted"] is False, str(result["muted"]))

    result = manager.control_player("play_pause", room="Kantoor")
    check("play_pause tijdens play -> paused", result["paused"] is True, str(result["mode"]))
    result = manager.control_player("play_pause", room="Kantoor")
    check("play_pause nog eens -> playing", result["playing"] is True, str(result["mode"]))

    before = FakeLms.state["bb:bb"]["playlist_cur_index"]
    result = manager.control_player("next", room="Kantoor")
    check("next -> index +1", FakeLms.state["bb:bb"]["playlist_cur_index"] == before + 1, str(FakeLms.state["bb:bb"]["playlist_cur_index"]))
    check("next markeert remote skip", "bb:bb" in manager._expected_skip_until)

    # Kantoor gaat spelen, Laptop stopt: nu moet Kantoor gekozen worden.
    FakeLms.state["aa:aa"].update({"mode": "play", "playlist_tracks": 4})
    FakeLms.state["bb:bb"].update({"mode": "stop"})
    manager._note_activity("bb:bb", "Laptop", "play")
    zone = manager.zone_state("Kantoor")
    check("zone volgt de nieuwe speler", zone["player_name"] == "Kantoor", zone["resolved_by"])

    # Niets speelt: laatste activiteit wint (Laptop was net actief).
    FakeLms.state["aa:aa"].update({"mode": "stop"})
    FakeLms.players["aa:aa"]["isplaying"] = 0
    FakeLms.players["bb:bb"]["isplaying"] = 0
    manager._note_activity("aa:aa", "Kantoor", "play")
    time.sleep(1.1)
    manager._note_activity("bb:bb", "Laptop", "pause")
    zone = manager.zone_state("Kantoor")
    check("zonder weergave wint laatst actief", zone["player_name"] == "Laptop", zone["resolved_by"])

    # Expliciete speler wint van de kamerkeuze.
    result = manager.control_player("volume_up", room="Kantoor", player_name="Kantoor")
    check("player_name forceert de speler", result["player_name"] == "Kantoor", result["resolved_by"])

    # Lege wachtrij -> 409 bij next.
    FakeLms.state["aa:aa"]["playlist_tracks"] = 0
    try:
        manager.control_player("next", room="Kantoor", player_name="Kantoor")
        check("next zonder wachtrij faalt", False)
    except pe.RequestError as exc:
        check("next zonder wachtrij faalt", exc.status == 409, str(exc))

    # Stilstaande speler met wachtrij: next zou de weergave starten -> 409.
    FakeLms.state["aa:aa"]["playlist_tracks"] = 3
    try:
        manager.control_player("next", room="Kantoor", player_name="Kantoor")
        check("next op een stilstaande speler faalt", False)
    except pe.RequestError as exc:
        check("next op een stilstaande speler faalt", exc.status == 409, str(exc))
    check("en start de weergave niet", FakeLms.state["aa:aa"]["mode"] == "stop", FakeLms.state["aa:aa"]["mode"])

    # Onbekende kamer en onbekende actie.
    for action, room, code in (("volume_up", "Kelder", 404), ("dansen", "Kantoor", 400)):
        try:
            manager.control_player(action, room=room, player_name="Kantoor")
            check(f"{action}/{room} faalt", False)
        except pe.RequestError as exc:
            check(f"{action}/{room} faalt", exc.status == code, str(exc))

    # Offline: een speler die LMS nooit gezien heeft.
    unnamed = manager.player_state("Onbekend", None)
    check("onbekende speler is offline", unnamed["online"] is False and unnamed["state"] == "offline", str(unnamed["state"]))
    check("offline speler heeft geen volume", unnamed["volume"] is None, str(unnamed["volume"]))

    # Offline: wel bekend, maar de verbinding is weg (laptop uit).
    FakeLms.players["off:01"] = {
        "playerid": "off:01",
        "name": "LaptopOff",
        "modelname": "Squeezelite",
        "connected": 0,
        "power": 0,
        "isplaying": 0,
    }
    FakeLms.state["off:01"] = {"mode": "stop", "power": 0, "mixer volume": 30, "playlist_tracks": 0, "playlist_cur_index": 0, "time": 0}
    disconnected = manager.player_state("LaptopOff", None)
    check(
        "losgekoppelde speler is offline",
        disconnected["online"] is False and disconnected["player_id"] == "off:01",
        str(disconnected),
    )

    # Een kamer waar niemand van verbonden is levert ook een geldige stand.
    leeg = manager.zone_state("Zolder")
    check("lege kamer is offline", leeg["online"] is False and leeg["members"] == [], str(leeg))

    online = manager.player_state("Laptop", None)
    check("verbonden speler is online", online["online"] is True, str(online["online"]))

    print("\nAlle manager-checks geslaagd.")
    check_http(app)
    server.shutdown()
    print("\nAlle checks geslaagd.")
    return 0


def check_http(app) -> None:
    """Controleert de API-laag zoals Homey hem gebruikt."""
    import urllib.error
    import urllib.request

    handler_class = type("TestApiHandler", (pe.PlaylistApiHandler,), {})
    handler_class.engine = app
    api = ThreadingHTTPServer(("127.0.0.1", 0), handler_class)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{api.server_address[1]}"

    def call(path, body=None, token=True):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, method="POST" if body is not None else "GET")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("X-API-Key", "x")
        with urllib.request.urlopen(req) as response:
            return response.read().decode("utf-8")

    rooms = json.loads(call("/api/rooms"))
    check("/api/rooms noemt de kamer", rooms["rooms"][0]["name"] == "Kantoor", str(rooms))

    zone = json.loads(call("/api/zone?room=Kantoor"))
    check("/api/zone geeft een speler", bool(zone.get("player_name")), str(zone.get("player_name")))

    payload = json.loads(call("/api/control?token=x", {"action": "volume", "delta": 3, "room": "Kantoor"}))
    check("/api/control via body", payload["ok"] is True, str(payload.get("changed")))

    payload = json.loads(call("/api/control?action=volume_down&room=Kantoor"))
    check("/api/control via query", payload["action"] == "volume_down")

    payload = json.loads(call("/api/state?room=Kantoor"))
    check("/api/state met room", payload["resolved_by"] != "explicit", str(payload["resolved_by"]))
    check("/api/state bevat volume", "volume" in payload and "muted" in payload, str(payload.get("volume")))

    text = call("/api/playing?room=Kantoor")
    check("/api/playing met room", text in {"true", "false"}, text)

    check("/api/online voor verbonden speler", call("/api/online?player_name=Laptop") == "true")
    check("/api/online voor losgekoppelde speler", call("/api/online?player_name=LaptopOff") == "false")
    check("/api/online voor onbekende speler", call("/api/online?player_name=Bestaatniet") == "false")
    check("/api/playing offline is false, geen fout", call("/api/playing?player_name=Bestaatniet") == "false")

    offline_state = json.loads(call("/api/state?player_name=Bestaatniet"))
    check("/api/state offline", offline_state["online"] is False and offline_state["state"] == "offline", str(offline_state))

    empty_zone = json.loads(call("/api/zone?room=Zolder"))
    check("/api/zone zonder leden", empty_zone["online"] is False, str(empty_zone))

    try:
        call("/api/zone?room=Kantoor", token=False)
        check("auth verplicht", False)
    except urllib.error.HTTPError as exc:
        check("auth verplicht", exc.code == 401, str(exc.code))

    api.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
