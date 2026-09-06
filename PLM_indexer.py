#!/usr/bin/env python3
# WARN not tested
"""PLM_indexer.py — mp3 tag index for PlayArtist.

Scope, deliberately narrow:
  The ONLY consumer is the PlayArtist bash function in PLM. This database must
  never hold playlist contents. PLM edits .m3u files in place, by line number,
  with sed (see the entry-pair invariant in CLAUDE.md) — any cached playlist
  membership here would silently drift behind those edits and become a second,
  wrong source of truth. Tracks only.

Why mutagen and not ffprobe/id3v2 + shell parsing:
  tag values are arbitrary user text (quotes, backslashes, semicolons, newlines,
  ANSI-looking sequences). Parsing that out of a subprocess's stdout in bash is
  the bug factory this file exists to avoid. mutagen hands back real strings and
  they reach sqlite through bind parameters, so nothing is ever re-parsed.
  It is also ~5x faster: it reads the ID3 header only (~27s for 19k files)
  instead of spawning a process per file.

Usage:
  PLM_indexer.py build [--library DIR] [--db PATH]
      Rebuild the index from scratch. Always a full rewrite — never incremental.
      Written to a temp file and atomically renamed, so an interrupted build
      leaves the previous index intact.

  PLM_indexer.py artist-tracks [--db PATH] NAME
      Print the absolute path of every track whose ARTIST or ALBUMARTIST
      contains NAME (case-insensitive, substring), one per line.

The database is written to $PLM_MUSIC_DB, which PLM derives from the library root
($PLM_Library_Folder/music_index.db) — it belongs to the library it describes and
must not be cached elsewhere under $HOME.

Directories whose name starts with '.' are pruned — this is what keeps $PLM_TRASH_FOLDER
(.trash) and .git out of the index. Without it, PlayArtist would queue tracks
you already trashed.
"""

import argparse
import os
import sqlite3
import sys
from pathlib import Path

try:
    from mutagen.easyid3 import EasyID3
    from mutagen.mp3 import MP3
except ImportError:
    sys.exit("PLM_indexer: mutagen is not installed — pip install mutagen")

DEFAULT_LIBRARY = os.environ.get(
    "PLM_Library_Folder", str(Path.home() / "Music" / "library")
)
# The index lives IN the library, never in a local cache dir. It describes one
# specific tree, so it has to travel with it: on removable storage a cached copy
# under $HOME would go on answering PlayArtist with tracks from a device that is
# no longer plugged in. Falling back to the library root here keeps a standalone
# run of this script (no PLM_MUSIC_DB exported) on the same file PLM uses.
DEFAULT_DB_NAME = os.environ.get("PLM_MUSIC_DB_NAME", "music_index.db")
DEFAULT_DB = os.environ.get("PLM_MUSIC_DB") or str(
    Path(DEFAULT_LIBRARY) / DEFAULT_DB_NAME
)

SCHEMA = """
CREATE TABLE tracks (
    id             INTEGER PRIMARY KEY,
    title          TEXT,
    artist         TEXT,
    albumartist    TEXT,
    album          TEXT,
    duration_sec   REAL,
    -- casefolded copies so lookups need no SQL functions and no LIKE escaping;
    -- sqlite's own lower() is ASCII-only and would miss non-latin artists
    artist_lc      TEXT,
    albumartist_lc TEXT,
    rel_path       TEXT UNIQUE,
    full_path      TEXT
);
"""

COLUMNS = (
    "title", "artist", "albumartist", "album", "duration_sec",
    "artist_lc", "albumartist_lc", "rel_path", "full_path",
)
INSERT = f"INSERT OR REPLACE INTO tracks ({','.join(COLUMNS)}) VALUES ({','.join('?' * len(COLUMNS))})"

EMPTY_TAGS = {k: None for k in ("title", "artist", "albumartist", "album")}
EMPTY_TAGS["duration_sec"] = None


def casefold(value):
    """Unicode-aware lowercase, NULL-preserving."""
    return value.casefold() if value else None


def iter_mp3(base):
    """Every .mp3 under base, skipping dotted directories (.trash, .git)."""
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.lower().endswith(".mp3"):
                yield Path(root) / name


def read_tags(path):
    """Tag dict for one file, or None if mutagen cannot read it at all."""
    try:
        audio = MP3(path, ID3=EasyID3)
    except Exception:
        return None

    tags = audio.tags or {}

    def field(key):
        # ID3 frames are multi-valued; join with '; ', the separator the rest of
        # PLM already expects (see _sanitize_pattern in PLM_helpers.sh)
        values = tags.get(key) or []
        joined = "; ".join(v.strip() for v in values if v and v.strip())
        return joined or None

    return {
        "title": field("title"),
        "artist": field("artist"),
        "albumartist": field("albumartist"),
        "album": field("album"),
        "duration_sec": audio.info.length if audio.info else None,
    }


def build(library, db_path):
    base = Path(library).expanduser().resolve()
    if not base.is_dir():
        sys.exit(f"PLM_indexer: library not found: {base} (is the drive mounted?)")

    db_path = Path(db_path).expanduser()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = db_path.with_name(db_path.name + ".tmp")
    for stale in (tmp_path, Path(str(tmp_path) + "-journal")):
        if stale.exists():
            stale.unlink()

    print(f"PLM_indexer: scanning {base}", file=sys.stderr)

    conn = sqlite3.connect(tmp_path)
    conn.executescript(SCHEMA)

    total = unreadable = skipped = 0
    batch = []
    try:
        for path in iter_mp3(base):
            total += 1
            full = str(path)

            # a newline in a path would split into two m3u lines and desync the
            # entry-pair invariant downstream; such a file cannot be played anyway
            if "\n" in full or "\r" in full:
                skipped += 1
                print(f"PLM_indexer: skipping path with newline: {full!r}", file=sys.stderr)
                continue

            tags = read_tags(path)
            if tags is None:
                unreadable += 1
                tags = dict(EMPTY_TAGS)

            try:
                rel = path.relative_to(base).as_posix()
            except ValueError:
                rel = full

            batch.append((
                tags["title"], tags["artist"], tags["albumartist"], tags["album"],
                tags["duration_sec"],
                casefold(tags["artist"]), casefold(tags["albumartist"]),
                rel, full,
            ))

            if len(batch) >= 1000:
                conn.executemany(INSERT, batch)
                batch.clear()
                print(f"  {total} files...", file=sys.stderr)

        if batch:
            conn.executemany(INSERT, batch)
        conn.commit()
    finally:
        conn.close()

    if total == 0:
        tmp_path.unlink(missing_ok=True)
        sys.exit(f"PLM_indexer: no mp3 found under {base} — index left unchanged")

    os.replace(tmp_path, db_path)
    print(
        f"PLM_indexer: indexed {total} tracks -> {db_path}"
        f"  ({unreadable} unreadable tags, {skipped} skipped)",
        file=sys.stderr,
    )


def artist_tracks(name, db_path):
    pattern = casefold(name.strip() if name else "")
    if not pattern:
        sys.exit("PLM_indexer: empty artist name")

    db_path = Path(db_path).expanduser()
    if not db_path.is_file():
        sys.exit(f"PLM_indexer: no index at {db_path} — run PLMBuildIndex")

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        # instr() is a plain substring test: no LIKE wildcards to escape, and the
        # needle arrives as a bind parameter, so quotes/backslashes in an artist
        # name ("Guns N' Roses") are inert
        rows = conn.execute(
            "SELECT full_path FROM tracks "
            " WHERE (artist_lc      IS NOT NULL AND instr(artist_lc, ?)      > 0) "
            "    OR (albumartist_lc IS NOT NULL AND instr(albumartist_lc, ?) > 0) "
            " ORDER BY album IS NULL, album, full_path",
            (pattern, pattern),
        ).fetchall()
    finally:
        conn.close()

    for (full_path,) in rows:
        print(full_path)


def main():
    parser = argparse.ArgumentParser(description="mp3 tag index for PLM's PlayArtist")
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="rebuild the index from scratch")
    p_build.add_argument("--library", default=DEFAULT_LIBRARY)
    p_build.add_argument("--db", default=DEFAULT_DB)

    p_query = sub.add_parser("artist-tracks", help="paths whose ARTIST/ALBUMARTIST match")
    p_query.add_argument("--db", default=DEFAULT_DB)
    p_query.add_argument("name")

    args = parser.parse_args()
    if args.command == "build":
        build(args.library, args.db)
    else:
        artist_tracks(args.name, args.db)


if __name__ == "__main__":
    main()
