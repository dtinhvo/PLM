#!/bin/bash
filesrc=$(echo "$1" | awk -F: '{print $1}') # {1}
filesrc=${filesrc#./};
line=$(echo "$1" | awk -F: '{print $2}'| tr -cd '[:digit:]' ) # {2}
line1=$(($line));
line2=$(($line+1));
FILEPATH=$(awk "NR==$line2" "$filesrc" | sed 's|\\|/|g; s/\r//g; s/[[:space:]]*$//' )  # = _PLM_norm_path; not sourced here  

# Extract to editable format
stty sane
# ID3v1-only files (e.g. all of Taeko Onuki) have no TIT2/TPE1/TALB frames to read: promote v1 -> v2 first
id3v2 -l "$FILEPATH" | grep -q "^TIT2" || id3v2 -C "$FILEPATH" > /dev/null
echo -e "TITLE:\t$(id3v2 -l "$FILEPATH" | grep "^TIT2" | sed 's/TIT2.*: //')" > metadata.txt
echo -e "ARTIST:\t$(id3v2 -l "$FILEPATH" | grep "^TPE1" | sed 's/TPE1.*: //')" >> metadata.txt
echo -e "ALBUM:\t$(id3v2 -l "$FILEPATH" | grep "^TALB" | sed 's/TALB.*: //')" >> metadata.txt

# Edit the file
${PLM_EDITOR:-${EDITOR:-nvim}} metadata.txt < /dev/tty > /dev/tty 2>&1

title=$(grep "^TITLE:" metadata.txt | sed 's/^TITLE:\t*//')
artist=$(grep "^ARTIST:" metadata.txt | sed 's/^ARTIST:\t*//')
album=$(grep "^ALBUM:" metadata.txt | sed 's/^ALBUM:\t*//')

# Read back and apply
mapfile -t meta < metadata.txt
id3v2 --song "$title" --artist "$artist" --album "$album" "$FILEPATH"
rm -f metadata.txt
# TODO file to log

