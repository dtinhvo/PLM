#!/usr/bin/env bash
# PLM_manager.sh — Core interactive playlist manager (PLManager) and supporting pieces.
# Sourced by PLM.sh.  Requires PLM_helpers.sh to be sourced first.
# Requires env vars: PLM_TEST_PLAYLIST_PREFIX, PLM_LOG_FILE, PLM_PATH,
#                    PLM_KEY_* (bindings), PLM_HINTS_FILE / _FLAG / _WINDOW and
#                    PLM_PREVIEW_WINDOW (the key-hints sidebar),
#                    RG_PLM_PREFIX (set here if not already set)

# ---------------------------------------------------------------------------
# rg prefix used by every search in this file
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                           TODOS
# TODO preview a duplicate (other line of rg hits)  
# FEAT dynamically make new list
# BUG! a playlist with a EXTM3U 1line start (empty rest) not deleted
# ———————————————————————— all modes ———————————————————————— 
# BUG for ctrl - r , dont reload if esc
# --- modals / UX
# BUG! F2 is not renaming the host playlist 
# FEAT!! handle --multi --> MoveEntry to read beyond $2
# FEAT bind +- to seek

# TODO! Conditionals 
    # if targetting a test track:
        # C-d -> 
            # if no other playlist have this (no other hit), force delete!
            # else prompt for full file rm  (option 2)
    # return-to-Test:
        # banish a track (maybe multi input?) to testing
# ———————————————————————— Move / Copy ———————————————————————— 
# 
# ———————————————————————— -d ———————————————————————— 
# TODO $4 or $5 will not exist, so pass from MoveEntries here an option to Trash
    # the core PLManager needs to return a count of available rg hits on -d

# ———————————————————————— rm ———————————————————————— 
# TODO abstract ./rm ./.trash and ./.delete folders. cleanup
    # BUG!! after rm, can no longer select or resurrect --> rm needs to be a .m3u
    # Test: rm then resurrect
# TODO!! Testing convenience with duplicates:
    # 1. C-g: quick-snap to other match
        #  play the file 
        #  enter or Esc to get back 
    # 2. ? quick delete for duplicates
    # 3.
    # if other matches before 
    # 
# FEAT!  HARD ! keybind to temp switch to the other track in matches
# FEAT warn if from OK_ hits, delete and no more OK_ hits remain

# FEAT sanitation 
    # should be a way to directly inquire current playing FILE exactly 
    # BUG!! if playing and hit a file that is not playable, delete from m3u
        # how to undo this action?

##########################
# ———————————————————————— UI ———————————————————————— 
# BUG minor UI
    # reload is not parsing () correctly
    # MoveEntry : let selectDstPlaylist read from m3u entry --> display what file getting processed
        # dumps filesrc to tmp 

# ---------------------------------------------------------------------------
 


export RG_PLM_PREFIX='rg --line-number --no-heading -i'
    # FEAT! RG should highlight Test and OK differently https://chatgpt.com/c/682c65fd-1238-8003-87d3-fe4e0671e636 
        # define color vars
        # find all playlists -> sub color codes -> pipe to rg
 
    # rg does not play well with file spec somehow
    # Note:
    # 1. select ARTIST line and not ALBUMARTIST
    # 2. remove any text inside parenthesis
    # 2a. remove quotes and replace with .*
    # 3. print the thing after "=" 
    # 3a. another sed to make space .* - This solves when there is a ; for artists 

    # Entry management issues
    # (todo optional) later can parse $hit into filesrc and line variables, but difficult and dangerous: https://claude.ai/chat/edcf2afb-bd06-4d30-a8fb-ec1e96e0416d


# ---------------------------------------------------------------------------
# Pattern converters — turn qmmp status fields into rg-friendly patterns
# ---------------------------------------------------------------------------

Track2Pattern() {
    # BUG!! ( remix ) is not getting included in query
    qmmp --status 2>/dev/null | grep "TITLE" \
        | _sanitize_pattern
}

Artist2Pattern() {
    qmmp --status 2>/dev/null | grep "ARTIST" | grep -v "ALBUMARTIST" \
        | _sanitize_pattern
}

Album2Pattern() {
    qmmp --status 2>/dev/null | grep "\bALBUM\b" \
        | _sanitize_pattern 
}

# ---------------------------------------------------------------------------
# ReselectPlayingList — fzf picker to choose + load a different playlist
# ---------------------------------------------------------------------------
ReselectPlayingList() {
    local activePlaylistFile
    # Same row colouring as the PLayList picker and PLManager's own results
    # (see $PLM_COL_* in PLM_env).  Runs inside fzf's become() subshell, which is
    # why _PLM_colour_playlists is export -f'd.  --ansi both renders the codes and
    # strips them from the return value, so qmmp still receives a plain path.
    activePlaylistFile=$(find $PLM_PlayLists_Folder \
            -path '**/.git' -prune -o -type f -print \
        | _PLM_colour_playlists | \
        fzf --ansi --bind "ctrl-q:execute(PLQuit)"
    ) 
    # TODO! var for path here
    QT_QPA_PLATFORM=offscreen qmmp "$activePlaylistFile" >/dev/null 2>&1
    QT_QPA_PLATFORM=offscreen qmmp --next >/dev/null 2>&1  # next track for random
}
export -f ReselectPlayingList

# ---------------------------------------------------------------------------
# PLManager — core interactive fzf session for a single track
#   match currently playing track with playlists containing it
#
# $1  artist pattern
# $2  title  pattern
# $3  album  pattern  (used for preview colouring)
# $4  source playlist filename
# ---------------------------------------------------------------------------
PLManager() {
    echo "      ---***---       " | tee -a "$PLM_LOG_FILE"
            # echo "Processing entry: $(qmmp --status 2>/dev/null | grep "ARTIST" | head -c -1) $(qmmp --status 2>/dev/null | grep "TITLE")" # debug
 

    # ── preview command ──────────────────────────────────────────────────
    local preview_cmd
    preview_cmd=$(printf \
        'batcat --color=always {1} --highlight-line {2} | sed "s/%s/\x1b[34m&\\x1b[0m/g" | sed "s/\(([^)]*)\)/\033[1;33m&\033[0m/g" || batcat --color=always {1} --highlight-line {2} | sed "s/%s/\x1b[34m&\\x1b[0m/g" | sed "s/\(([^)]*)\)/\033[1;33m&\033[0m/g"' \
        "${3:-.^}" "${3:-.^}") # ? this line?
    SRC_BASE=$(basename "$4" | _sanitize_pattern)

    # ── check if playlist is a merged one ─────────────────────────────────────────────
    local MERGED=""
    if [ -n "$PLM_CONCAT_PLAYLIST" ] && \
       [ "$(basename "$4")" = "$(basename "$PLM_CONCAT_PLAYLIST")" ]; then
        MERGED=1
    fi
    local MERGED_NOTICE='*** MERGED PLAYLIST — NO SINGLE SOURCE PLAYLIST ***'

    # ── rg call fragments ─────────────────────────────────────────────────
    local COL_TEST="$PLM_COL_TEST"
    local COL_FIXED="$PLM_COL_FIXED"
    local COL_OFF="$PLM_COL_OFF"
    local COL_SRC="$PLM_COL_FIXED_SRC"
    case "$(basename "$4")" in
        *"$PLM_TEST_PLAYLIST_PREFIX"*) COL_SRC="$PLM_COL_TEST_SRC" ;;
    esac

    local FMT_CONTENT='sed "s|\([^:]*:[^:]*:[^:]*:\)\(.*\)|\1\x1b[97m\2\x1b[0m|" \
        | sed "s/(\([^)]*\))/\x1b[1;33m&\x1b[0m/g"' 

    local STRIP_ANSI='sed "s|\x1b\[[0-9;]*m||g"'

    local HL_SRC=' '"$STRIP_ANSI"' \
        | sed "s|^[^:]*'"$SRC_BASE_ESC"'|'"$COL_SRC"'&'"$COL_OFF"'|" \
        | '"$FMT_CONTENT"

    local HL_TEST=' '"$STRIP_ANSI"' \
        | sed "s|^[^:]*|'"$COL_TEST"'&'"$COL_OFF"'|" \
        | '"$FMT_CONTENT"

    local HL_FIXED=' '"$STRIP_ANSI"' \
        | sed "s|^[^:]*|'"$COL_FIXED"'&'"$COL_OFF"'|" \
        | '"$FMT_CONTENT"
 
    # local HL='sed "s/{q}/\x1b[34m&\x1b[0m/g" | sed "s/(\([^)]*\))/\x1b[1;33m&\x1b[0m/g"' # hl rules for rg hit lines
    # local HL_SRC='sed "s|^[^:]*'"$SRC_BASE"'|\\x1b[1;4m&\\x1b[0m|"' 

    # Priority 1 — the source playlist itself  (always exactly one hit)
    local RG_SRC="$RG_PLM_PREFIX --glob $(basename "$4") -e '(?s)EXTINF.*{q}'"
    # Priority 2 — Test playlists (excluding $4 to avoid duplicate)
    local RG_TEST="$RG_PLM_PREFIX --glob '*$PLM_TEST_PLAYLIST_PREFIX*' --glob '!$(basename "$4")' -e '(?s)EXTINF.*{q}'"
    # Priority 3 — the fixed/keeper playlists ($PLM_FIXED_PLAYLIST_PREFIX) and any
    # stray m3u that follows neither convention.  The glob stays a negation of
    # Test so an oddly named playlist is still listed rather than silently dropped.
    local RG_FIXED="$RG_PLM_PREFIX --glob '!*$PLM_TEST_PLAYLIST_PREFIX*' --glob '!$(basename "$4")' -e '(?s)EXTINF.*{q}'"
    local reload_cmd

    # if there is no 1 source playlist , ordering makes less sense, but Test still go first
    if [ -n "$MERGED" ]; then # no priority-1 pass: there is no source playlist
        reload_cmd="( $RG_TEST | $HL_TEST || true ; $RG_FIXED | $HL_FIXED || true )"
    else
        reload_cmd="( $RG_SRC | $HL_SRC || true ; $RG_TEST | $HL_TEST || true ; $RG_FIXED | $HL_FIXED || true )" # combined reload string
    fi


    # ── rg reload helper (used in comments / future refactor) ────────────
    # reloader() {
    #   ($RG_PLM_PREFIX --glob '*Test*' -e '(?s)EXTINF.*'"$1" || true
    #    $RG_PLM_PREFIX --glob '!*Test*' -e '(?s)EXTINF.*'"$1" || true)
    # }

    local header_text # header text for selector
    header_text=$(qmmp --status 2>/dev/null | sed -n -e '2p' -e '3p' -e '4p' -e '5p'  | sed 's/\(([^)]*)\)/'$'\033''[1;33m&'$'\033''[0m/g'  | awk '{ if (NR == 4) print "\033[34m" $0 "\033[0m"; else print $0 }')
    [ -n "$MERGED" ] && header_text=$'\033[1;35m'"$MERGED_NOTICE"$'\033[0m\n'"$header_text"

    # preview banner: name the playlist, or  lack thereof
    local preview_title="$activePlaylistFile"
    [ -n "$MERGED" ] && preview_title="$MERGED_NOTICE"

    # ── key-hints sidebar ────────────────────────────────────────────────
    # use the preview window
    _PLM_render_hints > "$PLM_HINTS_FILE" 2>/dev/null
    local preview_window="$PLM_PREVIEW_WINDOW"
    [ -f "$PLM_HINTS_FLAG" ] && preview_window="$PLM_HINTS_WINDOW"
    # ─────────────────────────────────────────────────────────────────────

    local hit
    hit=$(fzf --ansi --disabled  --query "$1.*$2" \
                            --header "$header_text" \
                            --color "hl:-1:underline,hl+:-1:underline:reverse,header:white" \
                            --ignore-case \
                            --bind "start:reload:$reload_cmd" \
                            --bind "change:reload:$reload_cmd" \
                            --bind "$PLM_KEY_QUIT:become(PLQuit )" \
                            --bind "$PLM_KEY_TAGS:execute($PLM_PATH/PLM_tag_editor.sh {} | tee -a $PLM_LOG_FILE)+reload($reload_cmd)" \
                            --bind "$PLM_KEY_DELETE:execute(MoveEntries -d {+f} | tee -a $PLM_LOG_FILE )+reload($reload_cmd)" \
                            --bind "$PLM_KEY_MOVE:execute(MoveEntries -m {+f} | tee -a $PLM_LOG_FILE )+reload($reload_cmd)" \
                            --bind "$PLM_KEY_COPY:execute(MoveEntries -c {+f} | tee -a $PLM_LOG_FILE )+reload($reload_cmd)" \
                            --bind "ctrl-g:become(TBD)+reload($reload_cmd)" \
                            --bind "$PLM_KEY_HINTS:transform:if [ -f \"\$PLM_HINTS_FLAG\" ]; then rm -f \"\$PLM_HINTS_FLAG\"; echo \"change-preview-window(\$PLM_PREVIEW_WINDOW)+refresh-preview\"; else touch \"\$PLM_HINTS_FLAG\"; echo \"change-preview-window(\$PLM_HINTS_WINDOW)+refresh-preview\"; fi" \
                            --bind "$PLM_KEY_RESELECT:become(ReselectPlayingList )+reload(fzf --ansi --disabled  --query "$1.*$2" )" \
                            --delimiter : \
                            --preview "if [ -f \"\$PLM_HINTS_FLAG\" ]; then cat -- \"\$PLM_HINTS_FILE\"; else echo -e \" \n╭─ Processing selected playlist: \033[1;35m $preview_title \033[0m \n╰─ press $PLM_KEY_HINTS for control hints ────────────────────────────────────────\n \";$preview_cmd; fi" \
                            --preview-window "$preview_window") # WARN even pipe outside here would not work | tee -a $PLM_LOG_FILE 
    # how fzf's +f handles multi for me:
    # writes the selection to a temp file and substitutes the path to that file — one word, always. So no matter how many entries you Tab-select, the binding expands to a 2-argument call:
        # select 1 entry   →  MoveEntries -m /tmp/fzf-sel-8231
        # select 12 entries →  MoveEntries -m /tmp/fzf-sel-8231

    if [ -z "$hit" ]; then
        #Managing=0
        # echo "No files selected. Restarting management with Managing signal: $Managing" # debug
        return 
    fi

    # ── multi-line selection: auto mode ─────────────────────────────────────────────
    local hits_file
    hits_file=$(mktemp /tmp/PLM_selection.XXXXXX)
    printf '%s\n' "$hit" > "$hits_file" # multi == to file

    MoveEntries -a "$hits_file" | tee -a "$PLM_LOG_FILE" # auto mode

    rm -f "$hits_file"
    touch "$MANAGING_FLAG"
} 
