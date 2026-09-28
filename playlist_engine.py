#!/usr/bin/env python3
import argparse
import json
import logging
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence
from urllib import error, parse, request


LOGGER = logging.getLogger("playlist-engine")
SQL_COMMENT_RE = re.compile(r"^\s*--.*$", re.MULTILINE)
SQL_WHITESPACE_RE = re.compile(r"\s+")


def read_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_path(base_dir: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def flatten_sql(sql_text: str) -> str:
    without_comments = SQL_COMMENT_RE.sub("", sql_text)
    flattened = SQL_WHITESPACE_RE.sub(" ", without_comments).strip()
    return flattened[:-1] if flattened.endswith(";") else flattened


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: Dict[str, Any]) -> None:
    raw = json.dumps(payload, ensure_ascii=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


class RequestError(Exception):
    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class PlaylistDefinition:
    identifier: str
    title: str
    sql_path: Path
    enabled: bool
    initial_count: int
    topup_count: int
    low_watermark: int
    description: str
    start_with_genre: str

    def to_api_payload(self) -> Dict[str, Any]:
        return {
            "id": self.identifier,
            "title": self.title,
            "sql_file": self.sql_path.name,
            "enabled": self.enabled,
            "initial_count": self.initial_count,
            "topup_count": self.topup_count,
            "low_watermark": self.low_watermark,
            "description": self.description,
            "start_with_genre": self.start_with_genre,
        }


@dataclass
class EngineConfig:
    config_path: Path
    listen_host: str
    listen_port: int
    api_token: str
    lms_base_url: str
    library_db: Path
    persist_db: Path
    playlists_dir: Path
    state_db: Path
    poll_interval_seconds: int
    default_initial_count: int
    default_topup_count: int
    default_low_watermark: int
    candidate_multiplier: int
    history_reset_on_exhaustion: bool
    auto_discover_playlists: bool
    skip_rules: List[Dict[str, Any]]
    playlists: Dict[str, PlaylistDefinition]

    @classmethod
    def load(cls, config_path: Path) -> "EngineConfig":
        raw = read_json(config_path)
        base_dir = config_path.parent.resolve()

        api = raw.get("api", {})
        lms = raw.get("lms", {})
        engine = raw.get("engine", {})

        playlists_dir = resolve_path(base_dir, engine.get("playlists_dir", "."))
        default_initial_count = int(engine.get("default_initial_count", 20))
        default_topup_count = int(engine.get("default_topup_count", 10))
        default_low_watermark = int(engine.get("default_low_watermark", 5))
        playlist_overrides = dict(raw.get("playlist_overrides", {}))
        configured_playlists = dict(raw.get("playlists", {}))
        auto_discover_playlists = bool(engine.get("auto_discover_playlists", True))

        playlist_catalog: Dict[str, PlaylistDefinition] = {}

        for playlist_id, playlist_config in configured_playlists.items():
            merged_config = dict(playlist_config)
            merged_config.update(playlist_overrides.get(playlist_id, {}))
            sql_file = merged_config.get("sql_file", f"{playlist_id}.sql")
            sql_path = resolve_path(playlists_dir, sql_file)
            playlist_catalog[playlist_id] = PlaylistDefinition(
                identifier=playlist_id,
                title=str(merged_config.get("title", playlist_id)),
                sql_path=sql_path,
                enabled=bool(merged_config.get("enabled", True)),
                initial_count=int(merged_config.get("initial_count", default_initial_count)),
                topup_count=int(merged_config.get("topup_count", default_topup_count)),
                low_watermark=int(merged_config.get("low_watermark", default_low_watermark)),
                description=str(merged_config.get("description", "")).strip(),
                start_with_genre=str(merged_config.get("start_with_genre", "")).strip(),
            )

        if auto_discover_playlists and playlists_dir.exists():
            for sql_path in sorted(playlists_dir.glob("*.sql")):
                playlist_id = sql_path.stem
                if playlist_id in playlist_catalog:
                    continue
                merged_config = dict(playlist_overrides.get(playlist_id, {}))
                playlist_catalog[playlist_id] = PlaylistDefinition(
                    identifier=playlist_id,
                    title=str(merged_config.get("title", playlist_id)),
                    sql_path=sql_path,
                    enabled=bool(merged_config.get("enabled", True)),
                    initial_count=int(merged_config.get("initial_count", default_initial_count)),
                    topup_count=int(merged_config.get("topup_count", default_topup_count)),
                    low_watermark=int(merged_config.get("low_watermark", default_low_watermark)),
                    description=str(merged_config.get("description", "")).strip(),
                    start_with_genre=str(merged_config.get("start_with_genre", "")).strip(),
                )

        return cls(
            config_path=config_path.resolve(),
            listen_host=api.get("host", "0.0.0.0"),
            listen_port=int(api.get("port", 8787)),
            api_token=api.get("token", ""),
            lms_base_url=lms.get("base_url", "http://127.0.0.1:9000").rstrip("/"),
            library_db=resolve_path(base_dir, lms.get("library_db", "library.db")),
            persist_db=resolve_path(base_dir, lms.get("persist_db", "persist.db")),
            playlists_dir=playlists_dir,
            state_db=resolve_path(base_dir, engine.get("state_db", "playlist_engine_state.db")),
            poll_interval_seconds=int(engine.get("poll_interval_seconds", 10)),
            default_initial_count=default_initial_count,
            default_topup_count=default_topup_count,
            default_low_watermark=default_low_watermark,
            candidate_multiplier=int(engine.get("candidate_multiplier", 4)),
            history_reset_on_exhaustion=bool(engine.get("history_reset_on_exhaustion", True)),
            auto_discover_playlists=auto_discover_playlists,
            skip_rules=list(raw.get("skip_rules", [])),
            playlists=playlist_catalog,
        )

    def playlist_definition(self, playlist_name: str) -> PlaylistDefinition:
        playlist = self.playlists.get(playlist_name)
        if not playlist or not playlist.enabled:
            raise RequestError(f"Playlist not found or disabled: {playlist_name}", HTTPStatus.NOT_FOUND)
        if not playlist.sql_path.exists():
            raise RequestError(f"Playlist SQL not found: {playlist.sql_path}", HTTPStatus.NOT_FOUND)
        return playlist

    def playlist_payloads(self) -> List[Dict[str, Any]]:
        return [
            playlist.to_api_payload()
            for playlist in sorted(self.playlists.values(), key=lambda item: item.title.lower())
            if playlist.enabled
        ]


class StateStore:
    def __init__(self, state_db: Path):
        self.state_db = state_db
        self.state_db.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.state_db)
        connection.row_factory = sqlite3.Row
        return connection

    def _init_db(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                create table if not exists sessions (
                    player_id text primary key,
                    player_name text not null,
                    playlist_name text not null,
                    started_at integer not null,
                    initial_count integer not null,
                    topup_count integer not null,
                    low_watermark integer not null,
                    active integer not null default 1
                );

                create table if not exists history (
                    player_id text not null,
                    playlist_name text not null,
                    track_id integer not null,
                    queued_at integer not null,
                    primary key (player_id, playlist_name, track_id)
                );
                """
            )

    def save_session(self, player_id: str, player_name: str, playlist_name: str, playlist: PlaylistDefinition) -> None:
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("delete from history where player_id = ?", (player_id,))
            connection.execute(
                """
                insert into sessions (
                    player_id, player_name, playlist_name, started_at, initial_count, topup_count, low_watermark, active
                ) values (?, ?, ?, ?, ?, ?, ?, 1)
                on conflict(player_id) do update set
                    player_name = excluded.player_name,
                    playlist_name = excluded.playlist_name,
                    started_at = excluded.started_at,
                    initial_count = excluded.initial_count,
                    topup_count = excluded.topup_count,
                    low_watermark = excluded.low_watermark,
                    active = 1
                """,
                (
                    player_id,
                    player_name,
                    playlist_name,
                    now,
                    playlist.initial_count,
                    playlist.topup_count,
                    playlist.low_watermark,
                ),
            )

    def stop_session(self, player_id: str) -> None:
        with self._connect() as connection:
            connection.execute("delete from sessions where player_id = ?", (player_id,))
            connection.execute("delete from history where player_id = ?", (player_id,))

    def list_sessions(self) -> List[Dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "select player_id, player_name, playlist_name, started_at, initial_count, topup_count, low_watermark from sessions where active = 1 order by player_name collate nocase"
            ).fetchall()
        return [dict(row) for row in rows]

    def add_history(self, player_id: str, playlist_name: str, track_ids: Sequence[int]) -> None:
        now = int(time.time())
        with self._connect() as connection:
            connection.executemany(
                "insert or ignore into history (player_id, playlist_name, track_id, queued_at) values (?, ?, ?, ?)",
                [(player_id, playlist_name, int(track_id), now) for track_id in track_ids],
            )

    def history_for_player(self, player_id: str, playlist_name: str) -> List[int]:
        with self._connect() as connection:
            rows = connection.execute(
                "select track_id from history where player_id = ? and playlist_name = ? order by queued_at asc",
                (player_id, playlist_name),
            ).fetchall()
        return [int(row[0]) for row in rows]

    def clear_history(self, player_id: str, playlist_name: str) -> None:
        with self._connect() as connection:
            connection.execute(
                "delete from history where player_id = ? and playlist_name = ?",
                (player_id, playlist_name),
            )


class LmsClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def _request(self, player_ref: str, params: List[Any]) -> Dict[str, Any]:
        payload = {
            "id": 1,
            "method": "slim.request",
            "params": [player_ref, params],
        }
        body = json.dumps(payload).encode("utf-8")
        req = request.Request(
            url=f"{self.base_url}/jsonrpc.js",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with request.urlopen(req, timeout=60) as response:
                return json.loads(response.read().decode("utf-8"))
        except error.URLError as exc:
            raise RequestError(f"LMS request failed: {exc}", HTTPStatus.BAD_GATEWAY) from exc

    def list_players(self) -> List[Dict[str, Any]]:
        result = self._request("", ["players", 0, 100])
        return list(result.get("result", {}).get("players_loop", []))

    def resolve_player(self, player_name: Optional[str], player_id: Optional[str]) -> Dict[str, Any]:
        players = self.list_players()

        if player_id:
            exact = [player for player in players if player.get("playerid") == player_id]
            if exact:
                return exact[0]

        if player_name:
            exact = [player for player in players if player.get("name") == player_name]
            if len(exact) == 1:
                return exact[0]

            partial = [player for player in players if player_name.lower() in player.get("name", "").lower()]
            if len(partial) == 1:
                return partial[0]

        raise RequestError("Could not resolve LMS player.", HTTPStatus.NOT_FOUND)

    def status(self, player_id: str) -> Dict[str, Any]:
        result = self._request(player_id, ["status", 0, 500, "tags:cgABbehldiqtyrSSuoKLNJ"])
        return dict(result.get("result", {}))

    def power_on(self, player_id: str) -> None:
        self._request(player_id, ["power", 1])

    def play_track(self, player_id: str, track_id: int) -> None:
        self._request(player_id, ["playlist", "playtracks", f"track.id={track_id}"])

    def add_track(self, player_id: str, track_id: int) -> None:
        self._request(player_id, ["playlist", "addtracks", f"track.id={track_id}"])

    def play(self, player_id: str) -> None:
        self._request(player_id, ["play"])


class TrackSelector:
    def __init__(self, config: EngineConfig, state_store: StateStore):
        self.config = config
        self.state_store = state_store

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.config.library_db)
        connection.row_factory = sqlite3.Row
        connection.execute("attach database ? as persist", (str(self.config.persist_db),))
        return connection

    def _prepare_sql(self, sql_text: str, player_id: str, limit: int) -> str:
        prepared = flatten_sql(sql_text)
        prepared = prepared.replace("'PlaylistPlayer'", f"'{player_id}'")
        prepared = prepared.replace("'PlaylistLimit'", str(limit))
        prepared = prepared.replace("PlaylistLimit", str(limit))
        prepared = prepared.replace("'PlaylistOffset'", "0")
        prepared = prepared.replace("PlaylistOffset", "0")
        prepared = prepared.replace("'PlaylistTrackMinDuration'", "90")
        prepared = prepared.replace("PlaylistTrackMinDuration", "90")
        if re.search(r"\blimit\b", prepared, re.IGNORECASE):
            return prepared
        return f"{prepared} limit {limit}"

    def _fetch_metadata(self, connection: sqlite3.Connection, track_ids: Sequence[int]) -> Dict[int, Dict[str, Any]]:
        if not track_ids:
            return {}

        placeholders = ",".join("?" for _ in track_ids)
        rows = connection.execute(
            f"""
            select
                t.id,
                t.title,
                t.url,
                t.secs,
                coalesce(tp.rating, 0) as rating,
                group_concat(distinct g.name) as genres
            from tracks t
            left join persist.tracks_persistent tp on tp.urlmd5 = t.urlmd5
            left join genre_track gt on gt.track = t.id
            left join genres g on g.id = gt.genre
            where t.id in ({placeholders})
            group by t.id, t.title, t.url, t.secs, tp.rating
            """,
            [int(track_id) for track_id in track_ids],
        ).fetchall()

        metadata: Dict[int, Dict[str, Any]] = {}
        for row in rows:
            genres: List[str] = []
            if row["genres"]:
                genres = [genre.strip() for genre in str(row["genres"]).split(",") if genre.strip()]
            metadata[int(row["id"])] = {
                "id": int(row["id"]),
                "title": row["title"],
                "url": row["url"],
                "secs": row["secs"],
                "rating": int(row["rating"] or 0),
                "genres": genres,
            }
        return metadata

    def _passes_skip_rules(self, track: Dict[str, Any]) -> bool:
        for rule in self.config.skip_rules:
            if not rule.get("enabled", True):
                continue

            kind = rule.get("kind")
            if kind == "exclude_genre":
                blocked = str(rule.get("value", "")).strip().lower()
                if blocked and any(blocked == genre.lower() for genre in track.get("genres", [])):
                    return False

            if kind == "min_rating_stars":
                minimum_stars = float(rule.get("value", 0))
                minimum_rating = int(minimum_stars * 20)
                rating = int(track.get("rating", 0) or 0)
                if rating > 0 and rating < minimum_rating:
                    return False

        return True

    @staticmethod
    def _has_genre(track: Dict[str, Any], genre_name: str) -> bool:
        wanted = genre_name.strip().lower()
        return bool(wanted) and any(wanted == genre.lower() for genre in track.get("genres", []))

    def choose_start_track(
        self,
        playlist_name: str,
        player_id: str,
        current_queue_ids: Sequence[int],
        preferred_genre: str,
    ) -> Optional[Dict[str, Any]]:
        if not preferred_genre:
            return None

        playlist = self.config.playlist_definition(playlist_name)
        sql_text = playlist.sql_path.read_text(encoding="utf-8")
        history_ids = set(self.state_store.history_for_player(player_id, playlist_name))
        current_ids = {int(track_id) for track_id in current_queue_ids}

        with self._connect() as connection:
            candidate_limit = max(playlist.initial_count * self.config.candidate_multiplier * 3, 80)
            query = self._prepare_sql(sql_text, player_id, candidate_limit)
            rows = connection.execute(query).fetchall()
            track_ids = [int(row[0]) for row in rows if row[0] is not None]
            metadata = self._fetch_metadata(connection, track_ids)

            for track_id in track_ids:
                if track_id in history_ids or track_id in current_ids:
                    continue
                track = metadata.get(track_id)
                if not track:
                    continue
                if not self._passes_skip_rules(track):
                    continue
                if self._has_genre(track, preferred_genre):
                    return track

        return None

    def choose_tracks(self, playlist_name: str, player_id: str, desired_count: int, current_queue_ids: Sequence[int]) -> List[Dict[str, Any]]:
        playlist = self.config.playlist_definition(playlist_name)
        sql_text = playlist.sql_path.read_text(encoding="utf-8")
        history_ids = set(self.state_store.history_for_player(player_id, playlist_name))
        current_ids = {int(track_id) for track_id in current_queue_ids}
        desired_count = max(1, desired_count)

        attempts = 0
        selected: List[Dict[str, Any]] = []
        exhausted_once = False

        with self._connect() as connection:
            while len(selected) < desired_count and attempts < 4:
                candidate_limit = max(desired_count * self.config.candidate_multiplier * (attempts + 1), desired_count)
                query = self._prepare_sql(sql_text, player_id, candidate_limit)
                LOGGER.debug("Selecting tracks for %s on %s with limit %s", playlist_name, player_id, candidate_limit)
                rows = connection.execute(query).fetchall()
                track_ids = [int(row[0]) for row in rows if row[0] is not None]

                if not track_ids and history_ids and self.config.history_reset_on_exhaustion and not exhausted_once:
                    LOGGER.info("Resetting session history for %s/%s because the candidate set was exhausted.", player_id, playlist_name)
                    self.state_store.clear_history(player_id, playlist_name)
                    history_ids.clear()
                    exhausted_once = True
                    continue

                metadata = self._fetch_metadata(connection, track_ids)
                selected_before_attempt = len(selected)
                for track_id in track_ids:
                    if len(selected) >= desired_count:
                        break
                    if track_id in history_ids or track_id in current_ids:
                        continue
                    track = metadata.get(track_id)
                    if not track:
                        continue
                    if not self._passes_skip_rules(track):
                        continue
                    selected.append(track)
                    history_ids.add(track_id)
                    current_ids.add(track_id)

                if (
                    len(selected) == selected_before_attempt
                    and history_ids
                    and self.config.history_reset_on_exhaustion
                    and not exhausted_once
                ):
                    LOGGER.info(
                        "Resetting session history for %s/%s because only already queued or filtered candidates remained.",
                        player_id,
                        playlist_name,
                    )
                    self.state_store.clear_history(player_id, playlist_name)
                    history_ids.clear()
                    exhausted_once = True
                    continue

                attempts += 1

        return selected


class SessionManager:
    def __init__(self, config: EngineConfig, lms: LmsClient, state_store: StateStore, selector: TrackSelector):
        self.config = config
        self.lms = lms
        self.state_store = state_store
        self.selector = selector
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start_background_loop(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run_loop, name="playlist-engine-loop", daemon=True)
        self._thread.start()

    def stop_background_loop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.maintain_sessions()
            except Exception:
                LOGGER.exception("Unexpected error in maintenance loop")
            self._stop_event.wait(self.config.poll_interval_seconds)

    def maintain_sessions(self) -> None:
        for session in self.state_store.list_sessions():
            player_id = session["player_id"]
            try:
                status = self.lms.status(player_id)
            except RequestError:
                LOGGER.warning("Could not read LMS status for player %s", player_id)
                continue

            mode = str(status.get("mode") or "").lower()
            power = int(status.get("power") or 0)
            if power == 0 or mode in {"pause", "stop"}:
                LOGGER.info("Stopping custom playlist session for %s because player state is mode=%s power=%s", player_id, mode, power)
                self.state_store.stop_session(player_id)
                continue

            queue_ids = [int(item["id"]) for item in status.get("playlist_loop", []) if str(item.get("id", "")).isdigit()]
            current_index = int(status.get("playlist_cur_index") or 0)
            total_tracks = max(int(status.get("playlist_tracks") or 0), len(queue_ids))
            remaining = max(total_tracks - current_index - 1, 0)

            if remaining > int(session["low_watermark"]):
                continue

            tracks = self.selector.choose_tracks(
                playlist_name=session["playlist_name"],
                player_id=player_id,
                desired_count=int(session["topup_count"]),
                current_queue_ids=queue_ids,
            )
            if not tracks:
                LOGGER.warning("No top-up tracks found for %s on %s", session["playlist_name"], player_id)
                continue

            for track in tracks:
                self.lms.add_track(player_id, track["id"])

            if remaining == 0:
                self.lms.play(player_id)

            self.state_store.add_history(player_id, session["playlist_name"], [track["id"] for track in tracks])
            LOGGER.info("Added %s tracks to %s on %s", len(tracks), session["playlist_name"], player_id)

    def start_playlist(self, playlist_name: str, player_name: Optional[str], player_id: Optional[str]) -> Dict[str, Any]:
        playlist = self.config.playlist_definition(playlist_name)
        player = self.lms.resolve_player(player_name, player_id)
        resolved_player_id = player["playerid"]
        resolved_player_name = player["name"]
        current_status = self.lms.status(resolved_player_id)
        queue_ids = [int(item["id"]) for item in current_status.get("playlist_loop", []) if str(item.get("id", "")).isdigit()]

        tracks: List[Dict[str, Any]] = []
        start_track = self.selector.choose_start_track(
            playlist_name,
            resolved_player_id,
            queue_ids,
            playlist.start_with_genre,
        )
        if start_track:
            tracks.append(start_track)
            queue_ids = list(queue_ids) + [start_track["id"]]

        remaining_count = max(playlist.initial_count - len(tracks), 0)
        if remaining_count > 0:
            tracks.extend(self.selector.choose_tracks(playlist_name, resolved_player_id, remaining_count, queue_ids))

        if not tracks:
            raise RequestError(f"Playlist {playlist_name} returned no tracks after filtering.", HTTPStatus.CONFLICT)

        self.lms.power_on(resolved_player_id)
        self.lms.play_track(resolved_player_id, tracks[0]["id"])
        for track in tracks[1:]:
            self.lms.add_track(resolved_player_id, track["id"])
        self.lms.play(resolved_player_id)

        self.state_store.save_session(resolved_player_id, resolved_player_name, playlist_name, playlist)
        self.state_store.add_history(resolved_player_id, playlist_name, [track["id"] for track in tracks])

        return {
            "player_id": resolved_player_id,
            "player_name": resolved_player_name,
            "playlist": playlist_name,
            "playlist_title": playlist.title,
            "queued_tracks": len(tracks),
            "tracks": tracks,
        }

    def preview_playlist(self, playlist_name: str, player_name: Optional[str], player_id: Optional[str], count: int) -> Dict[str, Any]:
        playlist = self.config.playlist_definition(playlist_name)
        player = self.lms.resolve_player(player_name, player_id)
        status = self.lms.status(player["playerid"])
        queue_ids = [int(item["id"]) for item in status.get("playlist_loop", []) if str(item.get("id", "")).isdigit()]
        tracks = self.selector.choose_tracks(playlist_name, player["playerid"], count, queue_ids)
        return {
            "player_id": player["playerid"],
            "player_name": player["name"],
            "playlist": playlist_name,
            "playlist_title": playlist.title,
            "tracks": tracks,
        }

    def stop_playlist(self, player_name: Optional[str], player_id: Optional[str]) -> Dict[str, Any]:
        player = self.lms.resolve_player(player_name, player_id)
        self.state_store.stop_session(player["playerid"])
        return {
            "player_id": player["playerid"],
            "player_name": player["name"],
            "stopped": True,
        }


class PlaylistApiHandler(BaseHTTPRequestHandler):
    engine: "PlaylistEngineApp" = None  # type: ignore[assignment]

    def do_GET(self) -> None:
        self._handle_request()

    def do_POST(self) -> None:
        self._handle_request()

    def log_message(self, format: str, *args: Any) -> None:
        LOGGER.info("%s - %s", self.address_string(), format % args)

    def _handle_request(self) -> None:
        try:
            self._check_auth()
            parsed = parse.urlparse(self.path)
            route = parsed.path.rstrip("/") or "/"
            payload = self._read_json_body()
            query = parse.parse_qs(parsed.query)

            if route == "/api/health":
                json_response(self, HTTPStatus.OK, {"ok": True})
                return

            if route == "/api/playlists":
                items = self.engine.config.playlist_payloads()
                json_response(self, HTTPStatus.OK, {"playlists": [item["id"] for item in items], "items": items})
                return

            if route == "/api/players":
                players = self.engine.lms.list_players()
                json_response(
                    self,
                    HTTPStatus.OK,
                    {
                        "players": [
                            {
                                "player_id": player.get("playerid"),
                                "player_name": player.get("name"),
                                "model": player.get("modelname"),
                                "connected": player.get("connected"),
                                "power": player.get("power"),
                            }
                            for player in players
                        ]
                    },
                )
                return

            if route == "/api/sessions":
                json_response(self, HTTPStatus.OK, {"sessions": self.engine.state_store.list_sessions()})
                return

            if route == "/api/start":
                playlist = self._param(payload, query, "playlist", required=True)
                player_name = self._param(payload, query, "player_name")
                player_id = self._param(payload, query, "player_id")
                result = self.engine.session_manager.start_playlist(playlist, player_name, player_id)
                json_response(self, HTTPStatus.OK, result)
                return

            if route == "/api/preview":
                playlist = self._param(payload, query, "playlist", required=True)
                player_name = self._param(payload, query, "player_name")
                player_id = self._param(payload, query, "player_id")
                count = int(self._param(payload, query, "count") or 10)
                result = self.engine.session_manager.preview_playlist(playlist, player_name, player_id, count)
                json_response(self, HTTPStatus.OK, result)
                return

            if route == "/api/stop":
                player_name = self._param(payload, query, "player_name")
                player_id = self._param(payload, query, "player_id")
                result = self.engine.session_manager.stop_playlist(player_name, player_id)
                json_response(self, HTTPStatus.OK, result)
                return

            raise RequestError(f"Unknown route: {route}", HTTPStatus.NOT_FOUND)
        except RequestError as exc:
            json_response(self, exc.status, {"ok": False, "error": str(exc)})
        except Exception as exc:
            LOGGER.exception("Unhandled request error")
            json_response(self, HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": str(exc)})

    def _check_auth(self) -> None:
        token = self.engine.config.api_token
        if not token:
            return

        supplied = self.headers.get("X-API-Key", "")
        if supplied == token:
            return

        parsed = parse.urlparse(self.path)
        query = parse.parse_qs(parsed.query)
        if query.get("token", [""])[0] == token:
            return

        raise RequestError("Unauthorized", HTTPStatus.UNAUTHORIZED)

    def _read_json_body(self) -> Dict[str, Any]:
        content_length = int(self.headers.get("Content-Length") or 0)
        if content_length == 0:
            return {}
        raw = self.rfile.read(content_length)
        return json.loads(raw.decode("utf-8"))

    @staticmethod
    def _param(payload: Dict[str, Any], query: Dict[str, List[str]], key: str, required: bool = False) -> Optional[str]:
        value = payload.get(key)
        if value in (None, ""):
            value = query.get(key, [None])[0]
        if required and value in (None, ""):
            raise RequestError(f"Missing required parameter: {key}")
        return str(value) if value not in (None, "") else None


class PlaylistEngineApp:
    def __init__(self, config: EngineConfig):
        self.config = config
        self.state_store = StateStore(config.state_db)
        self.lms = LmsClient(config.lms_base_url)
        self.selector = TrackSelector(config, self.state_store)
        self.session_manager = SessionManager(config, self.lms, self.state_store, self.selector)

    def serve_forever(self) -> None:
        handler_class = type("ConfiguredPlaylistApiHandler", (PlaylistApiHandler,), {})
        handler_class.engine = self
        server = ThreadingHTTPServer((self.config.listen_host, self.config.listen_port), handler_class)
        self.session_manager.start_background_loop()
        LOGGER.info("Playlist engine listening on %s:%s", self.config.listen_host, self.config.listen_port)
        try:
            server.serve_forever()
        finally:
            self.session_manager.stop_background_loop()
            server.server_close()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Stable SQL-driven LMS playlist engine")
    parser.add_argument(
        "--config",
        default="playlist_engine_config.example.json",
        help="Path to the engine JSON config file",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        help="Logging level, for example DEBUG or INFO",
    )
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    config = EngineConfig.load(Path(args.config).resolve())
    app = PlaylistEngineApp(config)
    app.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())