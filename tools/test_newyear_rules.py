"""Rooktest voor de Nieuwjaarsregels (genre NewYear) in de playlist-SQL.

Draaien vanaf de repo-root:  python3 tools/test_newyear_rules.py

Er wordt een kleine synthetische LMS-database in .tmp/newyear_test/ gebouwd
(library.db + persist.db) met daarin:
- gewone nummers (Hits / Oldies, 1985, rating 3 ster)
- id 100: genre NewYear (en verder niets), 5 ster
- id 101: genre NewYear + Kerst, 5 ster
- id 102: genre Kerst, 5 ster

Daarna wordt elke playlist-SQL op drie "dagen" gedraaid door de datumfunctie
in de SQL te vervangen door een vaste dag:
- 22 november (buiten de seizoenen): geen enkel NewYear-nummer
- 20 december: alleen het nummer dat ook Kerst is (101), nooit 100
- 1 januari: 100 en 101 mogen mee, maar nooit samen in één selectie

Tot slot wordt de engine zelf getest: genre_rules moet herhaling binnen een
sessie toestaan (exempt_from_history) en hooguit één NewYear-nummer tegelijk
in de wachtrij zetten (max_in_queue).

Schrijft alleen in .tmp/ (gitignored).
"""
import json
import sqlite3
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

import playlist_engine as pe  # noqa: E402

TMP = REPO / ".tmp" / "newyear_test"
DATE_FN = "strftime('%m-%d', 'now', 'localtime')"

FAILURES = []


def check(condition: bool, message: str) -> None:
    if condition:
        return
    FAILURES.append(message)
    print(f"FAIL: {message}")


def build_database() -> tuple:
    TMP.mkdir(parents=True, exist_ok=True)
    library_db = TMP / "library.db"
    persist_db = TMP / "persist.db"
    for path in (library_db, persist_db):
        if path.exists():
            path.unlink()

    now = int(time.time())
    library = sqlite3.connect(library_db)
    library.executescript(
        """
        create table tracks (
            id integer primary key, title text, url text, urlmd5 text,
            secs real, bpm integer, year integer, audio integer,
            primary_artist integer
        );
        create table contributors (id integer primary key, name text);
        create table genres (id integer primary key, name text);
        create table genre_track (track integer, genre integer);
        create table contributor_track (track integer, contributor integer);
        create table customtagimporter_track_attributes (track integer, attr text, value text);
        create table dynamicplaylist_history (id integer, client text);
        """
    )
    library.executemany(
        "insert into contributors (id, name) values (?, ?)",
        [(3, "LUCARIX")]
        + [(9 + track_id, f"Artiest {track_id}") for track_id in range(1, 21)]
        + [(30, "Artiest Nieuwjaar"), (31, "Artiest Nieuwjaar 2"), (32, "Artiest Kerst")],
    )
    library.executemany(
        "insert into genres (id, name) values (?, ?)",
        [
            (1, "Hits"), (2, "Kerst"), (3, "NewYear"), (4, "Oldies"), (5, "Party"),
            (6, "Summer"), (7, "Spaans"), (8, "Nederlandstalig"), (9, "Love"),
        ],
    )

    tracks = []
    genres = []
    for track_id in range(1, 11):
        tracks.append((track_id, f"Hit {track_id}", f"file:///{track_id}.mp3", f"md5-{track_id}", 200.0, 118, 1985, 1, 9 + track_id))
        genres.append((track_id, 1))
    for track_id in range(11, 21):
        tracks.append((track_id, f"Oldie {track_id}", f"file:///{track_id}.mp3", f"md5-{track_id}", 210.0, 112, 1985, 1, 9 + track_id))
        genres.append((track_id, 4))
    tracks.extend(
        [
            (100, "Happy New Year", "file:///100.mp3", "md5-100", 240.0, 120, 1985, 1, 30),
            (101, "New Year's Day", "file:///101.mp3", "md5-101", 240.0, 118, 1985, 1, 31),
            (102, "Last Christmas", "file:///102.mp3", "md5-102", 240.0, 118, 1985, 1, 32),
        ]
    )
    genres.extend([(100, 3), (101, 3), (101, 2), (102, 2)])
    library.executemany(
        "insert into tracks (id, title, url, urlmd5, secs, bpm, year, audio, primary_artist) "
        "values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        tracks,
    )
    library.executemany("insert into genre_track (track, genre) values (?, ?)", genres)
    library.executemany(
        "insert into contributor_track (track, contributor) values (?, ?)",
        [(100, 30), (101, 31), (102, 32)],
    )
    library.commit()
    library.close()

    persist = sqlite3.connect(persist_db)
    persist.executescript(
        """
        create table tracks_persistent (
            urlmd5 text primary key, rating integer, playCount integer, lastPlayed integer
        );
        """
    )
    rows = []
    for track_id in range(1, 21):
        rows.append((f"md5-{track_id}", 60, 10, now - 200000))
    rows.extend(
        [
            ("md5-100", 100, 0, None),
            ("md5-101", 100, 0, None),
            ("md5-102", 100, 0, None),
        ]
    )
    persist.executemany(
        "insert into tracks_persistent (urlmd5, rating, playCount, lastPlayed) values (?, ?, ?, ?)",
        rows,
    )
    persist.commit()
    persist.close()
    return library_db, persist_db


def connect(library_db: Path, persist_db: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(library_db)
    connection.row_factory = sqlite3.Row
    connection.execute("attach database ? as persist", (str(persist_db),))
    return connection


def sql_for(playlist: str, day: str) -> str:
    text = (REPO / f"{playlist}.sql").read_text(encoding="utf-8")
    return pe.flatten_sql(text).replace(DATE_FN, f"'{day}'")


def run_sample(connection: sqlite3.Connection, sql: str) -> int:
    rows = connection.execute(f"{sql} limit 1").fetchall()
    return int(rows[0][0]) if rows else 0


def run_full(connection: sqlite3.Connection, sql: str) -> list:
    return [int(row[0]) for row in connection.execute(sql).fetchall()]


def set_last_played(persist_db: Path, urlmd5: str, value) -> None:
    persist = sqlite3.connect(persist_db)
    persist.execute("update tracks_persistent set lastPlayed = ? where urlmd5 = ?", (value, urlmd5))
    persist.commit()
    persist.close()


def test_seasonal_gate(connection: sqlite3.Connection) -> None:
    """Buiten 1 januari: geen NewYear-only nummer; NewYear+Kerst volgt Kerst."""
    for playlist in ("DagMix", "AvondMix", "80sMix", "OldiesMix", "HitsMix"):
        sql = sql_for(playlist, "11-22")
        seen = {run_sample(connection, sql) for _ in range(40)}
        check(100 not in seen, f"{playlist} op 22 nov: NewYear-only nummer 100 speelde mee")
        check(101 not in seen, f"{playlist} op 22 nov: kerstnummer 101 speelde mee")
        check(102 not in seen, f"{playlist} op 22 nov: kerstnummer 102 speelde mee")

    # KerstMix speelt altijd kerst, maar het NewYear-nummer hoort daar niet.
    sql = sql_for("KerstMix", "11-22")
    seen = {run_sample(connection, sql) for _ in range(20)}
    check(100 not in seen, "KerstMix op 22 nov: NewYear-only nummer 100 speelde mee")
    check(seen <= {101, 102}, f"KerstMix op 22 nov: onverwachte ids {sorted(seen)}")

    # 20 december: het nummer met Kerst + NewYear volgt de kerstregels.
    for playlist in ("DagMix", "AvondMix"):
        sql = sql_for(playlist, "12-20")
        seen = {run_sample(connection, sql) for _ in range(40)}
        check(100 not in seen, f"{playlist} op 20 dec: NewYear-only nummer 100 speelde mee")
        check(seen <= {101, 102}, f"{playlist} op 20 dec: onverwachte ids {sorted(seen)}")
        check(bool(seen & {101, 102}), f"{playlist} op 20 dec: geen kerstnummers gekozen")

    sql = sql_for("KerstMix", "12-20")
    seen = {run_sample(connection, sql) for _ in range(20)}
    check(seen == {101, 102}, f"KerstMix op 20 dec: verwacht 101/102, kreeg {sorted(seen)}")

    # 1 januari: een kerstnummer met NewYear mag mee, een puur kerstnummer niet.
    sql = sql_for("DagMix", "01-01")
    seen = {run_sample(connection, sql) for _ in range(200)}
    check(100 in seen or 101 in seen, "DagMix op 1 jan: geen enkel Nieuwjaarsnummer gekozen")
    check(102 not in seen, "DagMix op 1 jan: puur kerstnummer 102 speelde mee")


def test_newyear_rotation(connection: sqlite3.Connection, persist_db: Path) -> None:
    """Op 1 januari: nooit twee Nieuwjaarsnummers in één selectie, om de beurt."""
    sql = sql_for("DagMix", "01-01")
    for _ in range(30):
        result = run_full(connection, sql)
        newyear_hits = [track_id for track_id in result if track_id in (100, 101)]
        check(len(newyear_hits) <= 1, f"1 jan: twee Nieuwjaarsnummers in één selectie: {newyear_hits}")

    # Beide recent gespeeld -> de pool valt stil (geen Nieuwjaarsnummer).
    now = int(time.time())
    set_last_played(persist_db, "md5-100", now - 60)
    set_last_played(persist_db, "md5-101", now - 120)
    for _ in range(10):
        result = run_full(connection, sql)
        check(not ({100, 101} & set(result)), "1 jan: Nieuwjaarsnummer binnen de minimumafstand opnieuw gekozen")

    # Eén nummer net gespeeld (binnen de minimumafstand): ook het andere
    # nummer moet wachten, ook al is dat zelf lang genoeg geleden.
    set_last_played(persist_db, "md5-100", now - 600)
    set_last_played(persist_db, "md5-101", now - 7200)
    for _ in range(10):
        result = run_full(connection, sql)
        check(not ({100, 101} & set(result)), "1 jan: tweede nummer kwam binnen de minimumafstand toch langs")

    # 100 speelde 40 min geleden, 101 50 min -> 101 is het langst geleden.
    set_last_played(persist_db, "md5-100", now - 2400)
    set_last_played(persist_db, "md5-101", now - 3000)
    candidates = set()
    for _ in range(30):
        result = run_full(connection, sql)
        candidates |= {track_id for track_id in result if track_id in (100, 101)}
    check(candidates == {101}, f"1 jan rotatie: verwacht alleen 101, kreeg {sorted(candidates)}")

    # 100 speelde 70 min geleden, 101 een uur -> 100 is nu het langst geleden.
    set_last_played(persist_db, "md5-100", now - 4200)
    set_last_played(persist_db, "md5-101", now - 4000)
    candidates = set()
    for _ in range(30):
        result = run_full(connection, sql)
        candidates |= {track_id for track_id in result if track_id in (100, 101)}
    check(candidates == {100}, f"1 jan rotatie: verwacht alleen 100, kreeg {sorted(candidates)}")


def test_theme_playlist_january(connection: sqlite3.Connection) -> None:
    """Een themaplaylist zonder Nieuwjaarspool mag het nummer op 1 jan wel draaien."""
    sql = sql_for("80sMix", "01-01")
    seen = {run_sample(connection, sql) for _ in range(200)}
    check(100 in seen, "80sMix op 1 jan: NewYear-nummer 100 kwam nooit langs")


def test_engine_genre_rules(library_db: Path, persist_db: Path) -> None:
    """Engine: herhaling binnen een sessie + maximaal één in de wachtrij."""
    playlists_dir = TMP / "playlists"
    playlists_dir.mkdir(exist_ok=True)
    (playlists_dir / "DagMix.sql").write_text(sql_for("DagMix", "01-01"), encoding="utf-8")

    config_path = TMP / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "api": {"host": "127.0.0.1", "port": 0, "token": "test"},
                "lms": {"base_url": "http://127.0.0.1:9000", "library_db": str(library_db), "persist_db": str(persist_db)},
                "engine": {"playlists_dir": str(playlists_dir), "auto_discover_playlists": True, "state_db": str(TMP / "state.db")},
                "playlists": {"DagMix": {"sql_file": "DagMix.sql", "initial_count": 20, "topup_count": 10}},
                "genre_rules": {"NewYear": {"exempt_from_history": True, "max_in_queue": 1}},
            }
        ),
        encoding="utf-8",
    )
    config = pe.EngineConfig.load(config_path)
    check(config.genre_rules.get("newyear", {}).get("max_in_queue") == 1, "config: genre_rules niet geparsed")
    check(
        pe.EngineConfig._parse_genre_rules({"New Year": 0})["newyear"] == {"exempt_from_history": True, "max_in_queue": 0},
        "config: korte vorm van genre_rules niet ondersteund",
    )

    state_db = TMP / "state.db"
    if state_db.exists():
        state_db.unlink()
    store = pe.StateStore(state_db)
    selector = pe.TrackSelector(config, store)
    player = "aa:aa"

    first = selector.choose_tracks("DagMix", player, 20, [])
    newyear_first = [track["id"] for track in first if track["id"] in (100, 101)]
    check(len(newyear_first) <= 1, f"engine: {len(newyear_first)} Nieuwjaarsnummers in één batch")

    # Blijf bijvullen tot er een Nieuwjaarsnummer in de wachtrij staat.
    queue_ids = [track["id"] for track in first]
    for _ in range(20):
        if [track_id for track_id in queue_ids if track_id in (100, 101)]:
            break
        more = selector.choose_tracks("DagMix", player, 20, queue_ids)
        queue_ids.extend(track["id"] for track in more)
    newyear_in_queue = [track_id for track_id in queue_ids if track_id in (100, 101)]
    check(len(newyear_in_queue) == 1, f"engine: verwacht één Nieuwjaarsnummer in de wachtrij, kreeg {newyear_in_queue}")

    # Zolang dat nummer in de wachtrij staat mag er geen tweede bij.
    for _ in range(5):
        more = selector.choose_tracks("DagMix", player, 10, queue_ids)
        check(
            not [track["id"] for track in more if track["id"] in (100, 101)],
            "engine: tweede Nieuwjaarsnummer toegevoegd terwijl er al één in de wachtrij staat",
        )
        queue_ids.extend(track["id"] for track in more)

    # Alleen het Nieuwjaarsnummer in de geschiedenis: het moet terug kunnen
    # komen (exempt_from_history). Zonder die regel blokkeert de sessie-
    # geschiedenis het nummer de rest van de sessie.
    store.add_history(player, "DagMix", newyear_in_queue)
    repeated = []
    for _ in range(30):
        again = selector.choose_tracks("DagMix", player, 20, [])
        repeated.extend(track["id"] for track in again if track["id"] in (100, 101))
        if repeated:
            break
    check(bool(repeated), "engine: Nieuwjaarsnummer kwam niet terug binnen dezelfde sessie (exempt_from_history werkt niet)")


def main() -> int:
    library_db, persist_db = build_database()
    connection = connect(library_db, persist_db)

    test_seasonal_gate(connection)
    # Eerst de themaplaylist: die gebruikt de gewone tier-cooldown, dus de
    # lastPlayed-waarden die de rotatietest hierna zet mogen nog niet gelden.
    test_theme_playlist_january(connection)
    test_newyear_rotation(connection, persist_db)

    # Alle SQL-bestanden moeten in elk geval uitvoerbaar zijn.
    for sql_path in sorted(REPO.glob("*.sql")):
        for day in ("11-22", "12-20", "01-01"):
            try:
                connection.execute(sql_for(sql_path.stem, day) + " limit 1").fetchall()
            except sqlite3.Error as exc:
                check(False, f"{sql_path.name} ({day}) gaf een SQL-fout: {exc}")

    connection.close()
    test_engine_genre_rules(library_db, persist_db)

    if FAILURES:
        print(f"\n{len(FAILURES)} controle(s) mislukt.")
        return 1
    print("\nAlle Nieuwjaarscontroles geslaagd.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
