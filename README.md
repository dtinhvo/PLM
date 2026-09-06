# PLM — PlayList Manager

A Bash + fzf + tmux front-end for curating an **m3u music library** that is played by a
headless [qmmp](https://qmmp.ylsoftware.com/). One track plays, PLM shows you every
playlist that track appears in, and you move / copy / trash it without leaving the keyboard.

There is no build step and no runtime: the package is a set of Bash files you `source`,
plus one Python script for the tag index.

```
PL                        tmux session
├── top pane      PLM_monitorer.sh   1 Hz `qmmp --status` + action log
└── bottom pane   PLayList           pick playlist(s) → play → manage
                  └── PLManager      one fzf screen per track
```

---

## 1. Requirements

| Tool | Used for | Minimum |
|---|---|---|
| `qmmp` | the player itself, driven only through its CLI | **2.x** (built from source, see below) |
| `fzf` | every interactive screen | ≥ 0.38 (`become(…)` bindings) |
| `ripgrep` (`rg`) | searching playlists | any |
| `bat` (`batcat`) | preview pane | any |
| `tmux` | the two-pane UI | any |
| `id3v2` | the `ctrl-e` tag editor | any |
| `python3` + `mutagen` | `PLM_indexer.py` tag index (only `PlayArtist` needs it) | any |
| `psmisc` | `killall qmmp` on quit | any |
| `git` | the playlists folder is usually its own repo | any |

### Everything except qmmp

```bash
sudo apt install -y fzf ripgrep bat tmux id3v2 python3-mutagen psmisc git
```

Two notes:

* Debian/Ubuntu install `bat` as **`batcat`**, which is the name PLM calls.
* `python3-mutagen` is only visible to `/usr/bin/python3`. If your `python3` is a pyenv /
  conda / venv one, install there instead: `python3 -m pip install mutagen`.

Optional, for the standalone `mpvyt` helpers only: `sudo apt install -y mpv socat xclip`.

### qmmp — from source

The distro package is too old (Ubuntu 24.04 ships **1.6.2**, the Qt5 series). PLM never
opens a qmmp window: it starts it with `QT_QPA_PLATFORM=offscreen` and drives it entirely
through `qmmp --status`, `--next`, `--previous`, parsing the `KEY = value` status block
that the 2.x series prints. Developed and tested against **2.3.0**.

```bash
sudo apt install -y build-essential cmake pkg-config \
    qt6-base-dev qt6-tools-dev qt6-tools-dev-tools \
    libtag1-dev libmad0-dev libvorbis-dev libogg-dev libcurl4-openssl-dev \
    libasound2-dev libmpg123-dev libflac-dev

curl -LO https://qmmp.ylsoftware.com/files/qmmp/2.3/qmmp-2.3.0.tar.bz2
tar xf qmmp-2.3.0.tar.bz2 && cd qmmp-2.3.0
cmake . -DCMAKE_BUILD_TYPE=Release && make -j"$(nproc)" && sudo make install
sudo ldconfig

qmmp --version     # expect: QMMP version: 2.3.0
```

`qt6-tools-dev-tools` is not optional — the build needs `lrelease`. Everything else in
that list is qmmp's own minimum (Qt ≥ 6.2, taglib, libmad, libvorbis/ogg, curl, ALSA);
add `libpulse-dev`, `libavcodec-dev` etc. if you want those output/decoder plugins.

---

## 2. Install

```bash
git clone <this-repo> ~/shelltools/PLM
echo 'source ~/shelltools/PLM/PLM' >> ~/.bashrc
exec bash
```

`PLM` is the only entry point; it sources `PLM_helpers.sh` and `PLM_manager.sh` relative
to its own path. Re-`source` it after editing any of the three.

### Library layout

Point `PLM_Library_Folder` at your audio and `PLM_PlayLists_Folder` at the m3u folder
(see [Configuration](#4-configuration)); the trash folder is a **sibling of the playlists
folder**, not of the library root:

```
$PLM_Library_Folder/            # audio files, any tree you like
├── playlists-stage/            # $PLM_PlayLists_Folder — often its own git repo
│   ├── OK_*.m3u                # curated keepers — the only move/copy destinations
│   ├── Test_*.m3u              # staging: moving OUT of these deletes the source entry
│   ├── rm.m3u                  # trash sentinel, auto-created if missing
│   └── new.m3u                 # (virtual — never a real file)
└── .trash/                     # $PLM_TRASH_FOLDER
    └── rm.log                  # $PLM_TRASH_LOG — what RestoreEntry reads back
```

You do not have to create any of that by hand: **`PLInit`** runs on every launch
(`PLayList` calls it, and everything else delegates to `PLayList`). It checks that the
required commands are installed, creates the playlists folder, the trash folder, the trash
log and the `rm.m3u` sentinel, and refuses to continue if `PLM_Library_Folder` does not
exist. Run it directly to check a fresh setup:

```bash
PLInit                 # idempotent — prints only what it creates or misses
PLMBuildIndex          # tag index, only needed for PlayArtist (~30 s / 19k files)
```

Every playlist must start with the `#EXTM3U` header, and **one track is exactly two
consecutive lines** — an `#EXTINF:…` line followed by the file path. Every edit PLM makes
is a line-range operation on that pair.

### Library on removable media

The library does not have to be on an internal disk. A phone, an SD card or a USB stick
works, with one catch: **its mount point changes between sessions** (`/media/$USER/PHONE`
today, `/media/$USER/PHONE1` after the next replug), so the default
`PLM_Library_Folder=$HOME/Music/library` is wrong the moment you plug something else in.

`PLSetLibrary` re-points it at runtime, and everything else follows:

```bash
PLSetLibrary                 # fzf asks mobile-vs-local, scans /media, verifies write access
PLSetLibrary /media/tvo/PHONE/Music   # or name the root directly
```

It does three things.

**1. Picks a root.** With no argument it asks whether the library is on a mobile /
removable device. If it is, it scans `$PLM_MEDIA_ROOTS` (`/media`, `/media/$USER`,
`/run/media/$USER`, `/mnt`) to `$PLM_MEDIA_DEPTH` levels and tags each candidate by what
it looks like, library-first:

```
[library]   /media/tvo/PHONE/Music        <- already holds a playlists-stage/
[audio]     /media/tvo/PHONE/Download     <- has audio files directly inside
[dir]       /media/tvo/PHONE
[type…]     enter a path by hand
```

Answer "local disk" instead and you get a readline prompt pre-filled with the current root.

**2. Accepts Windows-style paths**, because on this kind of device they are what you have
to hand — this library's own m3u entries use `\` separators. `\media\tvo\PHONE\Music`,
a path pasted complete with quotes, a stray CRLF and doubled slashes all normalise. A
`C:` drive letter is *rejected* rather than quietly treated as a relative path that would
then get created under your CWD:

```
PLM: 'E:\Music\library' is a Windows drive path — PLM needs the Linux mount point.
      lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT
```

**3. Proves write access** by creating a real file, not by testing `[ -w ]` — the
interesting removable-media failures (drive pulled, an I/O error that remounted it
read-only underneath you, a full filesystem) all pass a permission-bit check and would
otherwise surface later as a `sed -i` that silently loses a playlist edit. On failure it
looks up how the thing is actually mounted and prints the command that fixes *that*:

```
PLM: no write access to the library: '/mnt/tvo/OLD MUSIC PROXY CACHE'
      mount: /mnt/tvo   device: /dev/nvme1n1p2   fs: fuseblk
      the filesystem is mounted READ-ONLY.  Remount it rw:
      sudo mount -o remount,rw '/mnt/tvo'
      NTFS goes read-only after an unclean unmount or Windows fast-boot:
      sudo ntfsfix '/dev/nvme1n1p2' && sudo mount -o remount,rw '/mnt/tvo'
```

The hints branch on the filesystem: gvfs/MTP, a read-only mount, ntfs/fuseblk,
vfat/exfat, or plain ownership. Nothing is exported unless every check passes, so a failed
call leaves the previous library in place. `PLInit` runs the same probe on every launch,
so `PL` fails loudly at startup instead of halfway through an edit.

**What gets derived.** `PLSetLibrary` is the single point where library-relative paths are
computed — `PLM_PlayLists_Folder` and `PLM_MUSIC_DB` are *not* assigned in `PLM`'s config
block at all. The tag index deliberately lives **inside the library**
(`$PLM_Library_Folder/music_index.db`), never in a cache directory under `$HOME`: it
describes one specific tree and has to travel with it, or `PlayArtist` goes on offering
tracks from a device that is not plugged in. Same reasoning for the trash — `.trash` stays
a sibling of the playlists folder so `TrashEntry`'s `mv` is a rename on the device, not a
full copy back over USB.

A running `PL` keeps the root it started with; restart it to pick up a change.

**Practical notes.**

* Playlist entries in this library are **library-root-relative** (`..\Album\track.mp3`),
  which is what makes them survive a changing mount point. Entries holding an absolute
  path do not — `PlayTrack` and `PlayArtist` write absolute paths into their tmp
  playlists, and moving one of those into an `OK_*` playlist copies the line verbatim.
* An Android in its default **MTP** mode is not usable as a library: gvfs cannot do the
  in-place writes `sed -i` and SQLite need, and a full-library `rg`/`find` over MTP takes
  minutes. Switch the phone to mass-storage, read its SD card directly, or keep the
  library on a local mirror. `PLSetLibrary` recognises a gvfs/MTP path and says so.
* `PLM_Library_Folder` is the one config variable that defers to the environment
  (`${PLM_Library_Folder:-…}`), so re-sourcing `PLM` does not undo your choice. Export it
  in your shell rc to make one device the default.
* First run on a new device: `PLInit` creates `playlists-stage/`, `.trash/`, `rm.log` and
  `rm.m3u`; `PLMBuildIndex` builds the tag index on the device.

---

## 3. Controls

### Commands

| Command | What it does |
|---|---|
| `PL` | the full thing: tmux session, monitor pane + playlist picker (alias for `PlayList_mux`) |
| `PLayList [file.m3u …]` | picker + player + management loop, no tmux. Several arguments play concatenated |
| `PLM [query]` | the management screen only. Needs a running qmmp, or a query argument |
| `PlayTrack [query]` | fzf over every mp3 in the library → tmp playlist → normal management loop |
| `PlayArtist [query]` | pick one track, play everything by that artist (uses the tag index) |
| `PLMBuildIndex` | rebuild the mutagen/SQLite tag index. Re-run after adding music |
| `PLMTrashAllEntries <playlist>` | bulk-trash every entry in one m3u |
| `PLRenamePlaylist` | pick an m3u, type a new name |
| `RestoreEntry` | pick a file out of `.trash` and put it back |
| `PLSetLibrary [path]` | re-point the library root (fzf: mobile → scan `/media`, or local → type a path); re-derives every library path and verifies write access |
| `PLQuit` | kill the tmux session and qmmp |
| `PLM_DEBUG=1 PL` | echo every parsed fzf hit to stderr |

### Playlist picker — `PLayList`

| Key | Action |
|---|---|
| type | filter |
| `Tab` | mark several playlists — they are merged into one tmp queue and played as one |
| `Enter` | play the selection |
| `Esc` | ignored on purpose — use `ctrl-q` |
| `ctrl-q` | quit everything |

Renaming from inside the picker (`alt-r`) is currently commented out; use
`PLRenamePlaylist`.

### Track manager — `PLManager` (the main screen)

Opens fresh for each track, pre-queried with the playing artist + title, and lists every
m3u entry that matches. Row colour tells you which playlist a hit is in:

* **magenta** — the playlist currently playing (the source)
* **yellow** — `Test_*` playlists
* **green** — everything else

| Key | Action |
|---|---|
| type | re-search all playlists (query is a regex) |
| `Tab` | mark several hits; every action below applies to all of them |
| `Enter` | **auto**: prompts for a destination, then *moves* if the hit is in a `Test_*` playlist, *copies* otherwise |
| `ctrl-x` | **move**: prompts for a destination, writes the entry there, deletes it from the source |
| `ctrl-c` | **copy**: prompts for a destination, source untouched |
| `ctrl-d` | remove the entry from this playlist only — the audio file is not touched |
| `ctrl-e` | edit TITLE / ARTIST / ALBUM tags of the highlighted track (needs `$PLM_PATH`, i.e. launched through `PL`) |
| `ctrl-r` | reselect: pick a different playlist and load it into the player |
| `ctrl-q` | quit everything |
| `alt-h` | toggle the key-hints sidebar (see below) |
| `Esc` | close and reopen on the same track (the loop keeps running) |
| `ctrl-g` | placeholder, not implemented yet |

The destination prompt appears **once per action**, no matter how many rows are marked.

**The key-hints sidebar** (`alt-h`) lists every binding, the destination sentinels and the
row-colour legend. fzf has exactly one preview window, so the sidebar *is* that window:
toggling moves it from the top (track preview) to a 40-column panel on the right, and
toggling again moves it back. The state lives in `$PLM_HINTS_FLAG`, which outlives a track
change — leave it open and it stays open. The panel is rendered from the `$PLM_KEY_*`
variables, so rebinding a key updates the panel automatically.

### Destination picker

| Key / row | Action |
|---|---|
| `Tab` | write to several playlists at once |
| `Enter` | confirm |
| `rm.m3u` | **trash**: the audio file is moved to `.trash/`, the entry is logged in `rm.log` and removed from the source |
| `new.m3u` | **create**: prompts for a name (pre-filled `OK_`, `.m3u` appended if you leave it off), writes the `#EXTM3U` header, then uses the new playlist as the destination |
| `Esc` | cancel the whole action |

Only `OK_*` playlists are offered as real destinations — that is what makes `OK_` mean
"curated keeper".

### Tag editor — `ctrl-e`

Opens `$PLM_EDITOR` (`$EDITOR`, then `nvim`) on three `KEY:<tab>value` lines. Save and quit and
the values are written back to the mp3 with `id3v2`; the file path itself is untouched.

### Monitor pane

Read-only. Refreshes at 1 Hz for as long as the tmux session lives, and exits by itself on
`PLQuit`. It shows the progress bar, the current tags, and the tail of the action log.

---

## 4. Configuration

Everything is `export`ed near the top of `PLM` — override there, or in your shell before
sourcing.

| Variable | Default | Meaning |
|---|---|---|
| `PLM_PATH` | the folder `PLM` was sourced from | where the sibling scripts live (`PLM_tag_editor.sh`, `PLM_monitorer.sh`, `PLM_indexer.py`) |
| `PLM_Library_Folder` | `$HOME/Music/library` | where the audio lives. **The one variable that defers to the environment** (`${PLM_Library_Folder:-…}`), so `PLSetLibrary` survives a re-source |
| `PLM_MEDIA_ROOTS` | `/media /media/$USER /run/media/$USER /mnt` | where `PLSetLibrary` looks for a removable library |
| `PLM_MEDIA_DEPTH` | `3` | how deep that scan goes under each root |
| `PLM_PlayLists_Folder_name` | `playlists-stage` | m3u folder, relative to the library |
| `PLM_PlayLists_Folder` | `$PLM_Library_Folder/$PLM_PlayLists_Folder_name` | absolute form; **CWD for everything below `PLM`**. Derived by `_PLM_set_library`, not assigned in the config block |
| `PLM_AUDIO_EXTS` | `mp3 wav flac aac ogg m4a` | every extension the library and trash pickers accept |
| `PLM_EDITOR` | `${EDITOR:-nvim}` | rename bindings + tag editor |
| `PLM_FIXED_PLAYLIST_PREFIX` | `OK` | curated keepers = the only real destinations |
| `PLM_TEST_PLAYLIST_PREFIX` | `Test` | staging; source of an `Enter` action means *move*, not copy |
| `PLM_PLAYLIST_SEPARATOR` | `_` | what sits between prefix and name in a real filename |
| `PLM_M3U_EXT` / `PLM_M3U_HEADER` | `.m3u` / `#EXTM3U` | extension and the header every playlist opens with |
| `PLM_TRASH_PLAYLIST` | `rm.m3u` | destination sentinel meaning "trash it" |
| `PLM_NEW_PLAYLIST` | `new.m3u` | destination sentinel meaning "make a new playlist" |
| `PLM_NEW_PLAYLIST_PREFIX` | `OK_` | pre-filled in that prompt |
| `PLM_TRASH_FOLDER` | `.trash` | sibling of the playlists folder |
| `PLM_TRASH_LOG` | `rm.log` | trash journal `RestoreEntry` reads |
| `PLM_Ressurect_Playlist` | `Test_99_Resurrected.m3u` | restored entries are appended here |
| `PLM_MUSIC_DB` | `$PLM_Library_Folder/$PLM_MUSIC_DB_NAME` | SQLite tag index. Derived like the above; **always inside the library**, never a cache dir under `$HOME` — it describes that tree and must travel with it |
| `PLM_MUSIC_DB_NAME` | `music_index.db` | the index's filename within the library |
| `PLM_INDEXER` | next to `PLM_helpers.sh` | path to `PLM_indexer.py` |
| `PLM_KEY_MOVE` / `_COPY` / `_DELETE` / `_TAGS` / `_RESELECT` / `_QUIT` | `ctrl-x` `ctrl-c` `ctrl-d` `ctrl-e` `ctrl-r` `ctrl-q` | PLManager bindings; the hints panel is rendered from them |
| `PLM_KEY_HINTS` | `alt-h` | toggles the key-hints sidebar |
| `PLM_HINTS_FILE` / `PLM_HINTS_FLAG` | `/tmp/…` | rendered panel / "sidebar is open" state |
| `PLM_HINTS_WINDOW` / `PLM_PREVIEW_WINDOW` | `right,40,border-left` / `up,60%,…` | the two preview-window geometries the toggle swaps between |
| `PLM_tmux_session` | `PLMmux` | tmux session name |
| `PLM_logger_height` / `PLM_status_height` | `20` / `9` | tmux split sizing |
| `PLM_STATUS_HEIGHT` | `27` | rendered height of the monitor's status block; the log tail gets `pane_height` minus this |
| `PLM_LOG_FILE` / `PLM_VIEW_FILE` / `PLM_qmmp_STATUS_FILE` | `/tmp/…` | action log, rendered frame, raw status |
| `PLM_CONCAT_PLAYLIST` | `/tmp/qmmp_concat_playlist.m3u` | merge target for multi-playlist play |
| `MANAGING_FLAG` | `/tmp/PLM_managingFlag` | loop control between `PLM` and `PLManager` |
| `PLM_DEBUG` | unset | `1` dumps every parsed fzf hit to stderr |

The two prefixes deliberately carry **no trailing `_`**: they are used both anchored
(`"$PREFIX"*`, the destination picker and the move/copy rule) and loose (`*"$PREFIX"*`,
the search passes), so a separator baked into the value would need a second, stripped copy
of each variable. `PLM_PLAYLIST_SEPARATOR` supplies the `_` where a real filename is being
built.

Note the block uses `export VAR=…`, not `${VAR:=…}` — it **overrides** the environment.
Change your paths by editing the block, not by exporting before you source. The single
exception is `PLM_Library_Folder`, written `${PLM_Library_Folder:-…}` so that a library on
removable storage survives a re-source; `PLM_PlayLists_Folder` and `PLM_MUSIC_DB` are not
in the block at all, because `_PLM_set_library` derives them from the root (see
[Library on removable media](#library-on-removable-media)).

### Still hardcoded

Known portability gaps, if you are running this somewhere other than the machine it grew
up on:

* `mntE` (`PLM`) has a literal NTFS device and mount point.
* **`batcat`** (`PLM_manager.sh`, preview command) — that name is Debian/Ubuntu-only. They
  rename upstream's `bat` because of a clash with the `bacula` console; on Arch, Fedora,
  Homebrew or a `cargo install` the binary is plain `bat`. A `PLM_BAT` resolver
  (`command -v batcat || command -v bat`) would cover both.
* `killall` (`PLQuit`, `PlayStop`) needs `psmisc`; `qmmp` itself is a literal at ~15 sites.
* `/tmp/qmmp_activePLaylist`, `/tmp/PLM_monitorer.sh`, `/tmp/qmmp_track_playlist.m3u`,
  `/tmp/qmmp_artist_playlist.m3u` are literals even though the neighbouring state files
  have variables; `PLM_monitorer.sh` re-declares its own copies of three of them (and calls
  the raw-status file `PLM_STATUS_TMPFILE`, a second name for `PLM_qmmp_STATUS_FILE`).
* `PLM_indexer.py` is mp3-only (mutagen's `MP3`/`EasyID3`) and does not read
  `PLM_AUDIO_EXTS`, so `PlayArtist`'s *picker* offers all six extensions but its index
  lookup only ever returns mp3.
* `PLM_FZF_DEFAULT_OPTS` is defined but never consumed.
* The config block cannot be overridden from the environment, apart from `PLM_Library_Folder` (see above).

---

## 5. Troubleshooting

| Symptom | Cause |
|---|---|
| `ctrl-q` does nothing | `PLQuit` is exported inside `PLayList` — a code path that skipped it has no export |
| Edits to `PLM_monitorer.sh` have no effect | it is copied to `/tmp` by `PlayList_mux`; restart with `PL` |
| An action silently fails inside fzf | a function reachable from a binding is missing its `export -f` |
| `PlayArtist` finds nothing | stale tag index — re-run `PLMBuildIndex` |
| Nothing is writable | the library is on a read-only mount. `PL`, `PLInit` and `PLSetLibrary` probe with a real file create and print the command that works for *that* filesystem — note a directory can show `drwxrwxrwx` and still be unwritable, because those bits are recorded on the volume, not permission to write to the mount |
| `Remounting is not supported at present` | ntfs-3g cannot remount rw in place. `sudo umount <mp>`, `sudo ntfsfix -d <dev>` to clear the dirty flag, then `sudo mount <mp>`. ntfs-3g drops to read-only when the volume is dirty — an unclean unmount, or Windows left it hibernated by fast startup (boot Windows and shut down fully rather than forcing it) |
| `library root does not exist` after replugging | the device came back on a different mount point — re-run `PLSetLibrary` |
| A Windows path is refused | a `C:`-style drive letter cannot be resolved; give the Linux mount point (`lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT`). Backslash separators themselves are fine |
| An Android shows nothing under `/media` | it is in MTP mode, which PLM cannot use — switch to mass-storage or read the SD card directly |
