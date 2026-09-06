#!/usr/bin/env bash
# 

source "$PLM_PATH/PLM_helpers.sh"
 
export PLM_LOG_FILE="/tmp/qmmp_status.log"
export PLM_VIEW_FILE="/tmp/PLM_view.log"
export PLM_STATUS_TMPFILE="/tmp/qmmpstatus.tmp"

# --- Wait for qmmp to start ---
while ! pgrep -x qmmp > /dev/null; do 
    sleep 0.1
done
 
# --- Helper: render a styled progress bar string ---
render_bar() {
    local current_sec=$1 total_sec=$2 time_info=$3
    local bar_length=20 percent=0 filled=0 bar=""

    if [ "$total_sec" -gt 0 ]; then
        percent=$(( 100 * current_sec / total_sec ))
    fi
    filled=$(( percent * bar_length / 100 ))

    for ((i=0; i<filled; i++));    do bar+="▓"; done
    [ "$percent" -lt 100 ] && { bar+=""; ((filled++)); }
    for ((i=filled; i<bar_length; i++)); do bar+="░"; done

    printf "%s %s\n" \
        "$(printf '\033[38;5;214m%s\033[0m' "[$bar]")" \
        "$(printf '\033[38;5;245m%s\033[0m' "($time_info)")"
}

# --- Helper: seconds from M:SS ---
time_to_seconds() {
    local time=$1
    echo $(( 10#${time%%:*} * 60 + 10#${time##*:} ))
}

# --- Main loop --- true; do # 
while  tmux has-session -t "$PLM_tmux_session" 2>/dev/null; do

    # Fetch raw qmmp status
    status=$(qmmp --status 2>/dev/null | grep -v "Qt: Session management error")
    echo "$status" > "$PLM_STATUS_TMPFILE"

    # --- Parse time / progress bar ---
    first_line=$(head -n 1 "$PLM_STATUS_TMPFILE")
    time_info=$(echo "$first_line" | grep -oP '\d+:\d+/\d+:\d+')
    current_time=$(echo "$time_info" | cut -d'/' -f1)
    total_time=$(echo "$time_info"   | cut -d'/' -f2)
    current_sec=$(time_to_seconds "$current_time")
    total_sec=$(time_to_seconds "$total_time")

    bar_line=$(render_bar "$current_sec" "$total_sec" "$time_info")

    # --- Parse metadata fields ---
    title=$(grep '^TITLE'       "$PLM_STATUS_TMPFILE" | cut -d'=' -f2- | sed 's/^ *//'  )
    artist=$(grep '^ARTIST'     "$PLM_STATUS_TMPFILE" | cut -d'=' -f2- | sed 's/^ *//')
    albumartist=$(grep '^ALBUMARTIST' "$PLM_STATUS_TMPFILE" | cut -d'=' -f2- | sed 's/^ *//')
    album=$(grep '^ALBUM ='     "$PLM_STATUS_TMPFILE" | cut -d'=' -f2- | sed 's/^ *//')

    # --- Style metadata ---
    title_line="$(printf '♫:    '; printf '\033[1;38;5;250m%s\033[0m' "$title")"  
    artist_line="/:  $(printf '\033[38;5;111m%s\033[0m' "${artist}/${albumartist}")"
    album_line="󰀥:    $(printf '\033[38;5;68m%s\033[0m' "$album")"

   
   # --- Build status block ---
    status_block=$(printf "%s\n%s\n%s\n%s" \
        "$bar_line" "$title_line" "$artist_line" "$album_line")

 
    # ==========================================
    # --- DYNAMIC PANE HEIGHT CALCULATION ---
    # ==========================================
    
    # Reserve 5 lines for the header.
    # Reserve 1 EXTRA line for a bottom safety buffer so the cursor never forces a scroll.
    # HOWEVER $PLM_STATUS_HEIGHT (27) is the true height of the status block.
    # Retune it in PLM's config block if the status block gains or loses lines.
    pane_height=$(tmux display-message -p '#{pane_height}' | tr -d '[:space:]')
    log_height=$(( pane_height - ${PLM_STATUS_HEIGHT:-27} )) 

    # --- Tail + pad the log ---
    # if (( log_height > 0 )); then
        true_lines=$(tail -n "$log_height" "$PLM_LOG_FILE" 2>/dev/null)
        
        if [[ -z "$true_lines" ]]; then
            line_count=0
        else
            line_count=$(echo "$true_lines" | wc -l)
        fi

        blank_count=$(( log_height - line_count ))
        padding=""
        for _ in $(seq 1 "$blank_count" 2>/dev/null); do padding+=$'\n'; done
        
        log_block="${padding}${true_lines}"
    # else
    #     log_block=""
    # fi

    # --- Combine and write to view file ---
    {
        echo "$status_block"
        printf '\033[38;5;240m%s\033[0m\n' "---------------------------------------------------"
        echo -n "$log_block"
    } > "$PLM_VIEW_FILE"

    # --- Display ---
    # Hide cursor (\033[?25l), move to top-left (\033[H), clear to end (\033[J)
    printf '\033[?25l\033[H\033[J'
    cat "$PLM_VIEW_FILE"

    sleep 1
done 

