# Highlighting

PLManager's preview pane is not the m3u file itself. It is batcat's rendering of the
playlist, piped through `sed` / `awk` filters that add colour on top. The command is
`preview_cmd`, built in `PLManager` (`PLM_manager.sh`).

**What batcat prints.** Every line starts with a coloured line-number column. Line 13
looks like this byte for byte (`ESC` = the `\x1b` byte):

```
ESC[38;2;131;148;150m  13ESC[0m ESC[38;2;131;148;150m│ESC[0m ESC[38;2;248;248;242m/m/Album X/t6.mp3ESC[0m
└──── colour on ─────┘└num┘└off┘                        └──── the m3u line's own text ───┘
```

Any filter that cares about *which* line it is on has to read the number out of that
column, between the first colour code's closing `m` and the next `ESC`.

**How the command gets its values: three layers.**

1. **`PLManager` runs `printf`** to build `preview_cmd`. The format string is in single
   quotes, so fzf placeholders and `$(( ))` are copied in as literal text; only the `%s`
   slots are filled (the album pattern, and the bracket-flip filter `FLIP_PREVIEW`).
2. **fzf substitutes the placeholders** each time the cursor moves to a hit: `{1}` → the
   playlist file, `{2}` / `{r2}` → the hit's line number. `{2}` comes out quoted
   (`'12'`); `{r2}` is raw (`12`), which is the one to use inside `$(( ))`.
3. **The shell fzf spawns** evaluates whatever is left, e.g. `$(( 12 + 1 ))` → `13`.

## Matching

The playing track's album is coloured blue wherever it appears in the preview:

```
sed "s/<album>/\x1b[34m&\x1b[0m/g"
```

- `<album>` is `$3`, from `Album2Pattern`: qmmp's `ALBUM` field run through
  `_sanitize_pattern`, which turns punctuation and spaces into `.*`. It is a regex, not
  a literal string.
- When there is no album, `${3:-.^}` substitutes `.^`, a regex that can never match, so
  the filter becomes a no-op instead of a broken `s//…/`.
- Brackets get a second pass: `(…)` groups go yellow, and `FLIP_PREVIEW`
  (`_PLM_flip_header_brackets`) reverses the ones that exactly match the playing
  track's TITLE / ALBUM brackets.

### Line-targeted

The blue album match is applied to **one line only**: the line after the hit.

**Why line + 1.** Search hits always land on the `#EXTINF` line (`rg` searches for
`EXTINF.*{q}`), and the m3u entry-pair rule puts the file path on the very next line.
The album is in that path, so that is the line worth colouring.

**How.** `sed` takes an optional address before a command: `/regex/s/a/b/g` runs the
substitution only on lines matching `/regex/`. The replacement is unchanged; the
address does the targeting:

```
sed "/^[^m]*m *$(( {r2} + 1 ))\x1b/s/<album>/\x1b[34m&\x1b[0m/g"
```

For a hit on line 12, layers 2 and 3 above turn the address into
`/^[^m]*m *13\x1b/`:

| Piece | Matches |
|---|---|
| `^[^m]*m` | everything up to and including the **first** `m` on the line, which closes the colour code `ESC[38;2;…m`. `[^m]*` cannot cross an `m`, so it cannot run on into the line's text. |
| ` *` | batcat's padding (it right-aligns numbers to 4 columns) |
| `13` | the target line number |
| `\x1b` | the `ESC` that turns the colour off. It must follow the digits immediately, so `13` cannot match line `113` or `130`. |

The first-`m` anchor also stops `3` from matching line `13`: after the `m` come spaces,
then `1`, not `3`. A looser `^.* *3\x1b` could skip the `1`. The anchor still holds when
line numbers reach five digits and batcat stops padding them.

The bracket flip targets lines the same way (TITLE brackets on `{r2}`, ALBUM brackets
on `{r2} + 1`), but through awk, which strips the colour codes first and can therefore
use the plainer address `^ *13 `.
