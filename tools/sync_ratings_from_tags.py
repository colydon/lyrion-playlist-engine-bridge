#!/usr/bin/env python3
"""Vul LMS-ratings aan vanuit de POPM-tag in de mp3-bestanden.

Waarom dit bestaat
------------------
Muziek wordt in MusicBee beoordeeld en die rating staat als POPM-tag in het
bestand. CustomTagImporter kan die tag naar de LMS-database schrijven, maar
versie 1.3.3 doet dat kapot (het schrijft "ARRAY(0x...)" als waarde en zet
vervolgens *alle* ratings op 0). Daarom staat `writeratingstodb` daar uit en
regelt dit script de overstap van tag naar LMS.

Uitgangspunten
--------------
* Het script onthoudt per nummer welke tag-waarde het de laatste keer zag
  (baseline in `rating_sync.db`). Verandert de POPM-tag in het bestand, dan
  wordt de LMS-rating bijgewerkt; blijft de tag gelijk, dan gebeurt er niets.
* Met `--correct` is de tag leidend: elke LMS-rating die afwijkt van de bekende
  tag-waarde wordt rechtgezet (ook als het bestand niet is aangeraakt). Zonder
  die vlag wordt alleen bijgewerkt wat nieuw is of waarvan de tag veranderde.
* Nooit een rating op 0 zetten; een nummer zonder rating-tag blijft ongemoeid.
* Schrijven gebeurt via de CLI van de RatingsLight-plugin, zodat LMS zijn
  cache bijwerkt en de historie (lastRated/prevRating) klopt.

Gebruik
-------
    python3 sync_ratings.py                # nieuwe nummers + gewijzigde tags
    python3 sync_ratings.py --dry-run      # laten zien wat er zou gebeuren
    python3 sync_ratings.py --verbose      # per nummer wat er gebeurt
    python3 sync_ratings.py --rescan-files # alle bestanden opnieuw inlezen
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sqlite3
import struct
import sys
import time
import urllib.parse

DEFAULT_LIBRARY_DB = "/usr/local/slimserver/Cache/library.db"
DEFAULT_PERSIST_DB = "/mnt/mmcblk0p2/tce/slimserver/prefs/persist.db"
DEFAULT_CONFIG = "/home/tc/playlist_engine/playlist_engine_config.json"
DEFAULT_STATE = "/home/tc/playlist_engine/rating_sync.db"
CLI_HOST = "127.0.0.1"
CLI_PORT = 9090
# Placeholder die LMS zelf aanmaakt voor bestanden zonder genre; nooit verwijderen.
IGNORE_GENRES = {"geen genre", "no genre", "(geen genre)", "(no genre)", ""}
MAX_TAG_BYTES = 2 * 1024 * 1024  # ID3-tag mag groot zijn i.v.m. hoezen


# ---------------------------------------------------------------- ID3 parser
def read_id3_frames(path: str) -> dict:
    with open(path, "rb") as fh:
        head = fh.read(10)
        if len(head) < 10 or head[:3] != b"ID3":
            return {}
        version = head[3]
        tag_size = 0
        for b in head[6:10]:
            tag_size = (tag_size << 7) | (b & 0x7F)
        body = fh.read(min(tag_size, MAX_TAG_BYTES))

    frames: dict = {}
    pos = 0
    while pos + 10 <= len(body):
        frame_id = body[pos:pos + 4]
        if not frame_id.strip(b"\x00"):
            break
        raw_size = body[pos + 4:pos + 8]
        if version == 4:
            size = (raw_size[0] << 21) | (raw_size[1] << 14) | (raw_size[2] << 7) | raw_size[3]
        else:
            size = struct.unpack(">I", raw_size)[0]
        if size <= 0 or pos + 10 + size > len(body):
            break
        frames.setdefault(frame_id.decode("latin1"), body[pos + 10:pos + 10 + size])
        pos += 10 + size
    return frames


def decode_text(body: bytes) -> str:
    """ID3-tekstframe decoderen (encoding-byte 0=latin1, 1=utf-16, 2=utf-16-be, 3=utf-8)."""
    if not body:
        return ""
    enc = body[0]
    payload = body[1:]
    try:
        if enc == 1:
            return payload.decode("utf-16", "replace")
        if enc == 2:
            return payload.decode("utf-16-be", "replace")
        if enc == 3:
            return payload.decode("utf-8", "replace")
        return payload.decode("latin1", "replace")
    except Exception:
        return ""


# POPM-byte -> LMS-rating (tientallen). Gemeten op deze bibliotheek: de bestanden
# bevatten zowel de klassieke WMP-waarden (64/128/196/255) als de waarden die
# MusicBee zelf schrijft voor halve sterren (118/186/242). MusicBee toont 128 als
# 3 ster, dus een lineaire byte/255-formule is fout. Tussenliggende bytes worden
# lineair geïnterpoleerd.
POPM_ANCHORS = [
    (13, 10),    # 0,5 ster
    (64, 40),    # 2 ster (WMP)
    (118, 50),   # 2,5 ster (MusicBee)
    (128, 60),   # 3 ster (WMP)
    (186, 70),   # 3,5 ster (MusicBee)
    (196, 80),   # 4 ster (WMP)
    (242, 90),   # 4,5 ster (MusicBee)
    (255, 100),  # 5 ster
]


def popm_to_lms(rating_byte: int) -> int:
    """POPM-waarde omrekenen naar een LMS-rating (0-100 in stappen van 10)."""
    if rating_byte <= 0:
        return 0
    if rating_byte <= POPM_ANCHORS[0][0]:
        return POPM_ANCHORS[0][1]
    if rating_byte >= POPM_ANCHORS[-1][0]:
        return POPM_ANCHORS[-1][1]
    for (b1, r1), (b2, r2) in zip(POPM_ANCHORS, POPM_ANCHORS[1:]):
        if b1 <= rating_byte <= b2:
            if b2 == b1:
                return r1
            value = r1 + (r2 - r1) * (rating_byte - b1) / float(b2 - b1)
            return int(round(value / 10.0)) * 10
    return 0


def popm_from_frames(frames: dict) -> int | None:
    """LMS-rating uit de POPM-tag, of None als die er niet is."""
    best = None
    for name in ("POPM", "POP"):
        body = frames.get(name)
        if not body:
            continue
        nul = body.find(b"\x00")
        if nul < 0 or nul + 1 >= len(body):
            continue
        rating_byte = body[nul + 1]
        if rating_byte == 0:
            continue
        value = popm_to_lms(rating_byte)
        if best is None or value > best:
            best = value
    return best


def popm_rating(path: str) -> int | None:
    """Percentage (0-100) uit de POPM-tag van dit bestand, of None."""
    try:
        return popm_from_frames(read_id3_frames(path))
    except OSError:
        return None


# ------------------------------------------------------------------- helpers
def load_config(path: str) -> dict:
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def open_state(path: str) -> sqlite3.Connection:
    """Baseline: welke tag-waarde / genres zagen we de vorige keer per nummer."""
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute(
        "create table if not exists tag_state ("
        "urlmd5 text primary key, popm integer, mtime integer, seen_at integer)"
    )
    db.execute(
        "create table if not exists genre_state ("
        "urlmd5 text primary key, genres text, mtime integer, seen_at integer)"
    )
    db.commit()
    return db


def parse_genres(frames: dict) -> set | None:
    """Genres uit de TCON-tag (kan meerdere waarden bevatten). None = tag onleesbaar."""
    body = frames.get("TCON") or frames.get("TCO")
    if body is None:
        return set()
    text = decode_text(body)
    parts = []
    for chunk in text.replace("\x00", ";").split(";"):
        for part in chunk.split("/"):
            name = re.sub(r"^\(\d+\)", "", part.strip()).strip()
            if name:
                parts.append(name)
    return {p.lower() for p in parts}


def lms_cli(command: str, timeout: float = 5.0) -> str:
    with socket.create_connection((CLI_HOST, CLI_PORT), timeout=timeout) as sock:
        sock.sendall((command + "\n").encode())
        sock.settimeout(2.0)
        chunks = []
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b"\n" in chunk:
                    break
        except socket.timeout:
            pass
    return b"".join(chunks).decode("utf-8", "replace").strip()


def path_from_url(url: str) -> str:
    return urllib.parse.unquote(url.replace("file://", "", 1))


# ---------------------------------------------------------------------- main
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--library-db", default=None)
    parser.add_argument("--persist-db", default=DEFAULT_PERSIST_DB)
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--rescan-files",
        action="store_true",
        help="ook bestanden opnieuw inlezen waarvan de mtime niet is gewijzigd",
    )
    parser.add_argument(
        "--correct",
        action="store_true",
        help="LMS-ratings die afwijken van de bekende tag-waarde meteen rechtzetten",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    library_db = args.library_db or (config.get("lms", {}) or {}).get("library_db") or DEFAULT_LIBRARY_DB
    if not os.path.exists(library_db):
        print("  bibliotheekdatabase niet gevonden: %s" % library_db)
        return 1
    if not os.path.exists(args.persist_db):
        print("  persist-database niet gevonden: %s" % args.persist_db)
        return 1

    started = time.time()

    library = sqlite3.connect(library_db, timeout=30)
    library.row_factory = sqlite3.Row
    persist = sqlite3.connect(args.persist_db, timeout=30)
    persist.row_factory = sqlite3.Row

    tracks = library.execute(
        "select t.id, t.url, t.urlmd5 from tracks t where t.url like 'file://%'"
    ).fetchall()
    known = {
        row["urlmd5"]: row["rating"] or 0
        for row in persist.execute("select urlmd5, rating from tracks_persistent")
    }
    state = open_state(args.state)
    baseline = {
        row["urlmd5"]: (row["popm"], row["mtime"] or 0)
        for row in state.execute("select urlmd5, popm, mtime from tag_state")
    }
    genres_baseline = {
        row["urlmd5"]: (row["genres"], row["mtime"] or 0)
        for row in state.execute("select urlmd5, genres, mtime from genre_state")
    }

    stats = {
        "gecontroleerd": 0,
        "nieuw": 0,
        "gewijzigd": 0,
        "baseline": 0,
        "zonder-tag": 0,
        "ontbrekend": 0,
        "fouten": 0,
        "genre-gecontroleerd": 0,
        "genre-verwijderd": 0,
        "genre-opgeruimd": 0,
        "gecorrigeerd": 0,
    }
    now = int(time.time())
    pending = {"n": 0}

    def _commit_if_needed() -> None:
        pending["n"] += 1
        if pending["n"] % 200 == 0:
            state.commit()
            library.commit()

    def remember(urlmd5: str, popm: int, mtime: int) -> None:
        """Onthoud de geziene rating-tag; af en toe committen i.p.v. één lange transactie."""
        state.execute(
            "insert into tag_state (urlmd5, popm, mtime, seen_at) values (?, ?, ?, ?) "
            "on conflict(urlmd5) do update set popm=excluded.popm, mtime=excluded.mtime, seen_at=excluded.seen_at",
            (urlmd5, popm, mtime, now),
        )
        _commit_if_needed()

    def remember_genre(urlmd5: str, genres: set, mtime: int) -> None:
        """Onthoud de geziene genres van dit bestand."""
        state.execute(
            "insert into genre_state (urlmd5, genres, mtime, seen_at) values (?, ?, ?, ?) "
            "on conflict(urlmd5) do update set genres=excluded.genres, mtime=excluded.mtime, seen_at=excluded.seen_at",
            (urlmd5, ",".join(sorted(genres)), mtime, now),
        )
        _commit_if_needed()

    # ---- correctie-pass: tag is leidend -------------------------------------
    # Vergelijkt de laatst bekende tag-waarde met LMS; daarvoor hoeft geen
    # bestand opnieuw gelezen te worden.
    if args.correct:
        track_ids = {row["urlmd5"]: row["id"] for row in tracks}
        for urlmd5, (popm, _mtime) in baseline.items():
            if not popm:
                continue
            current = known.get(urlmd5, 0)
            if current == popm:
                continue
            track_id = track_ids.get(urlmd5)
            if track_id is None:
                continue
            if args.dry_run:
                print("  zou corrigeren: track %-6s %s -> %s" % (track_id, current or "-", popm))
                stats["gecorrigeerd"] += 1
                continue
            response = lms_cli("ratingslight setratingpercentnoclient %s %s" % (track_id, popm))
            if "error" in response.lower():
                stats["fouten"] += 1
                print("  fout bij track %s: %s" % (track_id, response))
                continue
            stats["gecorrigeerd"] += 1
            if args.verbose:
                print("  gecorrigeerd: track %-6s %s -> %s" % (track_id, current or "-", popm))

    for row in tracks:
        track_id = row["id"]
        file_path = path_from_url(row["url"])
        urlmd5 = row["urlmd5"]
        lms_rating = known.get(urlmd5, 0)

        try:
            mtime = int(os.stat(file_path).st_mtime)
        except OSError:
            stats["ontbrekend"] += 1
            continue

        seen_popm, seen_mtime = baseline.get(urlmd5, (None, 0))
        seen_genres, seen_genre_mtime = genres_baseline.get(urlmd5, (None, 0))
        need_rating = seen_popm is None or seen_mtime != mtime or args.rescan_files
        need_genre = seen_genres is None or seen_genre_mtime != mtime or args.rescan_files
        if args.dry_run:
            need_rating = need_genre = True
        if not (need_rating or need_genre):
            continue  # bestand is niet aangeraakt sinds de vorige run

        stats["gecontroleerd"] += 1
        try:
            frames = read_id3_frames(file_path)
        except OSError:
            stats["fouten"] += 1
            continue
        read_ok = bool(frames)

        # ---- genres: koppelingen die niet meer in de tag staan verwijderen ----
        if need_genre:
            stats["genre-gecontroleerd"] += 1
            file_genres = parse_genres(frames) if read_ok else None
            db_genres = library.execute(
                "select g.id as id, g.name as name from genre_track gt "
                "join genres g on g.id = gt.genre where gt.track = ?",
                (track_id,),
            ).fetchall()
            stale = [
                (g["id"], g["name"])
                for g in db_genres
                if file_genres is not None
                and g["name"].strip().lower() not in file_genres
                and g["name"].strip().lower() not in IGNORE_GENRES
            ]
            for genre_id, genre_name in stale:
                if args.dry_run:
                    print(
                        "  zou genre wissen: %-36s %s"
                        % (os.path.basename(file_path)[:36], genre_name)
                    )
                else:
                    library.execute(
                        "delete from genre_track where track = ? and genre = ?", (track_id, genre_id)
                    )
                stats["genre-verwijderd"] += 1
            if read_ok and not args.dry_run:
                remember_genre(urlmd5, file_genres or set(), mtime)

        # ---- ratings ----
        if not need_rating or not read_ok:
            continue

        target = popm_from_frames(frames)

        if not target:
            # Geen (bruikbare) rating-tag. LMS-rating nooit aanpassen, maar wel
            # onthouden dat er niets staat, zodat een later toegevoegde tag wél opvalt.
            stats["zonder-tag"] += 1
            if not args.dry_run:
                remember(urlmd5, 0, mtime)
            continue

        if seen_popm is None:
            # Eerste kennismaking: nieuwe nummers altijd vullen; bestaande ratings
            # alleen aanpassen als de tag leidend is (--correct).
            if lms_rating == target:
                if not args.dry_run:
                    remember(urlmd5, target, mtime)
                continue
            if lms_rating == 0:
                action = "nieuw"
            elif not args.correct:
                stats["baseline"] += 1
                if not args.dry_run:
                    remember(urlmd5, target, mtime)
                elif args.verbose:
                    print("  baseline vastgelegd (LMS blijft %s): %s" % (lms_rating, os.path.basename(file_path)))
                continue
            else:
                action = "gecorrigeerd"
        elif target != seen_popm:
            action = "gewijzigd"
        elif args.correct and target != lms_rating:
            action = "gecorrigeerd"
        else:
            # Tag gelijk aan vorige keer; alleen mtime bijwerken.
            if not args.dry_run:
                remember(urlmd5, target, mtime)
            continue

        if args.dry_run:
            print(
                "  zou %s zetten: %-42s %s -> %s"
                % (action, os.path.basename(file_path)[:42], lms_rating or "-", target)
            )
            stats[action] += 1
            continue

        response = lms_cli("ratingslight setratingpercentnoclient %s %s" % (track_id, target))
        if "error" in response.lower():
            stats["fouten"] += 1
            print("  fout bij %s: %s" % (os.path.basename(file_path), response))
            continue
        stats[action] += 1
        remember(urlmd5, target, mtime)
        if args.verbose:
            print("  %s: %-42s %s -> %s" % (action, os.path.basename(file_path)[:42], lms_rating or "-", target))

    if not args.dry_run:
        # genres die nergens meer aan hangen opruimen (behalve de placeholder)
        orphans = library.execute(
            "select id, name from genres where id not in (select genre from genre_track)"
        ).fetchall()
        for genre in orphans:
            if genre["name"].strip().lower() in IGNORE_GENRES:
                continue
            library.execute("delete from genres where id = ?", (genre["id"],))
            stats["genre-opgeruimd"] += 1
        state.commit()
        library.commit()

    print(
        "rating-sync: %d bestanden bekeken, %d nieuw, %d gewijzigd, %d zonder tag, "
        "%d baseline, %d ontbrekend, %d fouten (%.1fs)"
        % (
            stats["gecontroleerd"],
            stats["nieuw"],
            stats["gewijzigd"],
            stats["zonder-tag"],
            stats["baseline"],
            stats["ontbrekend"],
            stats["fouten"],
            time.time() - started,
        )
    )
    print(
        "genre-sync: %d bestanden gecontroleerd, %d verouderde genre-koppelingen verwijderd, "
        "%d lege genres opgeruimd"
        % (stats["genre-gecontroleerd"], stats["genre-verwijderd"], stats["genre-opgeruimd"])
    )
    if stats["gecorrigeerd"]:
        print("correcties: %d LMS-ratings rechtgezet naar de tag-waarde" % stats["gecorrigeerd"])
    return 0 if stats["fouten"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
