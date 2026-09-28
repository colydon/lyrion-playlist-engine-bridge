#!/usr/bin/env python3
import argparse
import json
import logging
import re
import sqlite3
import threading
import time
from dataclasses import dataclass, field
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
class RoutingWindow:
    playlist: str
    start_minute: int
    end_minute: int
    label: str

    def matches(self, minute_of_day: int) -> bool:
        if self.start_minute == self.end_minute:
            return True
        if self.start_minute < self.end_minute:
            return self.start_minute <= minute_of_day < self.end_minute
        return minute_of_day >= self.start_minute or minute_of_day < self.end_minute


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
    routing_windows: List[RoutingWindow] = field(default_factory=list)

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
            "routing_targets": [window.playlist for window in self.routing_windows],
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
    artist_repeat_window_tracks: int
    player_recovery_enabled: bool
    player_recovery_grace_seconds: int
    player_recovery_cooldown_seconds: int
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
            routing_windows = cls._parse_routing_windows(merged_config.get("routing_windows", []), playlist_id)
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
                routing_windows=routing_windows,
            )

        if auto_discover_playlists and playlists_dir.exists():
            for sql_path in sorted(playlists_dir.glob("*.sql")):
                playlist_id = sql_path.stem
                if playlist_id in playlist_catalog:
                    continue
                merged_config = dict(playlist_overrides.get(playlist_id, {}))
                routing_windows = cls._parse_routing_windows(merged_config.get("routing_windows", []), playlist_id)
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
                    routing_windows=routing_windows,
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
            artist_repeat_window_tracks=max(0, int(engine.get("artist_repeat_window_tracks", 30))),
            player_recovery_enabled=bool(engine.get("player_recovery_enabled", True)),
            player_recovery_grace_seconds=max(5, int(engine.get("player_recovery_grace_seconds", 45))),
            player_recovery_cooldown_seconds=max(10, int(engine.get("player_recovery_cooldown_seconds", 120))),
            auto_discover_playlists=auto_discover_playlists,
            skip_rules=list(raw.get("skip_rules", [])),
            playlists=playlist_catalog,
        )

    @staticmethod
    def _parse_clock_minutes(value: str) -> int:
        match = re.fullmatch(r"(\d{1,2}):(\d{2})", str(value).strip())
        if not match:
            raise ValueError(f"Invalid routing time value: {value}")
        hour = int(match.group(1))
        minute = int(match.group(2))
        if hour not in range(24) or minute not in range(60):
            raise ValueError(f"Invalid routing time value: {value}")
        return hour * 60 + minute

    @classmethod
    def _parse_routing_windows(cls, raw_windows: Any, playlist_id: str) -> List[RoutingWindow]:
        windows: List[RoutingWindow] = []
        for index, raw_window in enumerate(raw_windows or []):
            if not isinstance(raw_window, dict):
                raise ValueError(f"Invalid routing window for {playlist_id}: {raw_window}")
            target = str(raw_window.get("playlist", "")).strip()
            start = str(raw_window.get("start", "")).strip()
            end = str(raw_window.get("end", "")).strip()
            if not target or not start or not end:
                raise ValueError(f"Incomplete routing window {index + 1} for {playlist_id}")
            windows.append(
                RoutingWindow(
                    playlist=target,
                    start_minute=cls._parse_clock_minutes(start),
                    end_minute=cls._parse_clock_minutes(end),
                    label=f"{start}-{end}",
                )
            )
        return windows

    def playlist_definition(self, playlist_name: str) -> PlaylistDefinition:
        playlist = self.playlists.get(playlist_name)
        if not playlist or not playlist.enabled:
            raise RequestError(f"Playlist not found or disabled: {playlist_name}", HTTPStatus.NOT_FOUND)
        if not playlist.sql_path.exists():
            raise RequestError(f"Playlist SQL not found: {playlist.sql_path}", HTTPStatus.NOT_FOUND)
        return playlist

    def resolve_playlist_definition(self, playlist_name: str) -> PlaylistDefinition:
        current_time = time.localtime()
        return self._resolve_playlist_definition(playlist_name, current_time, set())

    def _resolve_playlist_definition(
        self,
        playlist_name: str,
        current_time: time.struct_time,
        visited: set,
    ) -> PlaylistDefinition:
        if playlist_name in visited:
            raise RequestError(f"Playlist routing loop detected for {playlist_name}", HTTPStatus.INTERNAL_SERVER_ERROR)
        visited.add(playlist_name)

        playlist = self.playlist_definition(playlist_name)
        if not playlist.routing_windows:
            return playlist

        minute_of_day = current_time.tm_hour * 60 + current_time.tm_min
        for window in playlist.routing_windows:
            if window.matches(minute_of_day):
                return self._resolve_playlist_definition(window.playlist, current_time, visited)

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
                t.primary_artist as primary_artist_id,
                coalesce(pa.name, '') as primary_artist_name,
                coalesce(tp.rating, 0) as rating,
                group_concat(distinct g.name) as genres,
                group_concat(distinct ct.contributor) as contributor_ids,
                group_concat(distinct ca.name) as contributor_names
            from tracks t
            left join persist.tracks_persistent tp on tp.urlmd5 = t.urlmd5
            left join contributors pa on pa.id = t.primary_artist
            left join genre_track gt on gt.track = t.id
            left join genres g on g.id = gt.genre
            left join contributor_track ct on ct.track = t.id
            left join contributors ca on ca.id = ct.contributor
            where t.id in ({placeholders})
            group by t.id, t.title, t.url, t.secs, t.primary_artist, pa.name, tp.rating
            """,
            [int(track_id) for track_id in track_ids],
        ).fetchall()

        metadata: Dict[int, Dict[str, Any]] = {}
        for row in rows:
            genres: List[str] = []
            if row["genres"]:
                genres = [genre.strip() for genre in str(row["genres"]).split(",") if genre.strip()]
            artist_ids: List[int] = []
            artist_names: List[str] = []
            seen_artist_ids = set()
            seen_artist_names = set()

            primary_artist_id = row["primary_artist_id"]
            if primary_artist_id is not None:
                primary_artist_id_int = int(primary_artist_id)
                artist_ids.append(primary_artist_id_int)
                seen_artist_ids.add(primary_artist_id_int)
            primary_artist_name = str(row["primary_artist_name"] or "").strip()
            if primary_artist_name:
                artist_names.append(primary_artist_name)
                seen_artist_names.add(primary_artist_name.lower())

            if row["contributor_ids"]:
                for value in str(row["contributor_ids"]).split(","):
                    value = value.strip()
                    if not value:
                        continue
                    contributor_id = int(value)
                    if contributor_id in seen_artist_ids:
                        continue
                    artist_ids.append(contributor_id)
                    seen_artist_ids.add(contributor_id)

            if row["contributor_names"]:
                for value in str(row["contributor_names"]).split(","):
                    name = value.strip()
                    if not name:
                        continue
                    lowered = name.lower()
                    if lowered in seen_artist_names:
                        continue
                    artist_names.append(name)
                    seen_artist_names.add(lowered)

            metadata[int(row["id"])] = {
                "id": int(row["id"]),
                "title": row["title"],
                "url": row["url"],
                "secs": row["secs"],
                "rating": int(row["rating"] or 0),
                "genres": genres,
                "artist_ids": artist_ids,
                "artists": artist_names,
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

    @staticmethod
    def _artist_ids(track: Dict[str, Any]) -> set:
        return {int(artist_id) for artist_id in track.get("artist_ids", []) if str(artist_id).isdigit()}

    def _shares_recent_artist(self, track: Dict[str, Any], recent_tracks: Sequence[Dict[str, Any]]) -> bool:
        artist_window = self.config.artist_repeat_window_tracks
        if artist_window <= 0:
            return False

        track_artist_ids = self._artist_ids(track)
        if not track_artist_ids:
            return False

        for recent_track in recent_tracks[-artist_window:]:
            if track_artist_ids.intersection(self._artist_ids(recent_track)):
                return True
        return False

    def choose_start_track(
        self,
        playlist_name: str,
        player_id: str,
        current_queue_ids: Sequence[int],
        preferred_genre: str,
    ) -> Optional[Dict[str, Any]]:
        if not preferred_genre:
            return None

        playlist = self.config.resolve_playlist_definition(playlist_name)
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
        playlist = self.config.resolve_playlist_definition(playlist_name)
        sql_text = playlist.sql_path.read_text(encoding="utf-8")
        history_track_ids = self.state_store.history_for_player(player_id, playlist_name)
        history_ids = set(history_track_ids)
        current_ids = {int(track_id) for track_id in current_queue_ids}
        desired_count = max(1, desired_count)

        selected: List[Dict[str, Any]] = []
        exhausted_once = False

        with self._connect() as connection:
            recent_history_ids = history_track_ids[-self.config.artist_repeat_window_tracks :] if self.config.artist_repeat_window_tracks > 0 else []
            recent_history_metadata = self._fetch_metadata(connection, recent_history_ids)
            recent_tracks_seed = [recent_history_metadata[track_id] for track_id in recent_history_ids if track_id in recent_history_metadata]

            for allow_artist_repeats in ([False, True] if self.config.artist_repeat_window_tracks > 0 else [True]):
                if allow_artist_repeats and self.config.artist_repeat_window_tracks > 0 and len(selected) < desired_count:
                    LOGGER.info(
                        "Relaxing the %s-track artist spacing rule for %s/%s because too few candidates remained.",
                        self.config.artist_repeat_window_tracks,
                        player_id,
                        playlist_name,
                    )

                attempts = 0
                recent_tracks = list(recent_tracks_seed) + list(selected)
                while len(selected) < desired_count and attempts < 4:
                    candidate_limit = max(desired_count * self.config.candidate_multiplier * (attempts + 1), desired_count)
                    query = self._prepare_sql(sql_text, player_id, candidate_limit)
                    LOGGER.debug(
                        "Selecting tracks for %s using %s on %s with limit %s",
                        playlist_name,
                        playlist.identifier,
                        player_id,
                        candidate_limit,
                    )
                    rows = connection.execute(query).fetchall()
                    track_ids = [int(row[0]) for row in rows if row[0] is not None]

                    if not track_ids and history_ids and self.config.history_reset_on_exhaustion and not exhausted_once:
                        LOGGER.info("Resetting session history for %s/%s because the candidate set was exhausted.", player_id, playlist_name)
                        self.state_store.clear_history(player_id, playlist_name)
                        history_ids.clear()
                        recent_tracks_seed.clear()
                        recent_tracks = list(selected)
                        exhausted_once = True
                        continue

                    metadata = self._fetch_metadata(connection, track_ids)
                    selected_before_attempt = len(selected)
                    artist_blocked_count = 0
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
                        if not allow_artist_repeats and self._shares_recent_artist(track, recent_tracks):
                            artist_blocked_count += 1
                            continue
                        selected.append(track)
                        recent_tracks.append(track)
                        history_ids.add(track_id)
                        current_ids.add(track_id)

                    if (
                        len(selected) == selected_before_attempt
                        and history_ids
                        and self.config.history_reset_on_exhaustion
                        and artist_blocked_count == 0
                        and not exhausted_once
                    ):
                        LOGGER.info(
                            "Resetting session history for %s/%s because only already queued or filtered candidates remained.",
                            player_id,
                            playlist_name,
                        )
                        self.state_store.clear_history(player_id, playlist_name)
                        history_ids.clear()
                        recent_tracks_seed.clear()
                        recent_tracks = list(selected)
                        exhausted_once = True
                        continue

                    attempts += 1

                if len(selected) >= desired_count:
                    break

        return selected


class SessionManager:
    def __init__(self, config: EngineConfig, lms: LmsClient, state_store: StateStore, selector: TrackSelector):
        self.config = config
        self.lms = lms
        self.state_store = state_store
        self.selector = selector
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._disconnected_since: Dict[str, float] = {}
        self._empty_queue_since: Dict[str, float] = {}
        self._manual_suspend_reason: Dict[str, str] = {}
        self._recover_after_disconnect: Dict[str, float] = {}
        self._last_recovery_attempt_at: Dict[str, float] = {}

    def start_background_loop(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run_loop, name="playlist-engine-loop", daemon=True)
        self._thread.start()

    def stop_background_loop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _clear_runtime_state(self, player_id: str) -> None:
        self._disconnected_since.pop(player_id, None)
        self._empty_queue_since.pop(player_id, None)
        self._manual_suspend_reason.pop(player_id, None)
        self._recover_after_disconnect.pop(player_id, None)
        self._last_recovery_attempt_at.pop(player_id, None)

    def _can_attempt_recovery(self, player_id: str, now: float) -> bool:
        last_attempt_at = self._last_recovery_attempt_at.get(player_id, 0.0)
        if now - last_attempt_at < self.config.player_recovery_cooldown_seconds:
            return False
        self._last_recovery_attempt_at[player_id] = now
        return True

    def _build_session_tracks(
        self,
        session: Dict[str, Any],
        current_queue_ids: Sequence[int],
        desired_count: int,
    ) -> List[Dict[str, Any]]:
        playlist_name = str(session["playlist_name"])
        player_id = str(session["player_id"])
        playlist = self.config.playlist_definition(playlist_name)
        effective_playlist = self.config.resolve_playlist_definition(playlist_name)

        tracks: List[Dict[str, Any]] = []
        start_track = self.selector.choose_start_track(
            playlist_name,
            player_id,
            current_queue_ids,
            effective_playlist.start_with_genre or playlist.start_with_genre,
        )
        if start_track:
            tracks.append(start_track)
            current_queue_ids = list(current_queue_ids) + [start_track["id"]]

        remaining_count = max(int(desired_count) - len(tracks), 0)
        if remaining_count > 0:
            tracks.extend(self.selector.choose_tracks(playlist_name, player_id, remaining_count, current_queue_ids))
        return tracks

    def _recover_session(self, session: Dict[str, Any], reason: str) -> bool:
        player_id = str(session["player_id"])
        desired_count = max(int(session.get("initial_count") or self.config.default_initial_count), 1)
        tracks = self._build_session_tracks(session, [], desired_count)
        if not tracks:
            LOGGER.warning("Could not recover managed session for %s because no replacement tracks were available.", player_id)
            return False

        self.lms.power_on(player_id)
        self.lms.play_track(player_id, tracks[0]["id"])
        for track in tracks[1:]:
            self.lms.add_track(player_id, track["id"])
        self.lms.play(player_id)

        self.state_store.add_history(player_id, str(session["playlist_name"]), [track["id"] for track in tracks])
        self._empty_queue_since.pop(player_id, None)
        self._manual_suspend_reason.pop(player_id, None)
        self._recover_after_disconnect.pop(player_id, None)
        LOGGER.info(
            "Recovered managed session for %s on %s after %s with %s tracks.",
            player_id,
            session["playlist_name"],
            reason,
            len(tracks),
        )
        return True

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.maintain_sessions()
            except Exception:
                LOGGER.exception("Unexpected error in maintenance loop")
            self._stop_event.wait(self.config.poll_interval_seconds)

    def maintain_sessions(self) -> None:
        now = time.time()
        for session in self.state_store.list_sessions():
            player_id = session["player_id"]
            try:
                status = self.lms.status(player_id)
            except RequestError:
                LOGGER.warning("Could not read LMS status for player %s", player_id)
                continue

            mode = str(status.get("mode") or "").lower()
            power = int(status.get("power") if status.get("power") is not None else 1)
            connected = int(status.get("connected") if status.get("connected") is not None else 1)

            queue_ids = [int(item["id"]) for item in status.get("playlist_loop", []) if str(item.get("id", "")).isdigit()]
            current_index = int(status.get("playlist_cur_index") or 0)
            total_tracks = max(int(status.get("playlist_tracks") or 0), len(queue_ids))
            remaining = max(total_tracks - current_index - 1, 0)
            queue_intact = total_tracks > 0 or bool(queue_ids)

            if connected == 0:
                if player_id not in self._disconnected_since:
                    LOGGER.warning("Player %s disconnected; keeping the managed session active for recovery.", player_id)
                    self._disconnected_since[player_id] = now
                self._empty_queue_since.pop(player_id, None)
                continue

            disconnected_at = self._disconnected_since.pop(player_id, None)
            if disconnected_at is not None:
                self._recover_after_disconnect[player_id] = now
                LOGGER.info("Player %s reconnected after %.0fs; evaluating managed session recovery.", player_id, now - disconnected_at)

            if power == 0:
                if self._manual_suspend_reason.get(player_id) != "power_off":
                    LOGGER.info("Keeping managed session for %s idle because the player power is off.", player_id)
                self._manual_suspend_reason[player_id] = "power_off"
                self._empty_queue_since.pop(player_id, None)
                continue

            recovered_after_disconnect = player_id in self._recover_after_disconnect

            if mode in {"pause", "stop"} and queue_intact and not recovered_after_disconnect:
                suspend_reason = f"{mode}_with_queue"
                if self._manual_suspend_reason.get(player_id) != suspend_reason:
                    LOGGER.info(
                        "Keeping managed session for %s suspended because player state is mode=%s with queue intact.",
                        player_id,
                        mode,
                    )
                self._manual_suspend_reason[player_id] = suspend_reason
                self._empty_queue_since.pop(player_id, None)
                continue

            if recovered_after_disconnect and queue_intact and mode != "play":
                if self.config.player_recovery_enabled and self._can_attempt_recovery(player_id, now):
                    LOGGER.info("Resuming playback for %s after reconnect because the managed queue is still intact.", player_id)
                    self.lms.play(player_id)
                continue

            if not queue_intact:
                if player_id in self._manual_suspend_reason and not recovered_after_disconnect:
                    LOGGER.info("Stopping managed session for %s because a manually suspended queue was cleared.", player_id)
                    self.state_store.stop_session(player_id)
                    self._clear_runtime_state(player_id)
                    continue

                empty_since = self._empty_queue_since.setdefault(player_id, now)
                if not self.config.player_recovery_enabled:
                    LOGGER.warning("Managed session for %s lost its queue but automatic recovery is disabled.", player_id)
                    continue
                if now - empty_since < self.config.player_recovery_grace_seconds:
                    continue
                if not self._can_attempt_recovery(player_id, now):
                    continue
                self._recover_session(session, f"queue empty while mode={mode or 'unknown'} power={power}")
                continue

            self._empty_queue_since.pop(player_id, None)

            if mode == "play":
                if player_id in self._manual_suspend_reason:
                    LOGGER.info("Resuming managed session monitoring for %s after the player returned to play.", player_id)
                self._manual_suspend_reason.pop(player_id, None)
                self._recover_after_disconnect.pop(player_id, None)
            elif mode in {"pause", "stop"}:
                continue

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
        effective_playlist = self.config.resolve_playlist_definition(playlist_name)
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
            effective_playlist.start_with_genre or playlist.start_with_genre,
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

        self._clear_runtime_state(resolved_player_id)
        self.state_store.save_session(resolved_player_id, resolved_player_name, playlist_name, playlist)
        self.state_store.add_history(resolved_player_id, playlist_name, [track["id"] for track in tracks])

        return {
            "player_id": resolved_player_id,
            "player_name": resolved_player_name,
            "playlist": playlist_name,
            "playlist_title": playlist.title,
            "resolved_playlist": effective_playlist.identifier,
            "resolved_playlist_title": effective_playlist.title,
            "queued_tracks": len(tracks),
            "tracks": tracks,
        }

    def preview_playlist(self, playlist_name: str, player_name: Optional[str], player_id: Optional[str], count: int) -> Dict[str, Any]:
        playlist = self.config.playlist_definition(playlist_name)
        effective_playlist = self.config.resolve_playlist_definition(playlist_name)
        player = self.lms.resolve_player(player_name, player_id)
        status = self.lms.status(player["playerid"])
        queue_ids = [int(item["id"]) for item in status.get("playlist_loop", []) if str(item.get("id", "")).isdigit()]
        tracks = self.selector.choose_tracks(playlist_name, player["playerid"], count, queue_ids)
        return {
            "player_id": player["playerid"],
            "player_name": player["name"],
            "playlist": playlist_name,
            "playlist_title": playlist.title,
            "resolved_playlist": effective_playlist.identifier,
            "resolved_playlist_title": effective_playlist.title,
            "tracks": tracks,
        }

    def stop_playlist(self, player_name: Optional[str], player_id: Optional[str]) -> Dict[str, Any]:
        player = self.lms.resolve_player(player_name, player_id)
        self.state_store.stop_session(player["playerid"])
        self._clear_runtime_state(player["playerid"])
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