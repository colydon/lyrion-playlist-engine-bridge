#!/usr/bin/env python3
"""Simuleer een avond met een playlist-SQL uit deze repo.

Waarom: de engine trekt per top-up kandidaten uit de SQL en speelt ze af.
Bursts (5x Spaans achter elkaar) zijn een eigenschap van die trekking, niet
van de engine. Dit script bouwt een synthetische LMS-bibliotheek met de
verhoudingen uit WAARDERING_POOLS.md, speelt "een avond" na (elke ~3,5 minuut
een nummer) en meet:

  - de verdeling over de sterrenpools
  - het aandeel Spaans / Nederlandstalig (en samen)
  - de langste reeks achter elkaar uit dezelfde groep

Gebruik:
    python3 tools/sim_mix.py --sql AvondMix.sql --picks 400
    python3 tools/sim_mix.py --sql AvondMix.sql --picks 400 --json

Tegen een echte bibliotheek (gebruik een KOPIE; het script schrijft lastPlayed):
    sqlite3 library.db ".backup /tmp/mixsim/library.db"
    sqlite3 persist.db ".backup /tmp/mixsim/persist.db"
    python3 tools/sim_mix.py --sql AvondMix.sql --picks 100 --seeds 2 \
        --library /tmp/mixsim/library.db --persist /tmp/mixsim/persist.db

De tijd gaat in de simulatie vooruit door na elke trekking alle lastPlayed-
waarden 210 s terug te zetten. Zo ziet de SQL een echte avond tijdsverloop.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sqlite3
import statistics
import time

POOL_SIZES = {
    "5.0": 94,
    "4.5": 119,
    "4.0": 107,
    "3.5": 1182,
    "3.0": 1380,
    "2.5": 1844,
    "2.0": 92,
    "<2": 220,
}

RATING_BY_POOL = {"5.0": 100, "4.5": 90, "4.0": 80, "3.5": 70, "3.0": 60, "2.5": 50, "2.0": 40, "<2": 30}

# Samenstelling van de groepen. De gewichten zijn een schatting van hoe de
# echte bibliotheek eruitziet: Spaanse nummers zitten vooral in 3,0*/2,5*,
# Nederlandstalig loopt breder door maar ook veel 2,5*/3,0*.
SPAANS = 420
SPAANS_PROFILE = {"5.0": 0.01, "4.5": 0.02, "4.0": 0.03, "3.5": 0.15, "3.0": 0.40, "2.5": 0.32, "2.0": 0.07}
NEDERLANDS = 1400
NEDERLANDS_PROFILE = {"5.0": 0.01, "4.5": 0.04, "4.0": 0.07, "3.5": 0.23, "3.0": 0.28, "2.5": 0.33, "2.0": 0.04}
OLDIES = 1300
OLDIES_PROFILE = {"4.0": 0.03, "3.5": 0.07, "3.0": 0.30, "2.5": 0.50, "2.0": 0.10}
HITS_GENRE = 200
HITS_PROFILE = {"5.0": 0.15, "4.5": 0.25, "4.0": 0.35, "3.5": 0.25}

OTHER_GENRES = ["Pop", "Rock", "80s", "90s", "00s", "Dance", "R&B", "Alternative"]

# Tempo per waarderingspool: oldies (2,5*) zijn vaak langzaam, ex-hits (3,5*)
# en hits juist vaker snel. Dat bepaalt in AvondMix hoeveel er van een pool
# overblijft, dus dit moet kloppen om de gemeten poolverdeling te benaderen.
TEMPO_BY_POOL = {
    "5.0": [("Slow", 0.15), ("Very Slow", 0.03), ("Moderate", 0.35), ("Fast", 0.37), ("Very Fast", 0.10)],
    "4.5": [("Slow", 0.15), ("Very Slow", 0.03), ("Moderate", 0.35), ("Fast", 0.37), ("Very Fast", 0.10)],
    "4.0": [("Slow", 0.15), ("Very Slow", 0.03), ("Moderate", 0.35), ("Fast", 0.37), ("Very Fast", 0.10)],
    "3.5": [("Slow", 0.18), ("Very Slow", 0.04), ("Moderate", 0.30), ("Fast", 0.38), ("Very Fast", 0.10)],
    "3.0": [("Slow", 0.30), ("Very Slow", 0.08), ("Moderate", 0.28), ("Fast", 0.26), ("Very Fast", 0.08)],
    "2.5": [("Slow", 0.55), ("Very Slow", 0.15), ("Moderate", 0.20), ("Fast", 0.08), ("Very Fast", 0.02)],
    "2.0": [("Slow", 0.55), ("Very Slow", 0.15), ("Moderate", 0.20), ("Fast", 0.08), ("Very Fast", 0.02)],
    "<2": [("Slow", 0.55), ("Very Slow", 0.15), ("Moderate", 0.20), ("Fast", 0.08), ("Very Fast", 0.02)],
}

SQL_COMMENT_RE = re.compile(r"--[^\n]*", re.MULTILINE)
SQL_WHITESPACE_RE = re.compile(r"\s+")


def flatten_sql(sql_text: str) -> str:
    without_comments = SQL_COMMENT_RE.sub("", sql_text)
    flattened = SQL_WHITESPACE_RE.sub(" ", without_comments).strip()
    return flattened[:-1] if flattened.endswith(";") else flattened


def prepare_sql(sql_text: str, limit: int) -> str:
    prepared = flatten_sql(sql_text)
    prepared = prepared.replace("'PlaylistPlayer'", "'Kantoor'")
    prepared = prepared.replace("'PlaylistLimit'", str(limit))
    prepared = prepared.replace("PlaylistLimit", str(limit))
    prepared = prepared.replace("'PlaylistOffset'", "0")
    prepared = prepared.replace("PlaylistOffset", "0")
    prepared = prepared.replace("'PlaylistTrackMinDuration'", "90")
    prepared = prepared.replace("PlaylistTrackMinDuration", "90")
    if re.search(r"\blimit\b", prepared, re.IGNORECASE):
        return prepared
    return f"{prepared} limit {limit}"


def build_db(seed: int):
    rng = random.Random(seed)
    con = sqlite3.connect(":memory:")
    con.executescript(
        """
        create table tracks (id integer primary key, urlmd5 text, audio int, secs int, bpm int, primary_artist int);
        create table tracks_persistent (urlmd5 text primary key, rating int, playCount int, lastPlayed int);
        create table contributors (id integer primary key, name text);
        create table genres (id integer primary key, name text);
        create table genre_track (genre int, track int);
        create table customtagimporter_track_attributes (track int, attr text, value text);
        create table dynamicplaylist_history (client text, position integer primary key autoincrement, id int unique, added int);
        """
    )

    # Track-ids reserveren per waarderingspool.
    deck: dict[str, list[int]] = {}
    next_id = 1
    for pool, count in POOL_SIZES.items():
        deck[pool] = list(range(next_id, next_id + count))
        next_id += count

    genre_of: dict[int, set[str]] = {track: set() for pool in deck for track in deck[pool]}

    def assign_group(size: int, profile: dict[str, float], genre: str) -> list[int]:
        """Ken het genre toe aan een groep tracks, verdeeld over de pools.

        Per pool wordt een steekproef getrokken, dus een nummer kan in twee
        groepen zitten (een Nederlandse oldie is bijvoorbeeld Oldies en
        Nederlandstalig). Zo blijven de groepsgroottes kloppen zonder dat de
        pools overlopen.
        """
        total = sum(profile.values())
        chosen: list[int] = []
        for pool, weight in profile.items():
            count = int(round(size * weight / total))
            if count <= 0:
                continue
            for track in rng.sample(deck[pool], min(count, len(deck[pool]))):
                genre_of[track].add(genre)
                chosen.append(track)
        return chosen

    assign_group(SPAANS, SPAANS_PROFILE, "Spaans")
    assign_group(NEDERLANDS, NEDERLANDS_PROFILE, "Nederlandstalig")
    assign_group(OLDIES, OLDIES_PROFILE, "Oldies")
    hits = set(assign_group(HITS_GENRE, HITS_PROFILE, "Hits"))

    all_tracks = [track for pool in deck for track in deck[pool]]
    rated: dict[int, int] = {}
    for pool, tracks in deck.items():
        for track in tracks:
            rated[track] = RATING_BY_POOL[pool]

    artists = [(i, f"Artiest {i}") for i in range(1, 700)]
    con.executemany("insert into contributors (id, name) values (?, ?)", artists)

    genre_names = sorted({"Spaans", "Nederlandstalig", "Oldies", "Hits", "Kerst", "Sinterklaas", "Lounge", "Party", "Fout", "Live", "Karaoke", "Kinderliedjes", "Kindermuziek", "Geen genre", *OTHER_GENRES})
    genre_id = {name: index + 1 for index, name in enumerate(genre_names)}
    con.executemany("insert into genres (id, name) values (?, ?)", [(gid, name) for name, gid in genre_id.items()])

    pool_of_track = {track: pool for pool in deck for track in deck[pool]}
    track_rows = []
    persist_rows = []
    genre_rows = []
    attr_rows = []
    for track in all_tracks:
        bpm = rng.randint(70, 160)
        track_rows.append((track, f"md5-{track}", 1, rng.randint(120, 420), bpm, rng.randint(1, 699)))
        persist_rows.append((f"md5-{track}", rated[track], rng.randint(0, 200), None))
        genres = genre_of[track] or set()
        if not genres:
            genres = {rng.choice(OTHER_GENRES)}
        for name in genres:
            genre_rows.append((genre_id[name], track))
        # Ongeveer 70% heeft een TEMPO-tag.
        if rng.random() < 0.70:
            roll = rng.random()
            acc = 0.0
            for tempo, weight in TEMPO_BY_POOL[pool_of_track[track]]:
                acc += weight
                if roll <= acc:
                    attr_rows.append((track, "TEMPO", tempo))
                    break
        elif track in hits:
            attr_rows.append((track, "TEMPO", "Moderate"))

    con.executemany("insert into tracks (id, urlmd5, audio, secs, bpm, primary_artist) values (?, ?, ?, ?, ?, ?)", track_rows)
    con.executemany("insert into tracks_persistent (urlmd5, rating, playCount, lastPlayed) values (?, ?, ?, ?)", persist_rows)
    con.executemany("insert into genre_track (genre, track) values (?, ?)", genre_rows)
    con.executemany("insert into customtagimporter_track_attributes (track, attr, value) values (?, ?, ?)", attr_rows)
    con.commit()

    return con


def pool_of(rating: int) -> str:
    for pool, minimum in (("5.0", 100), ("4.5", 90), ("4.0", 80), ("3.5", 70), ("3.0", 60), ("2.5", 50), ("2.0", 40)):
        if rating >= minimum:
            return pool
    return "<2"


def simulate(con: sqlite3.Connection, query: str, picks: int, seconds_per_track: int, reset: bool = True) -> dict:
    now = int(time.time())
    if reset:
        con.execute("update tracks_persistent set lastPlayed = null")
    played: list[int] = []
    for _ in range(picks):
        rows = con.execute(query).fetchall()
        if not rows:
            break
        track_id = int(rows[0][0])
        played.append(track_id)
        con.execute(
            "update tracks_persistent set lastPlayed = ? where urlmd5 = (select urlmd5 from tracks where id = ?)",
            (now, track_id),
        )
        con.execute("update tracks_persistent set lastPlayed = lastPlayed - ? where lastPlayed is not null", (seconds_per_track,))
    return {"played": played}


def report(con: sqlite3.Connection, played: list[int]) -> dict:
    genres_of: dict[int, set[str]] = {}
    rated: dict[int, int] = {}
    if played:
        placeholders = ",".join("?" for _ in played)
        for row in con.execute(
            f"select gt.track, g.name from genre_track gt join genres g on g.id = gt.genre where gt.track in ({placeholders})",
            played,
        ):
            genres_of.setdefault(int(row[0]), set()).add(str(row[1]))
        for row in con.execute(
            f"select t.id, coalesce(tp.rating, 0) from tracks t left join tracks_persistent tp on tp.urlmd5 = t.urlmd5 where t.id in ({placeholders})",
            played,
        ):
            rated[int(row[0])] = int(row[1])
    pool_counts: dict[str, int] = {}
    spaans = nederlands = both = 0
    runs: list[int] = []
    current = 0
    for track_id in played:
        genres = genres_of.get(track_id, set())
        pool = pool_of(rated.get(track_id, 0))
        pool_counts[pool] = pool_counts.get(pool, 0) + 1
        is_spaans = "Spaans" in genres
        is_nederlands = "Nederlandstalig" in genres
        spaans += is_spaans
        nederlands += is_nederlands
        both += is_spaans or is_nederlands
        if is_spaans or is_nederlands:
            current += 1
        elif current:
            runs.append(current)
            current = 0
    if current:
        runs.append(current)

    total = max(len(played), 1)
    return {
        "picks": len(played),
        "pools": {pool: round(100.0 * count / total, 1) for pool, count in sorted(pool_counts.items(), reverse=True)},
        "spaans_pct": round(100.0 * spaans / total, 1),
        "nederlands_pct": round(100.0 * nederlands / total, 1),
        "samen_pct": round(100.0 * both / total, 1),
        "max_run": max(runs) if runs else 0,
        "runs_3plus": sum(1 for run in runs if run >= 3),
        "runs_4plus": sum(1 for run in runs if run >= 4),
        "runs_5plus": sum(1 for run in runs if run >= 5),
        "run_lengths": runs,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sql", default="AvondMix.sql")
    parser.add_argument("--picks", type=int, default=400)
    parser.add_argument("--seeds", type=int, default=3)
    parser.add_argument("--limit", type=int, default=16)
    parser.add_argument("--seconds-per-track", type=int, default=210)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--library", default="", help="draai tegen een echte (kopie van) library.db")
    parser.add_argument("--persist", default="", help="bijbehorende persist.db")
    args = parser.parse_args()

    sql_text = open(args.sql, encoding="utf-8").read()
    query = prepare_sql(sql_text, args.limit)

    results = []
    for seed in range(1, args.seeds + 1):
        if args.library:
            con = sqlite3.connect(args.library)
            con.execute("attach database ? as persist", (args.persist,))
        else:
            con = build_db(seed)
        played = simulate(con, query, args.picks, args.seconds_per_track)["played"]
        results.append(report(con, played))
        con.close()

    if args.json:
        print(json.dumps(results, indent=2))
        return 0

    print(f"{args.sql}: {args.picks} trekkingen per run, {args.seeds} runs\n")
    header = f"{'run':>3} {'5.0':>5} {'4.5':>5} {'4.0':>5} {'3.5':>5} {'3.0':>5} {'2.5':>5} {'2.0':>5} {'Sp':>5} {'Nl':>5} {'sa':>5} {'max':>4} {'3+':>3} {'4+':>3} {'5+':>3}"
    print(header)
    for index, result in enumerate(results, start=1):
        pools = result["pools"]
        row = " ".join(f"{pools.get(pool, 0.0):>5.1f}" for pool in ("5.0", "4.5", "4.0", "3.5", "3.0", "2.5", "2.0"))
        print(
            f"{index:>3} {row} {result['spaans_pct']:>5.1f} {result['nederlands_pct']:>5.1f} {result['samen_pct']:>5.1f} "
            f"{result['max_run']:>4} {result['runs_3plus']:>3} {result['runs_4plus']:>3} {result['runs_5plus']:>3}"
        )
    print("\nSp = aandeel Spaans, Nl = aandeel Nederlandstalig, sa = samen, max = langste reeks achter elkaar.")
    for key in ("spaans_pct", "nederlands_pct", "samen_pct", "max_run", "runs_3plus", "runs_4plus", "runs_5plus"):
        values = [result[key] for result in results]
        print(f"gemiddelde {key:<16} {statistics.mean(values):>6.2f}   (min {min(values)}, max {max(values)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
