#!/usr/bin/env bash
# PLM_helpers.sh — Entry-level helpers for PLM
# Sourced by PLM.sh and PLM_manager.sh.
# TBD Requires env vars: PLM_TRASH_FOLDER, PLM_TRASH_LOG, PLM_PlayLists_Folder,
#                        PLM_Duplicates_File, PLM_Ressurect_Playlist

# TODO optional abstract out MoveEntry -c flag for -m flag to reuse

_highlight_paren()
{
     sed "s/\(([^)]*)\)/\033[1;33m&\033[0m/g"
}
_sanitize_pattern() {
    sed "
        s/'/.*/g
        s/+/.*/g
        s/(.*)//g
        s/\[/.*/g
        s/\]/.*/g
        s/(/.*/g
        s/)/.*/g
        s/&/.*/g
        s/\-/.*/g
        s/\\\\/.*/g
        s/\//.*/g
        s/;/.*/g
        s/-/.*/g
    " \
    | awk -F"= " '{print $2}' \
    | sed "
        s/ /.*/g
        s/|/.*/g
    " \
    | _highlight_paren # highlight paren
} 
 
# ---------------------------------------------------------------------------
# IfTrashing — true if the selected destination means "delete"
#   Compares on the basename, so "./rm.m3u", "rm.m3u" and an absolute path all
#   match.  "rm" / "delete" stay accepted: they are the pre-$PLM_TRASH_PLAYLIST
#   sentinels and old folders still carry them.
# ---------------------------------------------------------------------------
IfTrashing() {
    local dst=${1##*/}
    [ "$dst" == "${PLM_TRASH_PLAYLIST:-rm.m3u}" ] || [ "$dst" == "rm" ] || [ "$dst" == "delete" ]
}

# ---------------------------------------------------------------------------
# IfNewPlaylist — true if the selected destination means "make me a new m3u"
# ---------------------------------------------------------------------------
IfNewPlaylist() {
    local dst=${1##*/}
    [ "$dst" == "${PLM_NEW_PLAYLIST:-new.m3u}" ] || [ "$dst" == "new" ]
}

# ---------------------------------------------------------------------------
# _PLM_ensure_playlist — create <file> carrying the #EXTM3U header if missing
#   An existing file is left completely untouched, so this is safe to call
#   unconditionally on every dst prompt.  Header is written LF-only; the CRLF
#   in the legacy playlists is stripped by every reader anyway.
# ---------------------------------------------------------------------------
_PLM_ensure_playlist() {
    local file=$1
    [ -z "$file" ] && return 1
    [ -f "$file" ] && return 0
    printf '%s\n' "#EXTM3U" > "$file" || {
        echo "[_PLM_ensure_playlist] could not create '$file'" >&2
        return 1
    }
    echo "[_PLM_ensure_playlist] created '$file'" >&2
}

# ---------------------------------------------------------------------------
# _PLM_prompt_new_playlist — ask for a name, create the m3u, echo its ./path
#   stdout is the return channel (SelectDstPlayList's output is captured by
#   MoveEntries), so every prompt and message here goes to stderr / the tty and
#   only the resulting path is echoed.
# ---------------------------------------------------------------------------
_PLM_prompt_new_playlist() {
    local name
    # read -p writes the prompt to stderr, and -e needs the tty fzf's
    # execute() left us — hence the explicit </dev/tty.
    read -e -i "${PLM_FIXED_PLAYLIST_PREFIX}" \
         -p "New playlist name (in ${PLM_PlayLists_Folder}): " name < /dev/tty || return 1

    name=${name%$'\r'}
    name=${name#"${name%%[![:space:]]*}"}    # trim leading blanks
    name=${name%"${name##*[![:space:]]}"}    # trim trailing blanks

    if [ -z "$name" ] || [ "$name" == "${PLM_FIXED_PLAYLIST_PREFIX}" ]; then
        echo "[_PLM_prompt_new_playlist] no name given, nothing created" >&2
        return 1
    fi
    case "$name" in
        */*) echo "[_PLM_prompt_new_playlist] name may not contain '/': '$name'" >&2; return 1 ;;
    esac
    [ "${name%$PLM_M3U_EXT}" == "$name" ] && name="$name$PLM_M3U_EXT"

    _PLM_ensure_playlist "$PLM_PlayLists_Folder/$name" || return 1
    printf './%s\n' "$name"     # ./-prefixed, matching what find hands the picker
}

# ---------------------------------------------------------------------------
# _PLM_audio_regex — "\.(mp3|wav|…)$" built from $PLM_AUDIO_EXTS, for `rg -i`
#   One list, three consumers: PlayTrack, PlayArtist and RestoreEntry.  The
#   unquoted expansion is deliberate — it word-splits the space separated list.
# ---------------------------------------------------------------------------
_PLM_audio_regex() {
    local ext alt=""
    for ext in ${PLM_AUDIO_EXTS:-mp3}; do
        alt="${alt:+$alt|}$ext"
    done
    printf '\\.(%s)$' "$alt"
}

# ---------------------------------------------------------------------------
# _PLM_file_manager — the graphical file manager to hand a path to
#   $PLM_FILE_MANAGER wins if it is set; otherwise the first one installed.
#   Kept separate from OpenInExplorer so the "which one" question has a single
#   answer that the --select branch below can also test against.
# ---------------------------------------------------------------------------
_PLM_file_manager() {
    local fm
    for fm in "$PLM_FILE_MANAGER" dolphin nautilus nemo caja thunar pcmanfm xdg-open; do
        [ -n "$fm" ] && command -v "$fm" >/dev/null 2>&1 && { printf '%s\n' "$fm"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# OpenInExplorer — reveal the audio file of one m3u entry in the file manager
#   Bound to $PLM_KEY_EXPLORER in PLManager.  Takes a raw fzf hit
#   (playlist.m3u:LINE:#EXTINF:…) — the entry-pair invariant puts the path on
#   LINE+1, so this is the same (filesrc, line1, line2) parse every other
#   action does, via _parse_hit.
#
#   Three things the path needs before a GUI app will accept it:
#     * ANSI codes stripped — belt and braces.  fzf --ansi already hands {}
#       back without them, but _iter_fzf_hits strips too and a hit that
#       arrives from anywhere else must not silently become a bad filename.
#     * `\` → `/` — this library's entries use Windows separators.
#     * made absolute.  An m3u path is relative to the PLAYLIST, which is only
#       the same as PLM's CWD while the playlist sits directly in
#       $PLM_PlayLists_Folder; resolve against the playlist's own folder first
#       and fall back to CWD, which is what TrashEntry assumes.
#
#   Launched with nohup … & so the file manager outlives fzf's execute()
#   subshell — without it the window dies with the binding.
# ---------------------------------------------------------------------------
OpenInExplorer() {
    local arg=$1 fm path dir
    arg=$(printf '%s' "$arg" | sed 's/\x1b\[[0-9;]*m//g')

    # Two kinds of caller.  A library picker (PlayArtist / PlayTrack) hands over
    # the audio file itself; PLManager hands over a rg hit whose path is on the
    # NEXT line of the m3u.  Told apart by asking the filesystem rather than by
    # parsing: a hit ("list.m3u:42:#EXTINF…") is never an existing file.
    if [ -f "$arg" ] && [ "${arg##*.}" != "${PLM_M3U_EXT#.}" ]; then
        path=$arg
    else
        _parse_hit "$arg" || return 1

        path=$(awk "NR==$HIT_L2" "$HIT_FILE" | sed 's|\\|/|g' | tr -d '\r')
        if [ -z "$path" ]; then
            echo "[OpenInExplorer] no path on line $HIT_L2 of '$HIT_FILE'" >&2
            return 1
        fi

        # An m3u path is relative to the PLAYLIST, which is only the same as
        # PLM's CWD while the playlist sits directly in $PLM_PlayLists_Folder;
        # resolve against the playlist's own folder first, then fall back to
        # CWD, which is what TrashEntry assumes.
        case "$path" in
            /*) ;;
            *)  dir=$(dirname -- "$HIT_FILE")
                if [ -e "$dir/$path" ]; then path="$dir/$path"; fi ;;
        esac
    fi

    if [ ! -e "$path" ]; then
        echo "[OpenInExplorer] file not found: '$path'" >&2
        return 1
    fi
    path=$(readlink -f -- "$path")

    if ! fm=$(_PLM_file_manager); then
        echo "[OpenInExplorer] no file manager found (set \$PLM_FILE_MANAGER)" >&2
        return 1
    fi

    # --select opens the containing folder with the file highlighted; the
    # others only understand a directory, so hand them the parent.
    # nohup … & so the window outlives fzf's execute() subshell.
    case "$fm" in
        dolphin|nautilus|nemo|caja)
            nohup "$fm" --select "$path" >/dev/null 2>&1 &
            ;;
        *)
            nohup "$fm" "$(dirname -- "$path")" >/dev/null 2>&1 &
            ;;
    esac
    disown 2>/dev/null

    echo "[explorer] $fm: $path"
}

# ---------------------------------------------------------------------------
# _PLM_find_audio — every audio file directly inside <dir>
#   find -iname args are built from $PLM_AUDIO_EXTS, which replaces the old
#   brace expansion `*.{mp3,wav,…}`: braces are expanded by bash BEFORE the
#   variable, so a runtime list can't be written that way.
# ---------------------------------------------------------------------------
_PLM_find_audio() {
    local dir=$1 ext args=()
    [ -d "$dir" ] || return 1
    for ext in ${PLM_AUDIO_EXTS:-mp3}; do
        [ "${#args[@]}" -gt 0 ] && args+=( -o )
        args+=( -iname "*.$ext" )
    done
    find "$dir" -maxdepth 1 -type f '(' "${args[@]}" ')' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _PLM_colour_playlists — colour a stream of playlist paths by naming convention
#   Reads paths on stdin, writes the same paths wrapped in $PLM_COL_TEST /
#   $PLM_COL_FIXED.  Used by the PLayList picker so its rows carry the same
#   meaning as PLManager's search results (which colour theirs inside the
#   reload_cmd's sed pipeline, on the leading path field of an rg hit).
#   fzf strips the codes again under --ansi, so what it returns is a clean path.
#   Matching uses ${line##*/} rather than basename: no subshell per row.
# ---------------------------------------------------------------------------
_PLM_colour_playlists() {
    local line
    while IFS= read -r line; do
        case "${line##*/}" in
            *"$PLM_TEST_PLAYLIST_PREFIX"*) printf '%b%s%b\n' "$PLM_COL_TEST"  "$line" "$PLM_COL_OFF" ;;
            *)                             printf '%b%s%b\n' "$PLM_COL_FIXED" "$line" "$PLM_COL_OFF" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _PLM_picker_binds <preview_cmd> [preview_window] — the shared control set
#   Every screen outside PLManager (the library pickers of PlayArtist and
#   PlayTrack) gets the same keys for the things that are not about an m3u
#   entry: the player transport, reveal-in-explorer, quit, and the alt-h hints
#   sidebar.  All bound to the same $PLM_KEY_* as PLManager, so one rebind
#   covers every screen and the hints panel cannot drift out of date.
#
#   Result lands in the $PLM_PICKER_BINDS array — an array cannot travel
#   through the environment, but these pickers are assembled in the parent
#   shell, so that is enough.  Use it as:
#
#       _PLM_picker_binds 'basename {}' 'up:1'
#       fzf --query … "${PLM_PICKER_BINDS[@]}"
#
#   Differences from PLManager's versions, both deliberate:
#     * next/prev do NOT +abort here.  In PLManager aborting is how the loop
#       re-derives its query for the new track; in a picker it would throw away
#       the selection you are in the middle of making.
#     * the explorer key gets {} — a bare audio path on these screens, which
#       OpenInExplorer detects and takes as-is instead of parsing it as a hit.
# ---------------------------------------------------------------------------
_PLM_picker_binds() {
    local preview_cmd=${1:-'basename {}'}
    local preview_window=${2:-up:1}
    local qmmp_cli="nohup env QT_QPA_PLATFORM=offscreen qmmp --no-start"

    # the panel describes THIS screen; PLManager re-renders it for its own
    _PLM_render_hints picker > "$PLM_HINTS_FILE" 2>/dev/null

    local win="$preview_window"
    [ -f "$PLM_HINTS_FLAG" ] && win="$PLM_HINTS_WINDOW"

    PLM_PICKER_BINDS=(
        --bind "$PLM_KEY_QUIT:execute(PLQuit)"
        --bind "$PLM_KEY_NEXT:execute-silent($qmmp_cli --next > /dev/null 2>&1 & echo '[skip] next track' >> $PLM_LOG_FILE)"
        --bind "$PLM_KEY_PREV:execute-silent($qmmp_cli --previous > /dev/null 2>&1 & echo '[skip] previous track' >> $PLM_LOG_FILE)"
        --bind "$PLM_KEY_PAUSE:execute-silent($qmmp_cli --play-pause > /dev/null 2>&1 & echo '[play] pause/unpause' >> $PLM_LOG_FILE)"
        --bind "$PLM_KEY_EXPLORER:execute-silent(OpenInExplorer {} >> $PLM_LOG_FILE 2>&1)"
        --bind "$PLM_KEY_HINTS:transform:if [ -f \"\$PLM_HINTS_FLAG\" ]; then rm -f \"\$PLM_HINTS_FLAG\"; echo \"change-preview-window($preview_window)+refresh-preview\"; else touch \"\$PLM_HINTS_FLAG\"; echo \"change-preview-window(\$PLM_HINTS_WINDOW)+refresh-preview\"; fi"
        --preview "if [ -f \"\$PLM_HINTS_FLAG\" ]; then cat -- \"\$PLM_HINTS_FILE\"; else $preview_cmd; fi"
        --preview-window "$win"
        --header "$PLM_KEY_HINTS: keys   $PLM_KEY_NEXT/$PLM_KEY_PREV/$PLM_KEY_PAUSE: player   $PLM_KEY_QUIT: quit"
    )
}

# ---------------------------------------------------------------------------
# _PLM_render_hints [scope] — the key-hints sidebar, written to stdout
#   Built from the $PLM_KEY_* variables so a rebind can never leave the panel
#   describing keys that no longer exist.  Sized for $PLM_HINTS_WINDOW (40 col).
#
#   scope "manager" (default) — PLManager's full set.
#   scope "picker"            — the library pickers (PlayArtist / PlayTrack),
#     which share the player controls, the explorer key and quit, but have no
#     m3u entry under the cursor and so none of the move/copy/tag actions.
#     Same $PLM_HINTS_FILE and $PLM_HINTS_FLAG: whichever screen is on top
#     rewrites the file, so the panel always describes the screen you can see.
# ---------------------------------------------------------------------------
_PLM_render_hints() {
    local scope=${1:-manager}
    local b=$'\033[1m' d=$'\033[2m' o=$'\033[0m'
    local yel=$'\033[1;33m' grn=$'\033[1;32m'
    local yelr=$'\033[1;7;33m' grnr=$'\033[1;7;32m'

    # Key colours by category, from $PLM_COL_KEY_* (PLM_env) so they can be
    # retuned in one place.  Those carry \x1b[…m like the other PLM_COL_*, and
    # everything below is printed with %s, hence the one-off %b conversion.
    local kpl kmp kqm kui
    kpl=$(printf '%b' "${PLM_COL_KEY_PLAYLIST:-\x1b[1;36m}")   # m3u edits
    kmp=$(printf '%b' "${PLM_COL_KEY_MP3:-\x1b[1;35m}")        # the audio file
    kqm=$(printf '%b' "${PLM_COL_KEY_QMMP:-\x1b[1;34m}")       # the player
    kui=$(printf '%b' "${PLM_COL_KEY_PLM:-\x1b[1;37m}")        # PLM itself

    if [ "$scope" = "picker" ]; then
        printf '%s\n' \
"${b}  Library picker keys${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${kpl}enter${o}   play the selection" \
"  ${kpl}tab${o}     mark several tracks" \
"  ${kmp}${PLM_KEY_EXPLORER}${o}   show file in explorer" \
"  ${kqm}${PLM_KEY_NEXT}${o}   next track" \
"  ${kqm}${PLM_KEY_PREV}${o}   previous track" \
"  ${kqm}${PLM_KEY_PAUSE}${o} pause / unpause" \
"  ${kui}${PLM_KEY_QUIT}${o}  quit PLM + qmmp" \
"  ${kui}esc${o}     cancel the picker" \
"  ${kui}${PLM_KEY_HINTS}${o}   close this panel" \
"" \
"${d}  The picked track(s) become a tmp${o}" \
"${d}  playlist, then the normal manager${o}" \
"${d}  loop runs — where the full key set${o}" \
"${d}  applies.${o}" \
"" \
"${b}  Key colours${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${kpl}■${o} builds the queue" \
"  ${kmp}■${o} the audio file itself" \
"  ${kqm}■${o} player controls" \
"  ${kui}■${o} PLM itself"
        return 0
    fi

    printf '%s\n' \
"${b}  PLManager keys${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${kpl}enter${o}   auto — move if the source" \
"          is a ${yel}${PLM_TEST_PLAYLIST_PREFIX}${o} playlist, else copy" \
"  ${kpl}tab${o}     mark several entries" \
"  ${kpl}${PLM_KEY_MOVE}${o}  move to a playlist" \
"  ${kpl}${PLM_KEY_COPY}${o}  copy to a playlist" \
"  ${kpl}${PLM_KEY_DELETE}${o}  drop the entry (file kept)" \
"  ${kmp}${PLM_KEY_TAGS}${o}  edit tags" \
"  ${kmp}${PLM_KEY_EXPLORER}${o}   show file in explorer" \
"  ${kqm}${PLM_KEY_NEXT}${o}   next track" \
"  ${kqm}${PLM_KEY_PREV}${o}   previous track" \
"  ${kqm}${PLM_KEY_PAUSE}${o} pause / unpause" \
"  ${kqm}${PLM_KEY_RESELECT}${o}  reselect the playlist" \
"  ${kui}${PLM_KEY_QUIT}${o}  quit PLM + qmmp" \
"  ${kui}esc${o}     reopen on this track" \
"  ${kui}${PLM_KEY_HINTS}${o}   close this panel" \
"" \
"${b}  Destination picker${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${kmp}${PLM_TRASH_PLAYLIST}${o}  trash the track" \
"  ${kpl}${PLM_NEW_PLAYLIST}${o} create a playlist" \
"  ${kpl}tab${o}     write to several at once" \
"" \
"${b}  Key colours${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${kpl}■${o} playlist edits" \
"  ${kmp}■${o} the audio file itself" \
"  ${kqm}■${o} player controls" \
"  ${kui}■${o} PLM itself" \
"" \
"${b}  Row colours${o}" \
"${d}  ─────────────────────────────${o}" \
"  ${yel}■${o} ${PLM_TEST_PLAYLIST_PREFIX} playlists" \
"  ${grn}■${o} ${PLM_FIXED_PLAYLIST_PREFIX} playlists" \
"  ${yelr} ${o}/${grnr} ${o} the source playlist," \
"          currently playing"
}

# ---------------------------------------------------------------------------
# _parse_hit — split an rg/fzf hit "path/file.m3u:42:#EXTINF:…" into globals
#   filename and 2 lines: HIT_FILE / HIT_L1 / HIT_L2.  
#   Returns 1 on anything malformed, so a bad hit is skipped instead of reaching sed as line address 0.
# ---------------------------------------------------------------------------
_parse_hit() {
    local hit=$1 rest
    HIT_FILE=${hit%%:*}; HIT_FILE=${HIT_FILE#./}
 
    # parses with ${var%%:*} so the #EXTINF content's own colons can't confuse field counting.
    rest=${hit#*:}
    HIT_L1=${rest%%:*}
        # explanation of this pattern (?)
        # 1. It never enumerates fields. ${hit%%:*} is "everything before the first colon" and ${hit#*:} then %%:* is "everything between the first and second". Both are anchored to the left edge, so colons further right are inert by construction — there's no field count to get wrong, and no temptation for a future edit to reach for $3.
        #
        # 2. Old solution: line=$(echo "$hit" | awk -F: '{print $2}' | tr -cd '[:digit:]')
        # tr -cd '[:digit:]' manufactures a number from whatever it's handed instead of rejecting it. 
        # Empty input → empty string → $(( )) → 0 → sed -n "0p". And it degrades worse if the input is off by one field: fed #EXTINF:-1,... it would strip to 1, and fed the whole line it would splice the line number, the EXTINF duration, and any digits in the title into a single bogus number — which then goes into sed -i "N,Md" and silently deletes the wrong two lines of a playlist. [[ "$HIT_L1" =~ ^[0-9]+$ ]] rejects instead, which is the behaviour you want in something that does in-place deletes.
        # 3. No subshells. The old parse forked echo | awk twice per hit plus a tr — three processes for every selected entry. Parameter expansion runs in-process. It also drops echo "$hit", which is a hazard of its own: m3u paths contain backslashes (TrashEntry has a sed 's|\\|/|g' for exactly that), and echo interprets backslash escapes under sh/dash — which is what fzf's execute() may spawn.

    # validates before sed : (rejects non-numeric/zero line numbers and missing playlists), 
    if ! [[ "$HIT_L1" =~ ^[0-9]+$ ]] || (( HIT_L1 < 1 )); then
        echo "[_parse_hit] skipping malformed hit: '$hit'" >&2 
        return 1
    fi
    if [[ ! -f "$HIT_FILE" ]]; then
        echo "[_parse_hit] skipping, no such playlist: '$HIT_FILE'" >&2
        return 1
    fi
    HIT_L2=$(( HIT_L1 + 1 ))
}

# ---------------------------------------------------------------------------
# _iter_fzf_hits — dispatch one callback per line of an fzf {+f} selection file
#   then dispatch raw hit lines, 
 
# Usage: _iter_fzf_hits <callback> <hits_file>
#   The callback receives the raw hit line and parses it via _parse_hit.
# Hits are fed in descending line-number order so in-place sed deletions don't
# shift the line numbers of later hits in the same file.
# ---------------------------------------------------------------------------
_iter_fzf_hits() {
    local callback=$1 hits_file=$2 hit

    if [[ ! -r "$hits_file" ]]; then
        echo "[_iter_fzf_hits] unreadable selection file: '$hits_file'" >&2
        return 1
    fi
    [[ -n "$PLM_DEBUG" ]] && {
        echo "[_iter_fzf_hits] callback='$callback' hits:" >&2
        cat -- "$hits_file" >&2
    }

    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        "$callback" "$hit"
    done < <(sed 's/\x1b\[[0-9;]*m//g' -- "$hits_file" | sort -t: -k2,2rn) # ? what is this sort
}
# ---------------------------------------------------------------------------
# TrashEntry — move audio file + playlist entry to trash
# $1  source playlist file
# $2  line number of the #EXTINF line
# $3  line number of the file-path line  (= $2 + 1)
# ---------------------------------------------------------------------------
TrashEntry() {
    # TODO does not check for remaining duplicates
    local filesrc=$1
    local line1=$2
    local line2=$3

    echo "deleting audio file ..."
    local FILEPATH
    FILEPATH=$(awk "NR==$line2" "$filesrc" | sed 's|\\|/|g' | tr -d '\r')
            # debug
            # echo "TrashEntry, FILEPATH" >> /tmp/qmmp_status.log
            # echo $FILEPATH >> /tmp/qmmp_status.log
            # echo "TrashEntry, PLM_TRASH_FOLDER" >> /tmp/qmmp_status.log
            # echo $PLM_TRASH_FOLDER >> /tmp/qmmp_status.log 
            # debug
 
    mv "$FILEPATH" "../$PLM_TRASH_FOLDER"

    local line0content
    line0content="$(basename "$FILEPATH")"

    echo "$line0content"                                  >> "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG"
    sed -n "${line1},${line2}p" "$filesrc"                >> "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG"
        # formatting of the lines written should be :
        # raw file name
        # original M3U formatted entry
        # file path


    echo "deleting $FILEPATH from $filesrc playlist..." # remove from original playlist
        # TODO should only skip if truly is the one playing

    sed -i "${line1},${line2}d" "$filesrc"
    # nohup qmmp --next > /dev/null 2>&1
}
# mutliple-handling for TrashEntries. Takes {+f} from fzf (selection file)
TrashEntries() {
    _trash_worker() {
        _parse_hit "$1" || return 1
        TrashEntry "$HIT_FILE" "$HIT_L1" "$HIT_L2"
    }
    _iter_fzf_hits _trash_worker "$1"
    nohup qmmp --next > /dev/null 2>&1   # advance player once, after all deletions
}
# ---------------------------------------------------------------------------
# RestoreEntry — interactive restore from trash (uses fzf)
# ---------------------------------------------------------------------------
RestoreEntry() {
    # TODO! either input or fzf select
    local FILE_TO_RESTORE
    FILE_TO_RESTORE="$(_PLM_find_audio "../$PLM_TRASH_FOLDER" | fzf)"
    FILE_TO_RESTORE="$(basename "$FILE_TO_RESTORE")"
    echo "$FILE_TO_RESTORE"

    if [ -z "$FILE_TO_RESTORE" ]; then
        echo "nothing selected to restore"
        return
    fi

    # Locate the entry in the trash log (line0 = filename line)
    local line0
    line0=$(grep -i -n -m1 -- "$FILE_TO_RESTORE" "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG" | cut -d: -f1)
    echo "$line0"

    if [ -z "$line0" ]; then
        echo "could not find the file entry $FILE_TO_RESTORE from rm.log"
        return
    fi

    local line1=$(( line0 + 1 ))
    local line2=$(( line0 + 2 ))

    # Restore file to original path (line2 holds the path)
    mv "../$PLM_TRASH_FOLDER/$FILE_TO_RESTORE" \
        "$(sed -n "${line2}p" "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG")" # BUG last arg not working

    # Append entry to resurrection playlist
    # TODO which playlist? var PLM_RESTORED_PLAYLIST
    _PLM_ensure_playlist "$PLM_PlayLists_Folder/$PLM_Ressurect_Playlist"
    sed -n "${line0},${line2}p" "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG" \
        >> "$PLM_PlayLists_Folder/$PLM_Ressurect_Playlist"

    sed -i "${line0},${line2}d" "../$PLM_TRASH_FOLDER/$PLM_TRASH_LOG"
}

# ---------------------------------------------------------------------------
# SelectDstPlayList — fzf picker for destination playlist
# $1  current hit line (shown in preview)
# $2  REPORT_HINT string (blue?)
# ---------------------------------------------------------------------------
SelectDstPlayList() {
    # the trash sentinel is listed by `find`, so it has to be a real file — on a
    # fresh playlists folder it isn't, and the delete option simply vanished
    # from the picker.  Create it (header only) instead of relying on it.
    _PLM_ensure_playlist "$PLM_PlayLists_Folder/${PLM_TRASH_PLAYLIST:-rm.m3u}"

    local picked
    picked=$( { find . -path '**/.git' -prune -o -type f \
                     '(' -name "$PLM_FIXED_PLAYLIST_PREFIX*" \
                      -o -name "${PLM_TRASH_PLAYLIST:-rm.m3u}" \
                      -o -name "rm" -o -name "delete" ')' -print
                # virtual row: no such file, resolved below into a real playlist
                printf './%s\n' "${PLM_NEW_PLAYLIST:-new.m3u}" ; } | \
        fzf --multi \
            --preview "echo -e \"Processing selected playlist entry matched: $1\n$2\"" \
            --preview-window=up:2 \
            --bind "ctrl-q:become(PLQuit)" )

    [ -z "$picked" ] && return 1   # Esc

    # resolve the new.m3u sentinel — prompt once per time it was picked, and
    # drop it silently if the user aborts the prompt, so the other dsts survive
    local line out=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if IfNewPlaylist "$line"; then
            line=$(_PLM_prompt_new_playlist) || continue
        fi
        out+="$line"$'\n'
    done <<< "$picked"

    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# MoveEntry — move / copy / delete a playlist entry
    # Stray trailing shift removed how ?
# Usage: MoveEntry <flag> <hit> [output_files]
#   -m   move  (dst chosen once by MoveEntries, passed in as $3)
#   -c   copy  (dst chosen once by MoveEntries, passed in as $3)
#   -d   delete entry from playlist only (no file removal)
#   -D   send entry to PermaDel / Duplicates playlist
#   -a   auto : move if is a Test_ playlist, else : copy 
# $2 is a raw rg/fzf hit — "path/file.m3u:42:#EXTINF:..." — parsed by _parse_hit
# ---------------------------------------------------------------------------
MoveEntry() {
    local flag=$1 hit=$2 output_files=$3
    _parse_hit "$hit" || return 1 # share same mechanism to parse incoming hits
    local filesrc=$HIT_FILE line1=$HIT_L1 line2=$HIT_L2 file_
    file_=$(sed -n "${line1}p" "$filesrc" | tr -d '\r')
 
        case "$flag" in
            -m)
                        # multiple handling - dst done outside MoveEntry
                        # local output_files
                        # output_files=$(SelectDstPlayList "$2" "Moving to playlist:")
                # to handle premature exit: pressed Esc
                [ -z "$output_files" ] && return
                # deleting track takes prio
                if IfTrashing "$output_files"; then
                    TrashEntry "$filesrc" "$line1" "$line2"
                    return   # ! break operation,
                             # or spurious files (the next one) will be moved!
                fi
                # normal move block
                # handle multi by injecting output_files into dst sequentially , then move one-by-one
                while IFS= read -r dst; do
                    [ -z "$dst" ] && continue
                    if grep -Fxq -- "$(sed -n "${line1}p" "$filesrc")" "$dst" && \
                       grep -Fxq -- "$(sed -n "${line2}p" "$filesrc")" "$dst"; then
                        echo "! Track exists in $dst ! Skipping"
                    else
                        echo "Writing $file_ \n to playlist: $dst"
                        sed -n "${line1},${line2}p" "$filesrc" >> "$dst"
                    fi
                done <<< "$output_files"
                echo "deleting $file_ \n from $filesrc playlist..."
                sed -i "${line1},${line2}d" "$filesrc"
                ;;

            -c)
                        # multiple handling - dst done outside MoveEntry
                        # local output_files
                        # output_files=$(SelectDstPlayList "$2" "Copying to playlist:")
                # to handle premature exit
                [ -z "$output_files" ] && return
                # normal move block
                # handle multi by injecting output_files into dst sequentially , then move one-by-one
                while IFS= read -r dst; do
                    [ -z "$dst" ] && continue
                    if grep -Fxq -- "$(sed -n "${line1}p" "$filesrc")" "$dst" && \
                       grep -Fxq -- "$(sed -n "${line2}p" "$filesrc")" "$dst"; then
                        echo "! Track exists in $dst ! Skipping"
                    else
                        echo "Writing $file_ \n to playlist: $dst"
                        sed -n "${line1},${line2}p" "$filesrc" >> "$dst"
                    fi
                done <<< "$output_files"
                ;;

            -d)
                # if [[ "$filesrc" == Test* ]]; then
                #       option=$(echo -e "yes\nno" | fzf --prompt="Playlist is a Test. Delete audio file permanently?" --height=3 --reverse)
                #       if [[ "$option" == "yes" ]]; then
                #           TrashEntry "$filesrc" "$line1" "$line2"  
                #       else 
                #       fi
                # nohup qmmp --next > /dev/null 2>&1 &  
                # fi
                echo "deleting $file_ \n from $filesrc playlist..."
                sed -i "${line1},${line2}d" "$filesrc"
                ;;

            -D) # this is not used - rm.m3u is a better strat
                echo "TBD NOT nuking from $filesrc playlist, but writing to PermaDelete instead..."
                sed -n "${line1},${line2}p" "$filesrc" \
                    >> "$PLM_PlayLists_Folder/$PLM_Duplicates_File"
                sed -i "${line1},${line2}d" "$filesrc"
                nohup qmmp --next > /dev/null 2>&1 &
                ;;

            -a) # auto ie. did not decide the mode -> decide mode based on src filename
                #   Test_*  -> move (write to dst, then delete from src)
                #   others  -> copy (write to dst, leave src intact)
                [ -z "$output_files" ] && return
                if IfTrashing "$output_files"; then
                    TrashEntry "$filesrc" "$line1" "$line2"
                    return
                fi
                local _mode=-c
                [[ "$(basename "$filesrc")" == $PLM_TEST_PLAYLIST_PREFIX* ]] && _mode=-m
                MoveEntry "$_mode" "$hit" "$output_files"
                ;;

            *)  ;;  # silently skip unknown flags
        esac
}

# Public entry point — fzf calls this with flag + {+f} (a selection FILE, not
# N arguments: that is what keeps spaces/quotes in track titles from splitting)
MoveEntries() {
    local flag=$1 hits_file=$2   # -m / -c / -a / -d / -D

    # -m, -c and -a need one interactive dst prompt up front, before the loop
    local output_files="" hint=""
    case "$flag" in
        -m) hint='Moving to playlist:'  ;;
        -c) hint='Copying to playlist:' ;;
        -a) hint='Test_ source = move, otherwise copy:' ;;
    esac
    if [ -n "$hint" ]; then
        output_files=$(SelectDstPlayList "$(head -n1 -- "$hits_file")" "$hint")
        [ -z "$output_files" ] && return   # user pressed Esc
    fi

    _worker() { MoveEntry "$flag" "$1" "$output_files"; }

    _iter_fzf_hits _worker "$hits_file"
}

# ---------------------------------------------------------------------------
# _PLM_concat_playlists — merge N m3u files into ONE throwaway playlist
#   Usage: _PLM_concat_playlists <dst.m3u> <src.m3u> [src.m3u …]
#
# Concat a tmp plaulist in /tmp to handle multiple m3u selection in PlayList
#
# Four things the sources do that a plain `cat` gets wrong:
#   * each source carries its own "#EXTM3U" header — only the first line of
#     the merged file may be one, or qmmp treats the rest as junk entries
#   * that header often sits behind a UTF-8 BOM, so it is not literally
#     "#EXTM3U" until the BOM is stripped
#   * the sources are CRLF; a trailing \r glued onto a path makes it unopenable # TODO ? why worked before?
#   * ! paths are relative to the source playlist's OWN directory and mostly
#     Windows-style ("..\NEW L 2024_1\…"). Moving them to /tmp changes what
#     they are relative to, so they must be absolutised here.
# ---------------------------------------------------------------------------
_PLM_concat_playlists() {
    local dst=$1; shift
    if [ "$#" -eq 0 ]; then
        echo "[_PLM_concat_playlists] no source playlists given" >&2
        return 1
    fi

    local src srcdir line
    {
        printf '%s\n' '#EXTM3U'
        for src in "$@"; do
            if [ ! -f "$src" ]; then
                echo "[_PLM_concat_playlists] skipping, no such playlist: '$src'" >&2
                continue
            fi
            srcdir=$(cd -P -- "$(dirname -- "$src")" && pwd) || continue

            # `|| [ -n "$line" ]` so a final line with no trailing newline is not dropped
            while IFS= read -r line || [ -n "$line" ]; do
                line=${line%$'\r'}          # CRLF sources
                line=${line#$'﻿'}      # BOM sitting ahead of the header
                [ -z "$line" ] && continue
                case "$line" in
                    '#EXTM3U'*) continue ;;                        # only ours survives
                    '#'*) printf '%s\n' "$line"; continue ;;       # #EXTINF & friends
                esac
                line=${line//\\//}                                  # windows sep -> posix optional
                [ "${line#/}" = "$line" ] && line="$srcdir/$line"    # relative -> absolute
                printf '%s\n' "$line"
            done < "$src"
        done
    } > "$dst"
}


# Helpers for removable disk / portable lib ===========================================================================
# Library root selection
#
# One derivation point for every path that hangs off the library root, so a
# library on removable storage (a phone/SD mounted under /media, whose mount
# point changes between sessions) can be re-pointed without editing PLM or
# re-sourcing it.  $PLM_Library_Folder is the ONLY config variable that defers
# to the environment -- everything else in PLM's config block deliberately
# overrides it (see CLAUDE.md).
#
#   PLSetLibrary [path]   interactive: fzf asks mobile-vs-local, then verifies
#   _PLM_set_library      the setter itself: normalise -> verify -> export

_PLM_err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
_PLM_note() { printf '\033[2m%s\033[0m\n'    "$*" >&2; }
_PLM_cmd()  { printf '      \033[1;36m%s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# _PLM_normalize_path — clean up a hand-typed or pasted library path
#   Windows-style input is expected: this library's own m3u entries use '\'
#   separators (see _PLM_concat_playlists, which does the same substitution),
#   and a path copied out of a Windows/Poweramp context arrives the same way.
#   A drive letter cannot be resolved to a Linux path, so it is rejected loudly
#   rather than silently turned into a relative path that would then be created
#   under $PWD.
#   Echoes the cleaned path; non-zero (and quiet) means "unusable".
# ---------------------------------------------------------------------------
_PLM_normalize_path() {
    local p=$1
    p=${p%$'\r'}                                   # CRLF paste
    if [ ${#p} -ge 2 ] && [ "${p:0:1}" = '"' ] && [ "${p: -1}" = '"' ]; then
        p=${p:1:-1}                                # a whole path pasted in quotes
    fi
    p=${p//\\//}                                   # windows sep -> posix
    case $p in
        '~')   p=$HOME ;;
        '~/'*) p="$HOME/${p#\~/}" ;;
    esac
    while [ "${p//\/\//\/}" != "$p" ]; do p=${p//\/\//\/}; done   # collapse //
    [ "$p" != / ] && p=${p%/}                                     # strip trailing /

    if [[ $p =~ ^[A-Za-z]:(/|$) ]]; then
        _PLM_err "PLM: '$1' is a Windows drive path — PLM needs the Linux mount point."
        _PLM_note "      look under ${PLM_MEDIA_ROOTS:-/media} for where that drive is mounted:"
        _PLM_cmd  "lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT"
        return 1
    fi
    [ -z "$p" ] && return 1
    printf '%s\n' "$p"
}

# ---------------------------------------------------------------------------
# _PLM_probe_writable — can we actually create a file in <dir>?
#   A real write, not [ -w ].  -w is an access() call on the permission bits: it
#   does catch a plainly read-only mount, but not a device that has been pulled
#   or has thrown an I/O error and remounted itself ro underneath us, not a full
#   filesystem, and not a FUSE/SMB backend whose bits disagree with what an
#   actual open(O_CREAT) does.  Those are the removable-media failures, and PLM
#   otherwise meets them as a `sed -i` that silently loses a playlist edit.
# ---------------------------------------------------------------------------
_PLM_probe_writable() {
    local dir=$1 probe
    [ -d "$dir" ] || return 1
    probe="$dir/.plm-write-test.$$"
    ( : > "$probe" ) 2>/dev/null || return 1
    rm -f -- "$probe" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# _PLM_report_unwritable — red error + the command that would actually fix it
#   The right fix depends on how the thing is mounted, so look that up rather
#   than printing a generic chmod.
# ---------------------------------------------------------------------------
_PLM_report_unwritable() {
    local dir=$1
    local mp src fstype opts line

    mp=$(df --output=target -- "$dir" 2>/dev/null | tail -n1)
    line=$(df --output=source,fstype -- "$dir" 2>/dev/null | tail -n1)
    src=${line%% *}
    fstype=${line##* }
    opts=$(findmnt -no OPTIONS --target "$dir" 2>/dev/null)

    _PLM_err "PLM: no write access to the library: '$dir'"
    _PLM_note "      mount: ${mp:-?}   device: ${src:-?}   fs: ${fstype:-?}"

    case "$dir$mp$fstype" in
        */gvfs/*|*mtp:*|*gvfsd-fuse*)
            _PLM_note "      this is an MTP/gvfs mount — it cannot do the in-place writes"
            _PLM_note "      PLM needs (sed -i, sqlite).  Mount the device's storage as a"
            _PLM_note "      block device instead, or point PLM at a local mirror:"
            _PLM_cmd  "lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT     # find the real partition"
            _PLM_cmd  "udisksctl mount -b /dev/sdXN"
            return 1
            ;;
    esac

    local ro=0
    case ",$opts," in *,ro,*) ro=1 ;; esac

    # The mount is read-only -> the fix depends on WHO can remount it.  ntfs-3g
    # (fstype fuseblk) cannot: it answers `mount -o remount,rw` with
    # "Remounting is not supported at present. You have to umount volume and
    # then mount it once again." — so telling anyone to try that is a dead end.
    if [ "$ro" -eq 1 ]; then
        _PLM_note "      the filesystem is mounted READ-ONLY."
        case "$fstype" in
            fuseblk|ntfs)
                _PLM_note "Try umount and mount again:"
                _PLM_cmd  "sudo umount '$mp'"
                _PLM_cmd  "sudo ntfsfix -d '$src'   # clear the dirty flag that forced ro"
                _PLM_cmd  "sudo mount '$mp'"
                ;;
            vfat|exfat|msdos)
                _PLM_note "Let udisks mount it as you, rather than remounting root's mount:"
                _PLM_cmd  "sudo umount '$mp' && udisksctl mount -b '$src'"
                ;;
            *)
                _PLM_cmd  "sudo mount -o remount,rw '$mp'"
                ;;
        esac
        return 1
    fi

    # Mounted rw, so this is about ownership / the mount's uid mapping.
    case "$fstype" in
        vfat|exfat|msdos)
            _PLM_note "Remount the device as you:"
            _PLM_cmd  "sudo umount '$mp' && udisksctl mount -b '$src'"
            _PLM_cmd  "sudo mount -o uid=$(id -u),gid=$(id -g),umask=000 '$src' '$mp'"
            ;;
        *)
            _PLM_note "The mount is writable but this path is not owned by you:"
            _PLM_cmd  "sudo chown -R '$USER' '$dir'"
            _PLM_cmd  "chmod -R u+w '$dir'"
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# _PLM_set_library — point PLM at <root> and re-derive every path from it
#   Usage: _PLM_set_library <root> [--quiet] [--no-verify]
#     --quiet      no success summary (still reports failures)
#     --no-verify  skip the exists/writable checks — used by PLM's config block
#                  at source time, where a detached drive must not turn every
#                  new shell red.  PLInit does the real check on PLayList.
#   Derives: PLM_PlayLists_Folder, PLM_MUSIC_DB.  The trash stays addressed as
#   ../$PLM_TRASH_FOLDER relative to the playlists folder (same filesystem, so
#   TrashEntry's mv is a rename and not a copy over USB) and needs no export.
# ---------------------------------------------------------------------------
_PLM_set_library() {
    local root="" quiet=0 verify=1 arg
    for arg in "$@"; do
        case "$arg" in
            --quiet)      quiet=1 ;;
            --no-verify)  verify=0 ;;
            *)            [ -z "$root" ] && root=$arg ;;
        esac
    done

    if [ -z "$root" ]; then
        _PLM_err "_PLM_set_library: no library root given"
        return 1
    fi

    root=$(_PLM_normalize_path "$root") || return 1
    [ "${root#/}" = "$root" ] && root="$PWD/$root"      # relative -> absolute

    if [ "$verify" -eq 1 ]; then
        if [ ! -d "$root" ]; then
            _PLM_err "PLM: library root does not exist: '$root'"
            _PLM_note "      is the drive plugged in and mounted?"
            _PLM_cmd  "lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT"
            _PLM_cmd  "udisksctl mount -b /dev/sdXN"
            return 1
        fi
        _PLM_probe_writable "$root" || { _PLM_report_unwritable "$root"; return 1; }
    fi

    local pls="$root/${PLM_PlayLists_Folder_name:-playlists}"

    # the playlists folder is where every sed -i lands, so it gets its own probe
    # when it already exists — a root can be writable while the folder inside it
    # was restored from a backup owned by someone else.
    if [ "$verify" -eq 1 ] && [ -d "$pls" ]; then
        _PLM_probe_writable "$pls" || { _PLM_report_unwritable "$pls"; return 1; }
    fi

    export PLM_Library_Folder="$root"
    export PLM_PlayLists_Folder="$pls"
    export PLM_MUSIC_DB="$root/${PLM_MUSIC_DB_NAME:-music_index.db}"

    if [ "$quiet" -eq 0 ]; then
        printf '\033[1;32m%s\033[0m\n' "PLM library root -> $root" >&2
        _PLM_note "      PLM_PlayLists_Folder = $PLM_PlayLists_Folder"
        _PLM_note "      PLM_MUSIC_DB         = $PLM_MUSIC_DB"
        [ -d "$pls" ] || _PLM_note "      (no $PLM_PlayLists_Folder_name yet — PLInit creates it)"
        _PLM_note "      a running PL keeps its old root: restart it to pick this up"
    fi
}

# ---------------------------------------------------------------------------
# _PLM_scan_media — candidate library roots on removable storage
#   Emits "<tag>\t<path>", library-looking directories first.  $PLM_MEDIA_ROOTS
#   carries /media/$USER as well as /media because udisks inserts a per-user
#   level, which would otherwise eat the whole depth budget.
# ---------------------------------------------------------------------------
_PLM_scan_media() {
    local roots=${PLM_MEDIA_ROOTS:-"/media /media/$USER /run/media/$USER /mnt"}
    local depth=${PLM_MEDIA_DEPTH:-3}
    local name=${PLM_PlayLists_Folder_name:-playlists}
    local r d libs=() auds=() dirs=()

    while IFS= read -r d; do
        [ -d "$d" ] || continue
        if [ -d "$d/$name" ]; then
            libs+=( "$d" )
        elif [ -n "$(_PLM_find_audio "$d" | head -n1)" ]; then
            auds+=( "$d" )
        else
            dirs+=( "$d" )
        fi
    done < <(
        for r in $roots; do
            [ -d "$r" ] || continue
            find "$r" -mindepth 1 -maxdepth "$depth" \
                 -name '.*' -prune -o -type d -print 2>/dev/null
        done | sort -u
    )

    for d in "${libs[@]}"; do printf '[library]\t%s\n' "$d"; done
    for d in "${auds[@]}"; do printf '[audio]  \t%s\n' "$d"; done
    for d in "${dirs[@]}"; do printf '[dir]    \t%s\n' "$d"; done
}

# ---------------------------------------------------------------------------
# _PLM_pick_media_library — fzf over _PLM_scan_media, echoes the picked path
# ---------------------------------------------------------------------------
_PLM_pick_media_library() {
    local rows picked
    local mroots=${PLM_MEDIA_ROOTS:-"/media /media/$USER /run/media/$USER /mnt"}
    rows=$(_PLM_scan_media)

    if [ -z "$rows" ]; then
        _PLM_err "PLM: nothing mounted under $mroots"
        _PLM_note "      plug the device in, then mount it:"
        _PLM_cmd  "lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINT"
        _PLM_cmd  "udisksctl mount -b /dev/sdXN"
        _PLM_note "      an Android in MTP mode will not show up here — switch it to"
        _PLM_note "      mass-storage, or read its SD card directly."
        return 1
    fi

    picked=$( { printf '%s\n' "$rows"; printf '[type…]  \tenter a path by hand\n'; } | \
        fzf --no-multi --reverse --height='~20' \
            --delimiter=$'\t' \
            --prompt="Library root on the device: " \
            --header=$'Tag shows what the directory looks like\n[library] already holds a '"${PLM_PlayLists_Folder_name:-playlists}" \
            --preview 'ls -1 -- {2} 2>/dev/null | head -40' \
            --preview-window='right,45%,border-left' ) || return 1

    [ -z "$picked" ] && return 1
    picked=${picked#*$'\t'}

    if [ "$picked" = "enter a path by hand" ]; then
        read -e -i "${mroots%% *}/" -p "Library root: " picked < /dev/tty || return 1
        [ -z "$picked" ] && return 1
    fi
    printf '%s\n' "$picked"
}

# ---------------------------------------------------------------------------
# PLSetLibrary — user-facing: choose the library root, verify it, export it
#   Usage: PLSetLibrary [path]
#     no argument -> fzf asks whether the library is on a mobile/removable
#                    device; if it is, scan $PLM_MEDIA_ROOTS, otherwise take a
#                    typed path (readline, pre-filled with the current root).
# ---------------------------------------------------------------------------
PLSetLibrary() {
    local root=$1 where

    if [ -z "$root" ]; then
        where=$(printf '%s\n' \
                    "mobile / removable device   — scan ${PLM_MEDIA_ROOTS:-/media …}" \
                    "local disk                  — type a path" | \
                fzf --no-multi --reverse --height='~6' \
                    --prompt="Where is the music library? ") || return 1
        [ -z "$where" ] && { _PLM_note "PLSetLibrary: cancelled"; return 1; }

        case "$where" in
            mobile*) root=$(_PLM_pick_media_library) || return 1 ;;
            *)       read -e -i "${PLM_Library_Folder:-$HOME/Music/library}" \
                          -p "Library root: " root < /dev/tty || return 1 ;;
        esac
    fi

    [ -z "$root" ] && { _PLM_note "PLSetLibrary: nothing selected"; return 1; }
    _PLM_set_library "$root"
}
# Helpers for removable disk / portable lib ===========================================================================
 
# Make helpers available to fzf subshells and PLManager_manager.sh
export -f IfTrashing
export -f IfNewPlaylist
export -f _PLM_ensure_playlist
export -f _PLM_audio_regex
export -f _PLM_file_manager
export -f OpenInExplorer
export -f _PLM_render_hints
export -f _PLM_picker_binds
export -f _PLM_colour_playlists
export -f _PLM_find_audio
export -f _PLM_prompt_new_playlist
export -f _PLM_concat_playlists
export -f _parse_hit
export -f _iter_fzf_hits
export -f TrashEntry
export -f TrashEntries
 
export -f RestoreEntry
export -f SelectDstPlayList
export -f MoveEntry 
export -f MoveEntries  

# TODO ? library root selection — exported so an fzf subshell can report a dead mount
export -f _PLM_err
export -f _PLM_note
export -f _PLM_cmd
export -f _PLM_normalize_path
export -f _PLM_probe_writable
export -f _PLM_report_unwritable
export -f _PLM_set_library
export -f _PLM_scan_media
export -f _PLM_pick_media_library
export -f PLSetLibrary

# tag index — consumed ONLY by PlayArtist, never by anything playlist-related
export PLM_INDEXER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/PLM_indexer.py"

