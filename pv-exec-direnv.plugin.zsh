#!/usr/bin/env zsh
#
# pv-exec-direnv - quiet direnv integration for zsh, pv_exec style.
# Bundles its own copy of the pv_exec popview library plus the direnv
# integration (animated package box, auto-retract, one-line summary).
# Only requirement: direnv installed (nix for the flake package listing).
#
# Load from zshrc:
#   zinit ice wait"1" lucid depth=1
#   zinit light Wateir/pv-exec-direnv

command -v direnv >/dev/null 2>&1 || return 0

#!/usr/bin/env zsh
#
# Amor et potentia oppressis.
#

########################################
# Avoid using tput since each call spawns a process. Echoti (or sending raw escape codes)
# is orders of magnitude faster.
pv_get_term_width()  {
    local out_cols=$1   # after zsh 5.10+ use: local -n out_cols=$1
    if [[ -n "${COLUMNS:-}" ]]; then
        # after zsh 5.10+ use: out_cols="$COLUMNS"
        : ${(P)out_cols::="$COLUMNS"}
    else
        __cols=$(echoti cols 2>/dev/null) || __cols=80
        # after zsh 5.10+ use: out_cols="$__cols"
        : ${(P)out_cols::="$__cols"}
    fi
    return 0
}
pv_get_term_height() {
    local out_lines=$1   # after zsh 5.10+ use: local -n out_lines=$1
    if [[ -n "${LINES:-}" ]]; then
        # after zsh 5.10+ use: out_lines="$LINES"
        : ${(P)out_lines::="$LINES"}
    else
        __lines=$(echoti lines 2>/dev/null) || __lines=50
        # after zsh 5.10+ use: out_lines="$__lines"
        : ${(P)out_lines::="$__lines"}
    fi
    return 0
}

pv_start_buffered_update() { print -nr -- $'\033[?2026h'; }  # start buffered update mode
pv_end_buffered_update()   { print -nr -- $'\033[?2026l'; }  # end buffered updated mode (flushes output)

pv_tput_clear() { echoti clear; }       # clear screen
pv_tput_smcup() { echoti smcup; }       # start alternate screen (screen+cursor saved, clear, no scroll back)
pv_tput_rmcup() { echoti rmcup; }       # exit alternate screen (screen+cursor restored)

pv_tput_rmam()  { echoti rmam; }        # disable auto-wrapping of lines (no automatic margins)
pv_tput_smam()  { echoti smam; }        # enable auto-wrapping of lines (automatic margins)

pv_tput_civis() { echoti civis 2>/dev/null || print -nr -- $'\033[?25l'; }  # hide cursor (raw escape fallback)
pv_tput_cnorm() { echoti cnorm 2>/dev/null || print -nr -- $'\033[?25h'; }  # show cursor (raw escape fallback)

pv_tput_cuf()   { echoti cuf $1; }      # cursor forward (relative: move-right)
pv_tput_cup()   { echoti cup $1 $2; }   # cursor position (absolute: y, x)
pv_tput_sc()    { echoti sc; }          # cursor save
pv_tput_rc()    { echoti rc; }          # cursor restore

pv_tput_el()    { echoti el; }          # erase from cursor to end-of-line

pv_tput_csr()   { echoti csr $1 $2; }   # set vertical scroll region (top, bottom)
pv_tput_rcsr()  {
    # reset vertical scroll region to entire term
    local -i height=0
    pv_get_term_height height
    echoti csr 0 $((height - 1));
}

pv_get_cursor_row() {
    emulate -L zsh
    local out_row=$1   # after zsh 5.10+ use: local -n out_row=$1

    local fd  # open controlling terminal for r+w
    exec {fd}<>/dev/tty || return 1

    # Save TTY and switch to no echo and no waiting
    local old=$(stty -g <&$fd)
    stty -echo -icanon min 1 time 1 <&$fd

    # Request report cursor position (CPR), preferring echoti over escape code.
    if ! echoti u7 >&$fd 2>/dev/null; then
        printf '\033[6n' >&$fd
    fi

    # Read reply: ESC [ row ; col R (1-based)
    local resp
    IFS= read -r -d R -u $fd resp
    local read_ok=$?

    # Immediately restore TTY
    stty "$old" <&$fd
    exec {fd}>&-

    # And then parse the result
    if ((read_ok == 0)); then
        resp=${resp#*$'\033['}        # Strip leading ESC[
        local row=${resp%%;*}
        if [[ $row == <-> ]]; then
            ((row--)) # 0-based to match 'tput cup'
            # after zsh 5.10+ use: out_row="${row}"
            : ${(P)out_row::="${row}"}
            return 0
        fi
    fi
    return 1
}

########################################
# Similar to sleep(), but doesn't start a new process.
pv_sleep() {
    local duration=$1
    local -i zsel_duration=$((100 * duration))
    zselect -t $zsel_duration
    return 0
}

########################################
program_exists() {
    command -v "$1" &>/dev/null
    return $?
}

########################################
# Remove escape sequences (used to set color, style, cursor pos, etc.) using zsh parameter expansion.
strip_control_chars() {
    setopt localoptions extendedglob
    local input=$1
    local output=$2 # after zsh 5.10+ use: local -n output=$2

    local cleaned=${input//*$'\x0D'/}                  # Remove everything up to and including CR

    cleaned=${cleaned//$'\033['[0-9;]#[a-zA-Z]/}       # Most CSI sequences
    cleaned=${cleaned//$'\033'[a-zA-Z]/}               # Simple ESC sequences
    cleaned=${cleaned//$'\033'[0-9]/}                  # ESC + single digit
    cleaned=${cleaned//$'\033Y'??/}                    # VT52 cursor positioning

    cleaned=${cleaned//$'\x9B'[0-9;]#[a-zA-Z]/}        # 8-bit CSI sequences
    cleaned=${cleaned//[$'\x80'-$'\x8F'$'\x91'-$'\x98'$'\x9A'$'\x9E'-$'\x9F']/} # Single-byte C1
    cleaned=${cleaned//$'\007'/}                       # Bell character (BEL)

    # Note using parameter expansion (above) is orders of magnitude faster than using sed
    # or anything that spawns a new process.

    # after zsh 5.10+ use: output="$cleaned"
    : ${(P)output::="$cleaned"}
    return 0
}

stripped_len() {
    local handle_widechars=$1
    local stripped=""
    strip_control_chars "$2" stripped
    local outlen=$3     # after zsh 5.10+ use: local -n outlen=$3
    local -i width=0
    if [[ $handle_widechars == "true" ]]; then
        # Optimization: only try to handle widechars if caller requests it.
        local -i i=1
        local -i len=${#stripped}
        while (( i <= len )); do
            # Basic heuristic for common wide characters
            local char="${stripped[i]}"
            local codepoint=$((#char))
            if (( codepoint >= 0x1F000 && codepoint <= 0x1F9FF )); then
                ((width += 2))  # Emojis
            elif (( codepoint >= 0x2600 && codepoint <= 0x27BF )); then
                ((width += 2))  # Miscellaneous Symbols and Dingbats (includes ✅ at U+2705)
            elif (( codepoint >= 0x4E00 && codepoint <= 0x9FFF )); then
                ((width += 2))  # CJK Unified Ideographs
            elif (( codepoint >= 0x3000 && codepoint <= 0x303F )); then
                ((width += 2))  # CJK Symbols and Punctuation
            elif (( codepoint >= 0xAC00 && codepoint <= 0xD7AF )); then
                ((width += 2))  # Hangul Syllables
            elif (( codepoint >= 0xFF01 && codepoint <= 0xFF60 )); then
                ((width += 2))  # Fullwidth Forms
            else
                ((width += 1))  # Normal width
            fi
            ((i++))
        done
    else
        width=${#stripped}
    fi
    # after zsh 5.10+ use: outlen="$width"
    : ${(P)outlen::="$width"}
    return 0
}

text_trunc() {
    local -i width=$1
    local handle_widechars=$2
    local text_str=$3
    local out_text=$4   # after zsh 5.10+ use: local -n out_text=$4

    # Strip colors to get just the visible text (otherwise padding calculation are off)
    local -i text_len=0;  stripped_len $handle_widechars "$text_str" text_len
    local -i chop=$((width - text_len))
    if (( chop < 0 )); then
        if (( width > 3 )); then
            text_str="${text_str:0:$((chop-3))}..."
        elif (( text_len > -chop )); then
            text_str="${text_str:0:$chop}"
        else
            text_str=""
        fi
    fi
    # after zsh 5.10+ use: out_text="$text_str"
    : ${(P)out_text::="$text_str"}
    return 0
}

########################################
# This encodes a file name or file path it into an absoluste file:// URL.
url_encode_file() {
    setopt localoptions extendedglob
    local filepath="${1:A}"     # :A normalizes filename/path to an absolute path
    local out_url=$2            # after zsh 5.10+ use: local -n out_url=$2
    local encoded_url="file://"

    local -i pos filepath_len=${#filepath}
    for (( pos=1; pos<=filepath_len; pos++ )); do
        local ch=${filepath[pos]}
        if [[ "$ch" == [a-zA-Z0-9._~/-] ]]; then
            encoded_url+="$ch"
        else
            local hex=""
            print -v hex -f "%02X" "'$ch"
            encoded_url+="%$hex"
        fi
    done
    # after zsh 5.10+ use: out_url="encoded_url"
    : ${(P)out_url::="$encoded_url"}
    return 0
}

# This extracts a UI label to show for the URL, which is the filename
# with spaces (%20) decoded. If the URL isn't pointing to a filename
# then the entire encoded URL is just returned.
url_extract_ui_label() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_label=$2       # after zsh 5.10+ use: local -n out_label=$2

    # Strip trailing slashes
    in_url="${in_url%/}"

    # Extract everything after the last slash
    local filename="${in_url##*/}"

    # If filename part exists (not empty or just query params)
    if [[ -n "$filename" && "$filename" != \?* ]]; then
        filename="${filename%%\?*}"  # Strip ?query
        filename="${filename%%\#*}"  # Strip #fragment

        # Test for filename extensions.
        if [[ "$filename" == *.* && "$filename" != .* ]]; then
            # Test against common extensions
            local extension="${filename##*.}"
            if [[ "${extension:l}" == (txt|out|html|htm|pdf|doc|docx|zip|tar|gz|json|xml|csv|md|js|css|py|sh|zsh|conf|toml|yaml|yml|log) ]]; then
                filename=${filename//\%20/ }  # for display labels convert encoded spaces back to space chars.
                # after zsh 5.10+ use: out_label="filename"
                : ${(P)out_label::="$filename"}
                return 0
            fi
            # # Or just assume if extension < 6 characters it is likely a file?
            # if (( ${#extension} <= 5 )); then
            #     filename=${filename//%20/ }  # for display labels convert encoded spaces back to space chars.
            #     # after zsh 5.10+ use: out_label="filename"
            #     : ${(P)out_label::="$filename"}
            #     return 0
            # fi
        fi
    fi

    # Default to returning the full URL if we aren't confident we can extract a filename.
    # after zsh 5.10+ use: out_label="in_url"
    : ${(P)out_label::="$in_url"}
    return 0
}

# This escape encodes the URL arg (file://, http://, etc.) into a sequence that most
# terminal apps (not macOS Terminal, unfortunately) recognize and allow for hot clicking
# (normally via CMD+click).
url_term_render() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_text=$2       # after zsh 5.10+ use: local -n out_text=$2
    local url_text=""

    local label=""
    url_extract_ui_label "$in_url" label

    local url_glyph="🔗"
    if [[ "$in_url" == file://* ]]; then
        local url_glyph="🧾"
    fi

    # Try escaped hyperlink encoding in supported terminals. Could probably remove this conditional
    # and just always do the encoding.
    local -i render_blue=0
    if [[ -n "${TERM_PROGRAM:-}" && "${TERM_PROGRAM:l}" == (iterm.app|apple_terminal) ]]; then
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s \033]8;;%s\007%s\033]8;;\007${PV_RESET}" "$url_glyph" "$in_url" "$label"
        else
            print -v url_text -f "%s \033]8;;%s\007%s\033]8;;\007" "$url_glyph" "$in_url" "$label"
        fi
    else
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s %s${PV_RESET}" "$url_glyph" "$label"
        else
            print -v url_text -f "%s %s" "$url_glyph" "$label"
        fi
    fi
    # after zsh 5.10+ use: out_text="$url_text"
    : ${(P)out_text::="$url_text"}
    return 0
}

########################################
typeset -i _TERM_BG_ISDARK_RTN_VAL=-1
term_bg_isdark() {
    if ((_TERM_BG_ISDARK_RTN_VAL != -1)); then
        return $_TERM_BG_ISDARK_RTN_VAL
    fi

    local -i is_dark=1   # Default to dark (1) if all queries below fail.
    if [[ -n "$COLORFGBG" ]]; then
        local bg_color_index="${COLORFGBG##*;}"
        if (( bg_color_index < 8 )); then
            is_dark=1   # Dark background
        else
            is_dark=0   # Light background
        fi
    else
        # $COLORFGBG not defined (caller probably using SSH), so query terminal directly.
        if program_exists "stty"; then
            local saved_settings=$(stty -g 2>/dev/null)
            if [[ -n "$saved_settings" ]]; then
                {
                    stty raw -echo min 0 time 3 2>/dev/null
                    printf '\033]11;?\a' > /dev/tty  # Make sure query goes to terminal
                    local response=""
                    local char
                    while read -t 2 -k 1 char 2>/dev/null; do
                        response+="$char"
                        [[ "$char" == $'\a' || "$response" == *$'\033\\' ]] && break
                    done
                    stty "$saved_settings" 2>/dev/null

                    if [[ "$response" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
                        local r=$((16#${match[1]:0:2}))  # zsh arithmetic with hex
                        local g=$((16#${match[2]:0:2}))
                        local b=$((16#${match[3]:0:2}))
                        local luminance=$(((r * 299 + g * 587 + b * 114) / 1000))
                        # echo "DEBUG: RGB L=$r $g $b   $luminance" > /dev/tty; sleep 5
                        if (( luminance < 128 )); then
                            is_dark=1
                        else
                            is_dark=0
                        fi
                    fi
                } 2>/dev/null
            fi
        fi
    fi
    if ((is_dark)); then
        _TERM_BG_ISDARK_RTN_VAL=0
    else
        _TERM_BG_ISDARK_RTN_VAL=1
    fi
    return $_TERM_BG_ISDARK_RTN_VAL
}

if term_bg_isdark; then
    # Dark terminal background - use bright foreground colors
    LOG_TEXT_COLOR='\033[37m'           # Light gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[96m'    # Bright cyan for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[96m'      # Bright cyan for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[92m'   # Bright green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[93m'   # Bright yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[91m'   # Bright red for failure text messages
else
    # Light terminal background - use dark foreground colors
    LOG_TEXT_COLOR='\033[90m'           # Dark gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[34m'    # Dark blue for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[34m'      # Dark blue for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[32m'   # Dark green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[33m'   # Dark yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[31m'   # Dark red for failure text messages
fi

########################################
_yield_to_parser() {
    # Before calling pv_get_term_width/height, we must force zsh to hit its parser
    # boundary processing which will update $COLUMNS and $LINES (which our pv_get_term_*
    # funcs use). If we don't do this then we never detect window resizing. I tried
    # using local trap on WINCH and the global TRAPWINCH() function, but those will not
    # work either without the parser boundary processing. The local trap on WINCH is only
    # processed when parser boundary is hit. The global TRAPWINCH() function is called
    # immediately (via signal) BUT any variables it updates (like RESIZE_NEEDED=1) will
    # not be reflected in our loop here until the parser boundary. The only solution
    # would be to write to a temp FD inside TRAPWINCH() that we then add to our zselect,
    # but even with that we would then (here) still need to force the parser boundary
    # (using /usr/bin/true, sleep 0.01, etc.) to have $COLUMNS and $LINES updates, so
    # the only gain is that we would process the resize more quickly. Given our zselect
    # delay here is very short (PV_SPINNER_UPDATE_INTERVAL), we will handle the resize
    # quickly enough without all that extra overhead/code.
    /usr/bin/true
    # Here are a couple of alternative techniques for forcing parser boundary that
    # are slower. I tried to find a way to trip it without having to call/spawn a
    # new process but couldn't find any that worked.
    #   : | :
    #   sleep 0.001
    return 0
}

_render_label_processing() {
    local label=$1
    pv_tput_rmam  # disable auto-wrapping of lines
    printf "  ${PROCESSING_TEXT_COLOR}%s${PV_RESET}" "$label"
    pv_tput_el
    pv_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_done() {
    local label=$1
    local label_color=$2
    local outfile=$3

    pv_tput_rmam  # disable auto-wrapping of lines
    local outfile_term_rendered=""
    if [[ -n "$outfile" ]]; then
        local outfile_url=""
        url_encode_file "$outfile" outfile_url
        url_term_render "$outfile_url" outfile_term_rendered

        local -i label_width=${#label}
        local -i log_to_padding=$((PV_LOG_TO_PADDING - label_width))
        ((log_to_padding < 1)) && log_to_padding=1
        printf "${label_color}%s${PV_RESET}%*s logged to: %s" "$label" "$log_to_padding" "" "$outfile_term_rendered"
    else
        printf "${label_color}%s${PV_RESET}" "$label"
    fi
    pv_tput_el
    pv_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_success() {
    local label=$1
    local outfile=$2

    if (( PV_PLAIN_LABEL )); then
        print -v label -f "%s" "$label"
    else
        print -v label -f "✓ %s success" "$label"
    fi
    _render_label_done "$label" "$PROCESSING_TEXT_COLOR" "$outfile"
    return 0
}

_render_label_failure() {
    local label=$1
    local outfile=$2
    local rc=$3

    print -v label -f "✗ %s failed with rc %d" "$label" "$rc"
    _render_label_done "$label" "$MSG_FAILURE_TEXT_COLOR" "$outfile"
    return 0
}

_append_log_timestamp() {
    local outfile="$1"
    local msg="${@:2}"  # Capture args 2+ directly

    if [[ -z "$outfile" ]]; then
        return 0
    fi
    local parent_dir="$(dirname "$outfile")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir" 2>/dev/null
    fi

    if [[ -f "$outfile" && -s "$outfile" ]]; then
        local border_str=${(l:86::━:):""}
        printf "\n\n%s\n" "$border_str" >> "$outfile"
    fi
    print "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$outfile"
    return 0
}

_start_popview() {
    local label=$1
    pv_get_term_width PV_WIN_ORIG_WIDTH; pv_get_term_height PV_WIN_ORIG_HEIGHT

    print                               # Placeholder for label (will be filled in below)
    local -i placeholder_lines_needed="$PV_MAX_HEIGHT"
    if ((PV_BORDER_SHOW)); then
        local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
        local border_str=${(l:$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 2))::─:):""}
        print -v PV_TOP_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╭%s╮${PV_RESET}" "$padleft_str" "$border_str"
        print -v PV_BOT_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╰%s╯${PV_RESET}" "$padleft_str" "$border_str"
        print                           # Placeholder for top border
        ((placeholder_lines_needed++))  # Additional placeholder line needed for bottom border
    fi
    local -i count
    for (( count = 1; count < placeholder_lines_needed; count++ )); do
        print                           # Placeholders for scroll view output region
    done

    # Render the task label above the scroll view.
    pv_get_cursor_row PV_TOP_ANCHOR
    PV_TOP_ANCHOR=$((PV_TOP_ANCHOR - PV_MAX_HEIGHT))
    ((PV_BORDER_SHOW)) && ((PV_TOP_ANCHOR-=2))
    ((PV_TOP_ANCHOR < 0)) && PV_TOP_ANCHOR=0
    pv_tput_cup $PV_TOP_ANCHOR 0
    _render_label_processing "$label"

    # Define scroll region to PV_MAX_HEIGHT rows (enabled later when first output line arrives).
    PV_TOP_SCROLLREGION=$((PV_TOP_ANCHOR + 1))
    ((PV_BORDER_SHOW)) && ((PV_TOP_SCROLLREGION++))
    PV_BOT_SCROLLREGION=$((PV_TOP_SCROLLREGION + PV_MAX_HEIGHT - 1))
    pv_tput_cup "$PV_TOP_SCROLLREGION" 0   # move cursor to top-left of scroll region
    PV_CUR_HEIGHT=0
    return 0
}

_end_popview_leave_open() {
    local label=$1
    local outfile=$2
    local rc=$3

    pv_tput_cup $PV_TOP_ANCHOR 0
    if (( rc == 0 )); then
        _render_label_success "$label" "$outfile"
    else
        _render_label_failure "$label" "$outfile" "$rc"
        if ((PV_BORDER_SHOW && PV_CUR_HEIGHT > 0)); then
            # Re-render the border in red (leaving text inside view untouched).
            pv_get_term_width PV_WIN_ORIG_WIDTH; pv_get_term_height PV_WIN_ORIG_HEIGHT

            local -i rt_border_xpos=$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_RIGHT - 1))
            local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
            local border_str=${(l:$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 2))::─:):""}
            print -v PV_TOP_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╭%s╮${PV_RESET}" "$padleft_str" "$border_str"
            print -v PV_BOT_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╰%s╯${PV_RESET}" "$padleft_str" "$border_str"

            print "$PV_TOP_BORDER_STR"
            local -i index=0    ypos=$PV_TOP_SCROLLREGION
            for (( index = 0; index < PV_CUR_HEIGHT; index++, ypos++ )); do
                pv_tput_cup "$ypos" 0;                  printf "%s${MSG_FAILURE_TEXT_COLOR}│" "$padleft_str"
                pv_tput_cup "$ypos" "$rt_border_xpos";  print "│${PV_RESET}"
            done
            print "$PV_BOT_BORDER_STR"
            return 0
        fi
    fi
    if ((PV_CUR_HEIGHT > 0)); then
        local -i ypos=$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT - 1))
        ((PV_BORDER_SHOW)) && ((ypos++))
        pv_tput_cup "$ypos" 0
        print
    fi
    return 0
}

_end_popview_with_close() {
    local label=$1
    local outfile=$2

    pv_tput_cup $PV_TOP_ANCHOR 0
    (( PV_QUIET_CLOSE )) || _render_label_success "$label" "$outfile"
    if ((PV_CUR_HEIGHT == 0)); then
        if (( PV_QUIET_CLOSE )); then
            pv_tput_el    # nothing was rendered: just wipe the label line
        fi
        return 0  # Nothing was ever rendered, so no cleanup needed.
    fi

    pv_sleep $PV_CLOSE_PAUSE_DELAY
    local -i unused_width=0 unused_height=0
    if _process_win_resize unused_width unused_height; then
        (( PV_QUIET_CLOSE )) || _render_label_success "$label" "$outfile"
        return 0
    fi

    if ((PV_BORDER_SHOW && PV_BORDER_ANIMATE_CLOSE)); then
        PV_BOT_SCROLLREGION=$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT))
        pv_tput_csr "$PV_TOP_SCROLLREGION" "$PV_BOT_SCROLLREGION"; PV_INSIDE_TPUTCSR=1
        pv_tput_cup "$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT))" 0
        local -i index
        for (( index = 0; index < PV_CUR_HEIGHT; index++ )); do
            print
            pv_sleep $PV_CLOSE_FRAME_DELAY
            if _process_win_resize unused_width unused_height; then
                (( PV_QUIET_CLOSE )) || _render_label_success "$label" "$outfile"
                return 0
            fi
        done
        ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
        pv_tput_cup "$((PV_TOP_ANCHOR + 2))" 0;     pv_tput_el
        pv_tput_cup "$((PV_TOP_ANCHOR + 1))" 0;     pv_tput_el
    else
        local -i top=$((PV_TOP_ANCHOR + 1))
        local -i bottom=$((PV_BOT_SCROLLREGION))
        if ((PV_BORDER_SHOW)); then
            ((bottom++))
        fi
        local -i row
        for (( row = bottom; row >= top; row-- )); do
            pv_tput_cup $row 0;     pv_tput_el
            if ((PV_BORDER_ANIMATE_CLOSE)); then
                pv_sleep $PV_CLOSE_FRAME_DELAY
            fi
        done
    fi
    if (( PV_QUIET_CLOSE )); then
        # wipe the label line too so nothing is left behind
        pv_tput_cup $PV_TOP_ANCHOR 0
        pv_tput_el
    fi
    return 0
}

_render_progress_spinner() {
    if (( EPOCHREALTIME - PV_SPINNER_LAST_UPDATE < PV_SPINNER_UPDATE_INTERVAL )); then
        return 0
    fi
    PV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
    pv_tput_cup $PV_TOP_ANCHOR 0
    printf "%s" "${PV_SPINNER_CHARS[PV_SPINNER_IDX]}"
    ((PV_SPINNER_IDX++ && PV_SPINNER_IDX > PV_SPINNER_LEN)) && PV_SPINNER_IDX=1
    return 0
}

_render_line() {
    local text=$1
    local width=$2

    pv_tput_rmam  # disable auto-wrapping of lines
    pv_start_buffered_update

    if ((PV_BORDER_SHOW)); then
        # This case is more complicated because we animate/grow the border frame downward
        # as the first PV_MAX_HEIGHT lines arrive, and only set the scroll region once
        # that height is hit.
        if ((PV_CUR_HEIGHT == 0)); then
            # First output line: draw top border.
            local -i ypos=$((PV_TOP_SCROLLREGION - 1))
            pv_tput_cup "$ypos" 0
            print "$PV_TOP_BORDER_STR"
        else
            # Advance to next line (previous output line doesn't include /n).
            # This will force a line scroll if PV_CUR_HEIGHT == PV_MAX_HEIGHT.
            local -i ypos=$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT - 1))
            pv_tput_cup "$ypos" 0
            print
        fi
        # Render the output line (which was wrapped for us using 'fold').
        local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
        if ((1)); then
            # Handling double-width characters is problematic since neither the built-in
            # string length primitives (printf with %-*s) nor the 'fold' command handle
            # them correctly. This results in the line truncation (or wrapping if using fold)
            # breaking at the wrong place, which also results in our right border line
            # rendering at the incorrect location (offset to the right or offscreen).
            #
            # The best we can do here is turn off auto-wrappping of lines and truncate
            # the line using printf %-*s primitive which might bleed over to the right
            # too many characters. Next we force the cursor to the correct location to
            # draw the right border char, then clear to end-of-line. This results in
            # at least the right border drawing at the correct location. Some characters
            # in the line might be truncated in this case (even if PV_WRAP_LINES is 1),
            # but is a pretty small rendering buglet probably not noticed.
            printf "%s${PROCESSING_TEXT_COLOR}│ ${LOG_TEXT_COLOR}%-*s " "$padleft_str" "$width" "$text"
            local -i ypos=$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT))
            ((PV_CUR_HEIGHT == PV_MAX_HEIGHT)) && ((ypos--))
            pv_tput_cup "$ypos" "$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_RIGHT - 1))"
            print -n "${PROCESSING_TEXT_COLOR}│${PV_RESET}";    pv_tput_el
        else
            # This simpler (and unused) technique works okay if there are no double-width
            # characters. If there are then the right border will be at the wrong location
            # and PV_BORDER_MARGIN_RIGHT won't be obeyed.
            printf "%s${PROCESSING_TEXT_COLOR}│ ${LOG_TEXT_COLOR}%-*s ${PROCESSING_TEXT_COLOR}│${PV_RESET}" "$padleft_str" "$width" "$text"
            pv_tput_el
        fi
        if ((PV_CUR_HEIGHT < PV_MAX_HEIGHT)); then
            # Re-render bottom border one line down (it was just erased by the
            # output line above). This creates the dynamic growing border view
            # animation.
            print -n "\n$PV_BOT_BORDER_STR";    pv_tput_el
            ((PV_CUR_HEIGHT++))
            if ((PV_CUR_HEIGHT == PV_MAX_HEIGHT)); then
                # The last output line above was on the last line of the scroll
                # region, so it is time to set the scroll region so all subsequent
                # output lines automatically scroll correctly. After this point
                # we no longer need to render the bottom border, as the scroll
                # region is now full and locked in (the bottom border is no longer
                # overwritten by the output since it is outside the scroll region).
                pv_tput_csr "$PV_TOP_SCROLLREGION" "$PV_BOT_SCROLLREGION"; PV_INSIDE_TPUTCSR=1
            fi
            pv_tput_cup "$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT - 1))" 0
        fi
    else
        # This case (no border) is much simpler since we can set the scroll region
        # on the very first output line, and then let it handle the scrolling from
        # that point forward.
        if ((PV_CUR_HEIGHT == 0)); then
            # First output line: set scroll region and move cursor to top
            local -i ypos=$PV_TOP_SCROLLREGION
            pv_tput_csr "$ypos" "$PV_BOT_SCROLLREGION"; PV_INSIDE_TPUTCSR=1
            pv_tput_cup "$ypos" 0
        else
            # Advance to next line (previous output line doesn't include /n).
            # This will force a line scroll if PV_CUR_HEIGHT == PV_MAX_HEIGHT.
            local -i ypos=$((PV_TOP_SCROLLREGION + PV_CUR_HEIGHT - 1))
            pv_tput_cup "$ypos" 0
            print
        fi
        if ((PV_CUR_HEIGHT < PV_MAX_HEIGHT)); then
            ((PV_CUR_HEIGHT++))
        fi
        local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
        printf "%s  ${LOG_TEXT_COLOR}%-*s${PV_RESET}  " "$padleft_str" "$width" "$text";    pv_tput_el
    fi

    pv_end_buffered_update
    pv_tput_smam  # re-enable auto-wrapping of lines
    return 0
}

_process_win_resize() {
    local out_width=$1    # after zsh 5.10+ use: local -n out_width=$1
    local out_height=$2   # after zsh 5.10+ use: local -n out_height=$2

    # must call yield before pv_get_term_width / pv_get_term_height
    _yield_to_parser
    local -i width=0 height=0
    pv_get_term_width width; pv_get_term_height height
    # after zsh 5.10+ use: out_width="$width" and out_height="$height"
    : ${(P)out_width::="$width"}
    : ${(P)out_height::="$height"}

    if ((width != PV_WIN_ORIG_WIDTH || height != PV_WIN_ORIG_HEIGHT)); then
        # Window resize detected. There isn't a graceful way to re-render everything
        # already shown, so we clear the screen, and have ther caller reprint the
        # label.
        PV_WIN_TOO_SMALL=$((width < PV_MIN_WIN_WIDTH || height < PV_MIN_WIN_HEIGHT))
        ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
        pv_tput_clear
        return 0
    fi
    return 1
}

_process_popview() {
    local label=$1
    if [[ -z $PV_PID || -z $PV_FD ]]; then
        return 0   # No pending async process, bail out.
    fi

    local -i select_timeout=$((100 * PV_SPINNER_UPDATE_INTERVAL))
    while true; do
        local -i fd_readable=0
        zselect -t $select_timeout -r $PV_FD && fd_readable=1
        local -i cur_width=0 unused_height=0
        if _process_win_resize cur_width unused_height; then
            if ((PV_WIN_TOO_SMALL)); then
                # Window shrank to be too small for useful rendering. Just
                # Re-render the processing label and bail out from trying.
                ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
                _render_label_processing "$label"
                return 0
            else
                # Window resized but is still large enough. Reset and restart
                # the scroll view and continue rendering loop.
                _start_popview $label
            fi
        fi
        if (( fd_readable )); then
            local lineout=""
            if ! read -r -u $PV_FD lineout; then
                break
            fi
            # Saving entire scrollview buffer (PV_OUTBUF) is currently disabled since
            # we don't reference it anywhere (and provide an optional $outfile argument
            # to save all output to a file). If we ever need it, then uncomment:
            #   PV_OUTBUF+="$lineout"$'\n'

            local -i width=$((cur_width - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 4))
            if (( PV_WRAP_LINES )); then
                while IFS= read -r text; do
                    local noesc_text=""
                    strip_control_chars "$text" noesc_text
                    _render_line "$noesc_text" "$width"
                done < <(printf '%s\n' "$lineout" | fold -s -w "$width")
            else
                # Hard truncate to width instead of wrapping.
                local noesc_text=""
                strip_control_chars "$lineout" noesc_text
                ((${#noesc_text} > width)) && noesc_text="${noesc_text[1,$width]}"
                _render_line "$noesc_text" "$width"
            fi
            _render_progress_spinner
        else
            _render_progress_spinner
        fi
    done
    # reset scroll region to full screen
    ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
    return 0
}

_show_usage() {
    local script_name=$1
    print -u2 "usage: $script_name [-l label] [-o outfile] [-p] [-q] cmd [args...]"
    return 0
}

typeset -g PV_INIT=0
pv_init() {
    (( PV_INIT )) && return
    PV_INIT=1

    zmodload -F zsh/terminfo    # for echoti() func
    zmodload zsh/datetime       # for $EPOCHREALTIME var
    zmodload zsh/zselect        # for zselect() func

    typeset -gi PV_ENABLE=1                    # 0 to disable dynamic scrolling popview on task execution
    typeset -gi PV_WRAP_LINES=1                # 0 to truncate lines instead of wrapping
    typeset -gi PV_BORDER_SHOW=1
    typeset -gi PV_BORDER_ANIMATE_CLOSE=1
    typeset -gi PV_MAX_HEIGHT=13
    typeset -gi PV_BORDER_MARGIN_LEFT=2        # 2 character margin on left border
    typeset -gi PV_BORDER_MARGIN_RIGHT=2       # 2 character margin on right border
    typeset -gi PV_LOG_TO_PADDING=50           # 50 character padding before rendering label "logged to: "

    typeset -gi PV_DEBUG_SKIP_CLOSE=0          # if enabled scroll view is not closed (even if successful)
    typeset -gi PV_PLAIN_LABEL=0               # 1 = use the label verbatim (no "..." suffix, no "success" word)
    typeset -gi PV_QUIET_CLOSE=0               # 1 = leave nothing behind when the view closes (no success line)
    typeset -gF PV_CLOSE_PAUSE_DELAY=1.75      # short pause before erasing and closing views
    typeset -gF PV_CLOSE_FRAME_DELAY=0.035     # delay between animation frames during view closing

    typeset -gi PV_MIN_WIN_WIDTH=$((PV_BORDER_MARGIN_LEFT + PV_BORDER_MARGIN_RIGHT + 12))
    typeset -gi PV_MIN_WIN_HEIGHT=$((PV_MAX_HEIGHT + 8))
    typeset -gi PV_WIN_TOO_SMALL=0

    typeset -g PV_PID=""    PV_FD=""     PV_OUTBUF=""
    typeset -g PV_TOP_BORDER_STR=""      PV_BOT_BORDER_STR=""
    typeset -gi PV_WIN_ORIG_WIDTH=0      PV_WIN_ORIG_HEIGHT=0
    typeset -gi PV_TOP_ANCHOR=0
    typeset -gi PV_TOP_SCROLLREGION=0    PV_BOT_SCROLLREGION=0
    typeset -gi PV_CUR_HEIGHT=0
    typeset -gi PV_INSIDE_TPUTCSR=0

    typeset -gF PV_SPINNER_UPDATE_INTERVAL=0.15
    typeset -gF PV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
    typeset -ga PV_SPINNER_CHARS=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )
                  # alternative: ( "⠁" "⠈" "⠐" "⠠" "⢀" "⡀" "⠄" "⠂" )
    typeset -gi PV_SPINNER_LEN=${#PV_SPINNER_CHARS[@]}
    typeset -gi PV_SPINNER_IDX=1

    typeset -g PV_BOLD='\033[1m'         PV_UNBOLD='\033[22m'
    typeset -g PV_RESET='\033[0m'
}

pv_exec() {
    emulate -L zsh
    pv_init

    local label outfile
    local -i plain=0 quiet=0
    while (( $# )); do
        case $1 in
        -l)  label=$2;        shift 2 ;;
        -o)  outfile=$2;      shift 2 ;;
        -l*) label=${1#-l};   shift   ;;
        -o*) outfile=${1#-o}; shift   ;;
        -p)  plain=1;         shift   ;;
        -q)  quiet=1;         shift   ;;
        --)                   shift; break ;;
        -*)  print -u2 "Error: unknown option '$1'"; _show_usage "${0:t}"; return 2 ;;
        *)                    break ;;   # first non-option => command+args starts
        esac
    done
    (( $# )) || { print -u2 "Error: missing cmd"; _show_usage "${0:t}"; return 2; }
    PV_PLAIN_LABEL=$plain
    PV_QUIET_CLOSE=$quiet

    if [[ -z "$label" ]]; then  # If no label specified use the cmd and escaped args as label
        label="${(j: :)${(q)@}}"
    fi
    if (( ! plain )); then
        # truncate label and add "..." to leave room for "logged to: " text added later.
        label_max_len=$((PV_LOG_TO_PADDING - 12))
        text_trunc "$label_max_len" "true" "$label" label
        [[ $label == *... ]] || label+="..."
    fi

    local -i width=0 height=0
    pv_get_term_width width; pv_get_term_height height
    if ((PV_ENABLE == 0 || width < PV_MIN_WIN_WIDTH || height < PV_MIN_WIN_HEIGHT)); then
        (( PV_QUIET_CLOSE )) || _render_label_processing "$label"
        if [[ -n "$outfile" ]]; then
            # Scrolling popview not enabled (or window to narrow); only capture output to file.
            _append_log_timestamp "$outfile" "$@"
            command -- "$@" 1>> "$outfile" 2>&1
        else
            # No output file specified; output is not captured and only process error code is checked.
            command -- "$@" &>/dev/null
        fi
        local rc=$?
        if (( ! PV_QUIET_CLOSE )); then
            if (( rc == 0 )); then
                _render_label_success "$label" "$outfile"
            else
                _render_label_failure "$label" "$outfile" "$rc"
            fi
        fi
        return rc
    fi
    PV_WIN_TOO_SMALL=0

    # Else scrolling popview is enabled, so we'll capture the output as it comes and
    # temporarily display it until process is finished.
    if [[ -n $PV_PID ]]; then
        # Cannot call coproc again, so don't allow recursion.
        ERR_STR="Error: pv_exec cannot be called recursively or asynchronously"
        printf "${MSG_FAILURE_TEXT_COLOR}${PV_BOLD}%s${PV_RESET}\n" "$ERR_STR"
        return 2
    fi

    PV_PID=""; PV_FD=""; PV_OUTBUF=""
    if [[ -n "$outfile" ]]; then
        _append_log_timestamp "$outfile" "$@"
        setopt localoptions nomonitor
        coproc {
            set -o pipefail
            command -- "$@" 2>&1 | tee -a "$outfile"
        }
    else
        setopt localoptions nomonitor
        coproc {
            command -- "$@" 2>&1
        }
    fi
    PV_PID=$!
    exec {PV_FD}<&p

    trap 'pv_tput_rcsr; pv_tput_cnorm; echo' EXIT
    trap 'pv_tput_rcsr; pv_tput_cnorm; echo; exit' INT TERM HUP QUIT
    pv_tput_civis

    PV_INSIDE_TPUTCSR=0
    _start_popview $label
    _process_popview $label

    # Clean up the fd, and wait (process is dead, so will be instant) to retrieve return code.
    local -i rc
    exec {PV_FD}<&-;    PV_FD=""
    wait $PV_PID;       rc=$?
    PV_PID="";  PV_OUTBUF=""
    if (( rc != 0 || PV_DEBUG_SKIP_CLOSE )); then
        # failure: leave scroll view visible since it hopefully has the failure details
        _end_popview_leave_open "$label" "$outfile" "$rc"
        pv_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
        return rc
    else
        # success: wipe the scroll view rows, show a single success line, cleanup
        _end_popview_with_close "$label" "$outfile"
        pv_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
    fi
    return 0
}

if program_exists "direnv"; then
    export DIRENV_LOG_FORMAT=""

    typeset -g _PV_DIRENV_LAST=""

    typeset -gi _PV_DIRENV_PKG_SHOWN=0
    typeset -gi _PV_DIRENV_PKG_TOP=0
    typeset -gi _PV_DIRENV_STALE=0   # 1 = rows were printed after the box, don't shift lines
    typeset -gi _PV_DIRENV_HDR=0     # 1 = a "direnv: <dir>" line sits right above the box

    # query the cursor position as 0-based row / col (like pv_get_cursor_row
    # but also returns the column)
    _pv_get_cursor_pos() {
        emulate -L zsh
        local out_row=$1 out_col=$2
        local fd
        exec {fd}<>/dev/tty || return 1
        local old=$(stty -g <&$fd)
        stty -echo -icanon min 1 time 1 <&$fd
        printf '\033[6n' >&$fd
        local resp
        IFS= read -r -d R -u $fd resp
        local read_ok=$?
        stty "$old" <&$fd
        exec {fd}>&-
        if (( read_ok == 0 )); then
            resp=${resp#*$'\033['}
            local row=${resp%%;*}
            local col=${resp##*;}
            if [[ $row == <-> && $col == <-> ]]; then
                : ${(P)out_row::=$((row - 1))}
                : ${(P)out_col::=$((col - 1))}
                return 0
            fi
        fi
        return 1
    }

    # delete the package box printed above the prompt (runs on next preexec,
    # i.e. as soon as the user actually executes a command). uses line
    # deletion so the space is actually reclaimed: everything below (summary
    # line, prompt, output) shifts up.
    _pv_direnv_pkg_clear() {
        emulate -L zsh
        (( _PV_DIRENV_PKG_SHOWN > 0 )) || return 0
        local -i r c
        if ! _pv_get_cursor_pos r c; then
            _PV_DIRENV_PKG_SHOWN=0
            _PV_DIRENV_HDR=0
            return 0
        fi
        # delete the box rows (plus the header row above it, if any), shifting
        # the lines below up
        local -i del=$(( _PV_DIRENV_PKG_SHOWN + _PV_DIRENV_HDR ))
        printf '\033[%d;%dH\033[%dM' $(( _PV_DIRENV_PKG_TOP + 1 - _PV_DIRENV_HDR )) 1 "$del"
        # put the cursor back where the typed command now lives
        printf '\033[%d;%dH' $(( r - del + 1 )) $(( c + 1 ))
        _PV_DIRENV_PKG_SHOWN=0
        _PV_DIRENV_HDR=0
        _PV_DIRENV_STALE=0
        return 0
    }

    # auto-retract the box after this many seconds while the prompt is idle
    typeset -gF _PV_DIRENV_RETRACT_DELAY=2
    # total rows your prompt occupies, including any leading blank line
    # (oh-my-posh 2-line prompts typically render 3 rows for zle)
    typeset -gi _PV_DIRENV_PROMPT_LINES=3

    # timer fires (SIGUSR1): retract the box. if zle is active the deletion
    # runs as a widget so the prompt redraws cleanly at its shifted position;
    # otherwise fall back to the CPR-based clear
    _pv_direnv_retract_widget() {
        emulate -L zsh
        (( _PV_DIRENV_PKG_SHOWN > 0 )) || return 0
        local -i n=$_PV_DIRENV_PKG_SHOWN i
        _PV_DIRENV_PKG_SHOWN=0
        # drop anything typed while the box was up so the line redraws empty
        BUFFER=""
        CURSOR=0
        if (( _PV_DIRENV_STALE )); then
            # rows appeared between the box and the prompt: only blank the box
            # (and header) out (cursor-safe), don't shift anything
            printf '\0337\033[%d;1H' $(( _PV_DIRENV_PKG_TOP + 1 - _PV_DIRENV_HDR ))
            for (( i = 0; i < n + _PV_DIRENV_HDR; i++ )); do
                printf '\033[K\033[1B'
            done
            printf '\0338'
            _PV_DIRENV_HDR=0
            zle -I
            zle reset-prompt
        else
            zle -I
            # animated collapse: delete the inner rows one by one until only
            # the empty box remains (borders adjacent), then both borders
            # disappear together in a single frame
            for (( i = 0; i < n - 2; i++ )); do
                printf '\033[%d;1H\033[M' $(( _PV_DIRENV_PKG_TOP + 2 ))
                pv_sleep $PV_CLOSE_FRAME_DELAY
            done
            if (( n >= 2 )); then
                pv_sleep $PV_CLOSE_FRAME_DELAY
                printf '\033[%d;1H\033[M\033[M' $(( _PV_DIRENV_PKG_TOP + 1 ))
            fi
            local -i hdr=$_PV_DIRENV_HDR
            if (( hdr )); then
                # the summary just slid up: remove the old "direnv: <dir>"
                # header so the summary replaces it
                pv_sleep $PV_CLOSE_FRAME_DELAY
                printf '\033[%d;1H\033[M' $(( _PV_DIRENV_PKG_TOP ))
            fi
            _PV_DIRENV_HDR=0
            # after the deletion the summary + blank line occupy the old box
            # space, so the prompt's first line sits 2 rows below the box top
            # (one less when the header row was removed too). park the cursor
            # on the prompt's LAST line (zle repaints upward from there)
            printf '\033[%d;1H' $(( _PV_DIRENV_PKG_TOP + 2 + _PV_DIRENV_PROMPT_LINES - hdr ))
            zle reset-prompt
            zle -R   # full refresh: wipes ghost/suggestion remnants left by
                     # keystrokes that landed during the animation
        fi
        _PV_DIRENV_STALE=0
        return 0
    }
    zle -N _pv_direnv_retract _pv_direnv_retract_widget

    TRAPUSR1() {
        emulate -L zsh
        (( _PV_DIRENV_PKG_SHOWN > 0 )) || return 0
        if [[ -o zle ]]; then
            zle _pv_direnv_retract
        else
            _pv_direnv_pkg_clear
        fi
        return 0
    }

    # the nix expression listing the devshell's declared packages
    _pv_direnv_nix_expr() {
        print -r -- 'let f = builtins.getFlake "path:'"$1"'"; s = (f.devShells.${builtins.currentSystem}.default or f.devShell.${builtins.currentSystem}); in map (p: p.name or "?") (s.nativeBuildInputs or [] ++ s.buildInputs or [])'
    }

    _pv_direnv_packages() {
        # $1 = project dir, $2/$3 = json output + rc file of a nix eval that
        # was already started in the background (empty = run it now)
        local out dir=$1 jsonf=${2:-} rcf=${3:-}
        if [[ -n "$jsonf" && -n "$rcf" ]]; then
            # wait for the background eval (usually already done)
            local -i guard=0
            while [[ ! -s "$rcf" && $guard -lt 300 ]]; do
                pv_sleep 0.05
                (( guard++ ))
            done
            [[ -s "$rcf" ]] && out=$(< "$jsonf")
        else
            out=$(command nix eval --json --impure --expr "$(_pv_direnv_nix_expr "$dir")" 2>/dev/null) || out=""
        fi
        [[ "$out" == \[*\] ]] || return 0

        local -a pkgs
        local stripped=${out:1:-1}   # strip the surrounding [ ]
        pkgs=(${(s:,:)stripped//\"/})
        pkgs=(${(u)pkgs})
        (( ${#pkgs} )) || return 0

        # drop the previous box if the user entered another project without
        # running a command in between
        _pv_direnv_pkg_clear

        # the export popview's label line ("direnv: <dir>") sits right above
        # the box and acts as the header: keep it, it gets replaced by the
        # summary when the box retracts
        _PV_DIRENV_HDR=1

        # draw a static bordered box above the prompt: the prompt stays usable,
        # the box vanishes on the next executed command. remember where the
        # box starts so preexec can delete exactly those rows.
        local -i top col
        _pv_get_cursor_pos top col || top=-1
        if (( top < 0 )); then
            # no tty to query: no reliable delete later, skip the box
            _PV_DIRENV_PKG_SHOWN=0
            return ${#pkgs}
        fi
        _PV_DIRENV_PKG_TOP=$top
        _PV_DIRENV_STALE=0

        # draw a static bordered box above the prompt: the prompt stays usable,
        # the box vanishes on the next executed command
        local -i w=0
        local p
        for p in "${pkgs[@]}"; do
            (( ${#p} > w )) && w=${#p}
        done
        local -i maxw=$(( ${COLUMNS:-80} - 8 ))
        (( w > maxw )) && w=$maxw
        local hbar=${(l:$((w + 2))::─:)}
        # match the direnv log view's left margin (PV_BORDER_MARGIN_LEFT)
        local -i ml=${PV_BORDER_MARGIN_LEFT:-2}
        local m=${(l:ml:: :)}

        # animated draw: the box starts as an empty bordered frame (both
        # borders appear together), then fills package by package, the
        # bottom border riding one row below the last printed line
        printf '\033[%d;1H%s'"${PROCESSING_TEXT_COLOR}"'╭%s╮\033[0m' $(( _PV_DIRENV_PKG_TOP + 1 )) "$m" "$hbar"
        printf '\033[%d;1H%s'"${PROCESSING_TEXT_COLOR}"'╰%s╯\033[0m' $(( _PV_DIRENV_PKG_TOP + 2 )) "$m" "$hbar"
        pv_sleep $PV_CLOSE_FRAME_DELAY
        local -i row=$(( _PV_DIRENV_PKG_TOP + 2 ))
        for p in "${pkgs[@]}"; do
            # package name in white, trailing version in yellow
            local _pn="${p%%-[0-9]*}" _pv=""
            if [[ "$_pn" != "$p" ]]; then
                _pv="${p#${_pn}-}"
            fi
            local -i _pad=$(( w - ${#p} ))
            local _padtail=""
            (( _pad > 0 )) && _padtail=${(l:_pad:: :)}
            printf '\033[%d;1H%s'"${PROCESSING_TEXT_COLOR}"'│ \033[97m%b\033[0m '"${PROCESSING_TEXT_COLOR}"'│\033[0m' "$row" "$m" "${_pn}\033[33m${_pv}${_padtail}"
            printf '\033[%d;1H%s'"${PROCESSING_TEXT_COLOR}"'╰%s╯\033[0m' $(( row + 1 )) "$m" "$hbar"
            (( row++ ))
            pv_sleep $PV_CLOSE_FRAME_DELAY
        done
        _PV_DIRENV_PKG_SHOWN=$(( ${#pkgs} + 2 ))
        # park the cursor on the row below the finished box (summary row)
        printf '\033[%d;1H' $(( row + 1 ))
        # auto-retract after the delay (stale timers no-op once SHOWN resets)
        { command sleep "${_PV_DIRENV_RETRACT_DELAY:-4}"; command kill -USR1 $$ } &!
        return ${#pkgs}
    }

    _pv_direnv_hook() {
        emulate -L zsh
        local now=${${DIRENV_DIR:-}#-}

        # a new prompt (or command output) appeared below the box: the
        # canonical layout is gone, so retraction must not shift lines
        (( _PV_DIRENV_PKG_SHOWN > 0 )) && _PV_DIRENV_STALE=1

        # find the nearest .envrc above cwd
        local target="" d=$PWD
        while [[ $d == /* && $d != / ]]; do
            if [[ -f $d/.envrc ]]; then
                target=$d
                break
            fi
            d=${d:h}
        done

        local out rc
        if [[ -n "$target" && "$target" != "$now" ]]; then
            # entering a new direnv project: run the export inside the pv_exec
            # popview so direnv's log scrolls by while it works (flake builds
            # can take a while), then collapses when done. stdout (the env
            # code) goes to a temp file, stderr (the log) feeds the view.
            local tmpf
            tmpf=$(mktemp "${TMPDIR:-/tmp}/direnv.XXXXXX.zsh") || return 0
            # kick off the package listing in parallel with the export so the
            # nix eval time is hidden behind the direnv popview
            local pkgtf rcf
            pkgtf=$(mktemp "${TMPDIR:-/tmp}/direnv-pkg.XXXXXX.json") || pkgtf=""
            if [[ -n "$pkgtf" ]]; then
                rcf="$pkgtf.rc"
                { command nix eval --json --impure --expr "$(_pv_direnv_nix_expr "$target")" >"$pkgtf" 2>/dev/null; print -r -- $? >"$rcf"; } &!
            fi
            # -p keeps the "direnv: mango" label on screen when the log view
            # collapses: the line never leaves the screen, the package box
            # draws right below it, and the summary replaces it on retract
            pv_exec -p -l $'\033[36mdirenv\033[0m: \033[97m'"${target:t}"$'\033[0m' /bin/dash -c 'exec direnv export zsh >"$1"' dash "$tmpf"
            rc=$?
            if (( rc == 0 )); then
                out=$(< "$tmpf")
                [[ -n "$out" ]] && eval "$out"
                _PV_DIRENV_LAST=${${DIRENV_DIR:-}#-}
                # after the package list collapses, one summary line remains
                local -i n=0
                _pv_direnv_packages "$_PV_DIRENV_LAST" "$pkgtf" "$rcf"
                n=$?
                if (( n > 0 )); then
                    printf "\033[36mdirenv\033[0m: \033[97m%s\033[0m, %d packages\n\n" "${_PV_DIRENV_LAST:t}" "$n"
                else
                    # no flake packages: the popview label line already says
                    # "direnv: <dir>", just add the spacer below it
                    printf "\n"
                fi
            else
                printf "${MSG_FAILURE_TEXT_COLOR}direnv\033[0m error (blocked? run: direnv allow)\n"
            fi
            command rm -f "$tmpf"
            [[ -n "$pkgtf" ]] && command rm -f "$pkgtf" "$rcf"
            return 0
        fi

        # same project or leaving: plain fast path
        out=$(command direnv export zsh 2>/dev/null)
        rc=$?
        if (( rc != 0 )); then
            printf "${MSG_FAILURE_TEXT_COLOR}direnv\033[0m error (blocked? run: direnv allow)\n"
            return 0
        fi
        [[ -n "$out" ]] && eval "$out"

        # DIRENV_DIR is "-/path/to/dir" when loaded, just "-" when unloaded
        local now2=${${DIRENV_DIR:-}#-}
        if [[ "$now2" != "$_PV_DIRENV_LAST" ]]; then
            # same color zsh-patina uses for valid commands (default theme)
            if [[ -n "$now2" ]]; then
                printf "\033[36mdirenv\033[0m entered \033[97m%s\033[0m\n" "${now2:t}"
            else
                printf "\033[36mdirenv\033[0m left \033[97m%s\033[0m\n" "${_PV_DIRENV_LAST:t}"
            fi
            _PV_DIRENV_LAST="$now2"
        fi
    }

    # swap direnv's own (chatty) hook for ours
    precmd_functions=(${precmd_functions:#_direnv_hook})
    chpwd_functions=(${chpwd_functions:#_direnv_hook})
    precmd_functions+=(_pv_direnv_hook)
    preexec_functions+=(_pv_direnv_pkg_clear)
fi
