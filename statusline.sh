#!/usr/bin/env bash
# Claude Code status line, in a single line:
#   <session name> [✦ <model>] · ☁ <profile> · ⎇ <branch> ⇡a ⇣b +ins/-rem ⚑n  #<pr> <ci>
#     · <agent map> · 🧠 <bar> <ctx%> <tokens> · ⏳ 5h <bar> ↻hh:mm · 📅 7d <bar> · ⏱ <duration>
# The PRs are the ones opened in this session and not merged yet; each one is a link.
# The session name comes from /rename, --name or the automatic title, and opens the line.
# The agent map is the tree of active sub-agents: one row inside the line (AGENT_MAP=inline,
# the default), a taller panel below it (on), or nothing at all (off).
# Receives the session JSON on stdin; everything here must be fast (the PR state comes from a cache).
# Responsive: reads the Claude Code terminal width and drops items, least to most important,
# until the line fits (STATUSLINE_COLS forces a width, useful for testing).
input=$(cat)

# Local settings (colors per profile). Never versioned:
#   PROFILE_COLORS="acme=orange other=ice"
CONFDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -r "$CONFDIR/statusline.conf" ] && . "$CONFDIR/statusline.conf"

fg()   { printf '\e[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
bg()   { printf '\e[48;2;%d;%d;%dm' "$1" "$2" "$3"; }
R=$'\e[0m'; B=$'\e[1m'
DIM=$(fg 108 112 134); SEPC=$(fg 88 91 112)
PINK=$(fg 245 194 231); MAUVE=$(fg 203 166 247); BLUE=$(fg 137 180 250); SKY=$(fg 137 220 235)
TEAL=$(fg 148 226 213); GREEN=$(fg 166 227 161); YELLOW=$(fg 249 226 175); PEACH=$(fg 250 179 135)
RED=$(fg 243 139 168); LAV=$(fg 180 190 254)
ORANGE=$(fg 255 128 0)   # orange
ICE=$(fg 173 216 255)    # very light blue
SEP=" ${SEPC}·${R} "

# Separator \x1f, not tab: tab is whitespace to read, which would merge consecutive empty
# fields (e.g. null used_percentage at session start) and shift all the following ones.
IFS=$'\x1f' read -r model dir ctx size ctx_pct dur_ms rl5_pct rl5_reset rl7_pct \
  transcript session_id session_name < <(jq -r '
  (.context_window.current_usage // {}) as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $cur
  | [ (.model.display_name // "?"),
      (.workspace.current_dir // .cwd // "."),
      (if $cur > 0 then $cur else (.context_window.total_input_tokens // 0) end),
      (.context_window.context_window_size // 0),
      (.context_window.used_percentage // ""),
      (.cost.total_duration_ms // 0),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.transcript_path // ""),
      (.session_id // ""),
      (.session_name // "") ] | map(tostring) | join("\u001f")' <<<"$input")

# percentages may come fractional from Claude Code; bash only does integer arithmetic
ctx_pct=${ctx_pct%.*}; rl5_pct=${rl5_pct%.*}; rl7_pct=${rl7_pct%.*}

fmt_k() { awk -v n="$1" 'BEGIN { if (n >= 1e6) printf "%.1fM", n/1e6; else if (n >= 1000) printf "%dk", n/1000; else printf "%d", n }'; }
link() { printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$2"; }   # OSC 8: clickable text

# bar <pct> [width] -> a solid track in surface gray with a green→yellow→red fill over it;
# the fill has an eighth of a cell of precision (▏▎▍▌▋▊▉█).
EIGHTH=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
bar() {
  local p=${1%.*} w=${2:-10} units full part i t r g b out=""
  [ -z "$p" ] && p=0
  [ "$p" -gt 100 ] && p=100; [ "$p" -lt 0 ] && p=0
  units=$(( (p * w * 8 + 50) / 100 ))              # fill, in eighths of a cell
  [ "$p" -gt 0 ] && [ "$units" -eq 0 ] && units=1  # anything above zero shows
  full=$(( units / 8 )); part=$(( units % 8 ))
  for ((i = 0; i < w; i++)); do
    if [ "$i" -lt "$full" ] || { [ "$i" -eq "$full" ] && [ "$part" -gt 0 ]; }; then
      t=$(( w > 1 ? i * 100 / (w - 1) : 0 ))
      if [ "$t" -lt 50 ]; then r=$(( 166 + (249 - 166) * t / 50 )); g=$(( 227 - (227 - 226) * t / 50 )); b=$(( 161 + (175 - 161) * t / 50 ))
      else r=$(( 249 - (249 - 243) * (t - 50) / 50 )); g=$(( 226 - (226 - 139) * (t - 50) / 50 )); b=$(( 175 - (175 - 168) * (t - 50) / 50 )); fi
      if [ "$i" -lt "$full" ]; then out+="$(fg $r $g $b)█"; else out+="$(fg $r $g $b)${EIGHTH[$part]}"; fi
    else
      out+="$(fg 49 53 72)█"
    fi
  done
  printf '%s%s' "$out" "$R"
}
pct_color() { if [ "$1" -ge 80 ]; then printf '%s' "$RED"; elif [ "$1" -ge 50 ]; then printf '%s' "$YELLOW"; else printf '%s' "$GREEN"; fi; }

# ===== terminal width =======================================================================
# The status line runs without a tty: walks up the parent processes until it finds the Claude Code terminal.
term_cols() {
  local p=$PPID t i
  for i in 1 2 3 4 5; do
    t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "??" ]; then
      stty -f "/dev/$t" size 2>/dev/null | awk '{ print $2 }'
      return
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] || [ "$p" -le 1 ] && return
  done
}
cols=${STATUSLINE_COLS:-$(term_cols)}
[ "${cols:-0}" -gt 0 ] || cols=${COLUMNS:-0}
[ "$cols" -gt 0 ] || cols=200   # no terminal found: cut nothing
max=$(( cols - 6 ))   # frame + padding Claude Code leaves at the edges

# visible width: no colors or links; emojis take 2 columns and combining marks none
# (the agent map's kitty placeholders are one cell plus one or two combining marks)
vis() {
  perl -CSD -0777 -ne 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g; s/\p{Mn}//g; $n = length($_);
    $n++ while /[\x{1F300}-\x{1FAFF}\x{23F3}\x{26A1}]/g; print $n' <<<"$1"
}

# ===== data ==================================================================================

# --- profile (gcloud) ------------------------------------------------------------------------
gprofile="${CLOUDSDK_ACTIVE_CONFIG_NAME:-$(cat "$HOME/.config/gcloud/active_config" 2>/dev/null)}"
# PROFILE_COLORS maps "prefix=color" (orange, ice, blue, green, mauve, pink, teal, peach…)
prof_c=$DIM
for pair in ${PROFILE_COLORS:-}; do
  case "$gprofile" in
    "${pair%%=*}"*) case "${pair#*=}" in
                     orange) prof_c=$ORANGE ;; ice) prof_c=$ICE ;; blue) prof_c=$BLUE ;;
                     green)  prof_c=$GREEN  ;; mauve) prof_c=$MAUVE ;; pink) prof_c=$PINK ;;
                     teal)   prof_c=$TEAL   ;; peach) prof_c=$PEACH ;; sky) prof_c=$SKY ;;
                     yellow) prof_c=$YELLOW ;; red) prof_c=$RED ;; *) prof_c=$DIM ;;
                   esac
                   break ;;
  esac
done

# --- git: branch, sync with remote, local changes, stash -------------------------------------
git_() { git -C "$dir" --no-optional-locks "$@" 2>/dev/null; }
branch=$(git_ branch --show-current)
[ -z "$branch" ] && branch=$(git_ rev-parse --short HEAD)
if [ -n "$branch" ]; then
  read -r behind ahead < <(git_ rev-list --left-right --count '@{upstream}...HEAD')
  read -r ins del < <(git_ diff HEAD --numstat | awk '{ a += $1; d += $2 } END { printf "%d %d", a, d }')
  stashes=$(git_ stash list | wc -l | tr -d ' ')
fi

# --- PRs opened in THIS session (and by its sub-agents) that are still open --------------------
# They come from the session history: each `gh pr create` and the URL it returned. Merged and
# closed ones leave the line. Another session in the same repo is not included.
# State and checks via gh, cached for 2 min and refreshed in the background.
pr_chips=()
subdir="${transcript%/*}/${session_id}/subagents"
if [ -n "$session_id" ] && [ -f "$transcript" ]; then
  prs_cache="${TMPDIR:-/tmp}/claude-statusline-prs-${session_id}"
  if [ ! -f "$prs_cache" ] || [ -n "$(find "$prs_cache" -mmin +2 2>/dev/null)" ]; then
    touch "$prs_cache"
    (
      files=("$transcript")
      [ -d "$subdir" ] && files+=("$subdir"/agent-*.jsonl)
      ids=$(cat "${files[@]}" 2>/dev/null | grep 'gh pr create' | jq -r 'select(.type == "assistant")
              | .message.content[]? | select(.type == "tool_use" and .name == "Bash")
              | select(.input.command | test("gh pr create")) | .id' 2>/dev/null)
      urls=$(for id in $ids; do
               cat "${files[@]}" 2>/dev/null | grep "\"tool_use_id\":\"$id\"" \
                 | grep -oE 'https://github\.com/[^/" ]+/[^/" ]+/pull/[0-9]+'
             done | awk '!seen[$0]++' | tail -n 15)
      for u in $urls; do
        gh pr view "$u" --json number,state,url,statusCheckRollup --jq '
          [.statusCheckRollup[]? | (.conclusion // .state // "")] as $all
          | [.number, .state,
             # green as soon as every check that reported has succeeded; a PR with no checks
             # at all stays neutral, and anything still running keeps it yellow
             (if any($all[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "fail"
              elif ($all | length) == 0 then "none"
              elif any($all[]; . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "") then "pending"
              else "ok" end),
             .url] | @tsv' 2>/dev/null
      done > "$prs_cache.tmp"
      mv -f "$prs_cache.tmp" "$prs_cache"
    ) >/dev/null 2>&1 &
  fi
  while IFS=$'\t' read -r n state ci url; do
    [ -n "$n" ] || continue
    case "$url" in https://*) ;; *) continue ;; esac    # line from an older cache format
    case "$state" in MERGED|CLOSED) continue ;; esac    # open PRs only
    [ "${#pr_chips[@]}" -ge 4 ] && break
    case "$ci" in
      ok)      c=$GREEN;  icon="✓" ;;
      fail)    c=$RED;    icon="✗" ;;
      pending) c=$YELLOW; icon="⏳" ;;
      *)       c=$DIM;    icon="○" ;;
    esac
    pr_chips+=("${c}${B}$(link "$url" "#${n}") ${icon}${R}")
  done < "$prs_cache" 2>/dev/null
fi

# --- model, context, limits, duration ---------------------------------------------------------
case "$model" in   # model badge: background by family, dark text
  *Opus*)   mc="250 179 135" ;;   # peach
  *Sonnet*) mc="137 180 250" ;;   # blue
  *Haiku*)  mc="166 227 161" ;;   # green
  *Fable*)  mc="203 166 247" ;;   # lilac
  *)        mc="180 190 254" ;;
esac
pct=""; [ "${size:-0}" -gt 0 ] && pct=${ctx_pct:-$(( ctx * 100 / size ))}
rl5_at=""; [ -n "$rl5_reset" ] && rl5_at=$(date -r "${rl5_reset%.*}" +%H:%M 2>/dev/null)
dur_s=$(( ${dur_ms%.*} / 1000 ))
if [ "$dur_s" -ge 3600 ]; then dur_txt="$((dur_s / 3600))h$(printf '%02d' $((dur_s % 3600 / 60)))m"
else dur_txt="$((dur_s / 60))m"; fi

# ===== the line ===============================================================================
# line <level>: the higher the level, the leaner
#   1 no stash · 2 no ctx tokens · 3 no 5h reset · 4 no +/- · 5 only 2 PRs · 6 shortened branch
#   7 no session name · 8 no PRs · 9 no profile · 10 no 7d · 11 no agent map / no duration
#   12 5h/7d without bars · 13 ctx without bar
line() {
  local l=$1 out="" br=$branch n i
  [ -n "$session_name" ] && [ "$l" -lt 7 ] && out+="${PINK}${B}${session_name}${R}${SEP}"
  # shellcheck disable=SC2086
  out+="$(fg $mc)▐$(bg $mc)$(fg 30 30 46)${B}✦ ${model}${R}$(fg $mc)▌${R}"
  [ "$l" -lt 9 ] && out+="${SEP}${prof_c}${B}☁ ${gprofile:-?}${R}"
  if [ -n "$branch" ]; then
    [ "$l" -ge 6 ] && [ "${#br}" -gt 18 ] && br="${br:0:17}…"
    out+="${SEP}${MAUVE}⎇ ${br}${R}"
    [ "${ahead:-0}" -gt 0 ] && out+=" ${SKY}⇡${ahead}${R}"     # commits to push
    [ "${behind:-0}" -gt 0 ] && out+=" ${PEACH}⇣${behind}${R}"  # commits to pull
    [ "$l" -lt 4 ] && out+=" ${GREEN}+${ins:-0}${R}${DIM}/${R}${RED}-${del:-0}${R}"
    [ "$l" -lt 1 ] && [ "${stashes:-0}" -gt 0 ] && out+=" ${YELLOW}⚑ ${stashes}${R}"
  fi
  if [ "$l" -lt 8 ] && [ "${#pr_chips[@]}" -gt 0 ]; then   # the session's open PRs, as links
    n=${#pr_chips[@]}; [ "$l" -ge 5 ] && [ "$n" -gt 2 ] && n=2
    out+="${SEP}"
    for ((i = 0; i < n; i++)); do [ "$i" -gt 0 ] && out+=" "; out+="${pr_chips[i]}"; done
    [ "$n" -lt "${#pr_chips[@]}" ] && out+=" ${DIM}+$(( ${#pr_chips[@]} - n ))${R}"
  fi
  [ "$l" -lt 11 ] && [ -n "$map_inline" ] && out+="${SEP}${map_inline}${R}"   # the agent map, in one row
  if [ -n "$pct" ]; then
    out+="${SEP}🧠 "; [ "$l" -lt 13 ] && out+="$(bar "$pct") "
    out+="$(pct_color "$pct")${B}${pct}%${R}"; [ "$l" -lt 2 ] && out+=" ${DIM}$(fmt_k "$ctx")${R}"
  else
    out+="${SEP}🧠 ${DIM}$(fmt_k "$ctx")${R}"
  fi
  if [ -n "$rl5_pct" ]; then
    out+="${SEP}⏳ ${LAV}5h${R} "; [ "$l" -lt 12 ] && out+="$(bar "$rl5_pct" 6) "
    out+="$(pct_color "$rl5_pct")${B}${rl5_pct}%${R}"
    [ "$l" -lt 3 ] && [ -n "$rl5_at" ] && out+=" ${DIM}↻${rl5_at}${R}"
  fi
  if [ "$l" -lt 10 ] && [ -n "$rl7_pct" ]; then
    out+="${SEP}📅 ${LAV}7d${R} "; [ "$l" -lt 12 ] && out+="$(bar "$rl7_pct" 6) "
    out+="$(pct_color "$rl7_pct")${B}${rl7_pct}%${R}"
  fi
  [ "$l" -lt 11 ] && out+="${SEP}⏱ ${LAV}${dur_txt}${R}"
  printf '%s' "$out"
}

# fit <function> <last level>: the first level that fits in $max (or the last)
fit() {
  local l out
  for ((l = 0; l <= $2; l++)); do
    out=$($1 "$l")
    [ "$(vis "$out")" -le "$max" ] && break
  done
  printf '%s' "$out"
}

# --- agent map: the active sub-agents, as an image in the terminal (text elsewhere) --------
# AGENT_MAP (statusline.conf): inline = one row inside the line · on = panel below · off = nothing.
# The hook runs without a controlling terminal, so it walks up the process tree until it finds
# Claude's tty: the image is transmitted through it (the TUI filters the sequence on stdout).
map_lines=(); map_inline=""
case "${AGENT_MAP:-inline}" in
  off | 0 | no | false) agent_map=off ;;
  inline | mini)        agent_map=inline ;;
  *)                    agent_map=panel ;;
esac
if [ "$agent_map" != off ] && [ -n "$session_id" ] && [ -d "$subdir" ]; then
  amtty=""; ampid=$PPID
  for _ in 1 2 3 4 5 6; do
    read -r ampid amt _ <<<"$(ps -o ppid=,tty=,comm= -p "$ampid" 2>/dev/null)"
    [ -z "$ampid" ] && break
    case "$amt" in tty*) amtty=$amt; break ;; esac
  done
  [ "$agent_map" = inline ] && inline_flag=--inline || inline_flag=
  while IFS= read -r ml; do
    [ -n "$ml" ] || continue
    if [ "$agent_map" = inline ]; then map_inline=$ml; else map_lines+=("$ml"); fi
  done < <(python3 "$CONFDIR/agent-map.py" "$subdir" "${amtty:--}" "$cols" "$session_id" \
             ${inline_flag:+"$inline_flag"} 2>/dev/null)
fi

status=$(fit line 13)

# Alone, the status is a bare line. With the agent panel, a frame holds the two together:
# the panel lines are printed raw — cutting them would break the cell↔image mapping.
if [ "${#map_lines[@]}" -eq 0 ]; then
  printf '%s' "$status"
else
  printf '%s' "${SEPC}╭─${R} $status"
  for a in "${map_lines[@]}"; do printf '\n%s' "$a"; done
  # closes the frame on its own line: separates it from the Claude Code line (auto mode…)
  printf '\n%s' "${SEPC}╰─${R}"
fi
