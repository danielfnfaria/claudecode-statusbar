#!/usr/bin/env bash
# Claude Code status line, in a two-line frame:
# With a session name (/rename, --name or the automatic title), it becomes the frame label:
#   ╭─ <session name> ──────
#   │  work … / ╰─ session …
#   ╭─ work:    ☁ <company> · @<agent> (active ones or main) ⟳n (in background) · ⎈ <cluster> · ⎇ <branch> ⇡a ⇣b +ins/-rem ⚑n · PR #n <ci> (link)
#   ╰─ session: [✦ <model>] ●●○○○ <effort> 🧠 ⚡ · Ctx <bar> · $ <bar> · 5h <bar> ↻hh:mm · 7d <bar>
#                · ❄ <cache> · ⏱ <duration>
# Below, when present: one line per PR created in this session (with CI).
# Receives the session JSON on stdin; everything here must be fast (the PR CI comes from a cache).
# Responsive: reads the Claude Code terminal width and drops items, least to most important,
# until each line fits (STATUSLINE_COLS forces a width, useful for testing).
input=$(cat)

# Local settings (colors per profile, k8s context prefix, budget). Never versioned:
#   PROFILE_COLORS="acme=orange other=ice"   KCTX_STRIP_PREFIX="acme-ctx-"
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
IFS=$'\x1f' read -r model dir ctx size ctx_pct tok_in tok_out cost dur_ms pr_num pr_url \
  effort thinking fast rl5_pct rl5_reset rl7_pct cache_hit cache_warm transcript session_id main_agent session_name < <(jq -r '
  (.context_window.current_usage // {}) as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $cur
  | [ (.model.display_name // "?"),
      (.workspace.current_dir // .cwd // "."),
      (if $cur > 0 then $cur else (.context_window.total_input_tokens // 0) end),
      (.context_window.context_window_size // 0),
      (.context_window.used_percentage // ""),
      (.context_window.total_input_tokens // 0),
      (.context_window.total_output_tokens // 0),
      (.cost.total_cost_usd // 0),
      (.cost.total_duration_ms // 0),
      (.pr.number // ""),
      (.pr.url // ""),
      (.effort.level // ""),
      (.thinking.enabled // false),
      (.fast_mode // false),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (if .prompt_cache.hit_ratio then (.prompt_cache.hit_ratio * 100 | floor) else "" end),
      (.prompt_cache.warm // false),
      (.transcript_path // ""),
      (.session_id // ""),
      (.agent.name // ""),
      (.session_name // "") ] | map(tostring) | join("\u001f")' <<<"$input")

# percentuais podem vir fracionários do Claude Code; o bash só faz aritmética inteira
ctx_pct=${ctx_pct%.*}; rl5_pct=${rl5_pct%.*}; rl7_pct=${rl7_pct%.*}; cache_hit=${cache_hit%.*}

fmt_k() { awk -v n="$1" 'BEGIN { if (n >= 1e6) printf "%.1fM", n/1e6; else if (n >= 1000) printf "%dk", n/1000; else printf "%d", n }'; }
link() { printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$2"; }   # OSC 8: clickable text

# bar <pct> [width] -> cells with a green→yellow→red gradient; empty ones in gray
bar() {
  local p=${1%.*} w=${2:-10} f i r g b t out=""
  [ -z "$p" ] && p=0
  [ "$p" -gt 100 ] && p=100; [ "$p" -lt 0 ] && p=0
  f=$(( (p * w + 50) / 100 )); [ "$p" -gt 0 ] && [ "$f" -eq 0 ] && f=1
  for ((i = 0; i < w; i++)); do
    if [ "$i" -lt "$f" ]; then
      t=$(( i * 100 / (w - 1) ))
      if [ "$t" -lt 50 ]; then r=$(( 166 + (249 - 166) * t / 50 )); g=$(( 227 - (227 - 226) * t / 50 )); b=$(( 161 + (175 - 161) * t / 50 ))
      else r=$(( 249 - (249 - 243) * (t - 50) / 50 )); g=$(( 226 - (226 - 139) * (t - 50) / 50 )); b=$(( 175 - (175 - 168) * (t - 50) / 50 )); fi
      out+="$(fg $r $g $b)▰"
    else
      out+="$(fg 69 71 90)▱"
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

# visible width: no colors or links; emojis take 2 columns
vis() {
  perl -CSD -0777 -ne 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g; $n = length($_);
    $n++ while /[\x{1F300}-\x{1FAFF}\x{23F3}\x{26A1}]/g; print $n' <<<"$1"
}

# ===== line 1 data: work ======================================================================

# --- company (gcloud profile) --------------------------------------------------------------
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

# --- cluster (kubectl; ⎈ = Kubernetes/Helm symbol, same as kube-ps1) -----------------------
kubeconfig="${KUBECONFIG%%:*}"; kubeconfig="${kubeconfig:-$HOME/.kube/config}"
kctx=$(awk '/^current-context:/ { print $2; exit }' "$kubeconfig" 2>/dev/null | tr -d '"')
kctx="${kctx##*_}"             # gke_<project>_<region>_<cluster> -> <cluster>
[ -n "${KCTX_STRIP_PREFIX:-}" ] && kctx="${kctx#$KCTX_STRIP_PREFIX}"

# --- git: branch, sync with remote, local changes, stash -------------------------------------
git_() { git -C "$dir" --no-optional-locks "$@" 2>/dev/null; }
branch=$(git_ branch --show-current)
[ -z "$branch" ] && branch=$(git_ rev-parse --short HEAD)
if [ -n "$branch" ]; then
  read -r behind ahead < <(git_ rev-list --left-right --count '@{upstream}...HEAD')
  read -r ins del < <(git_ diff HEAD --numstat | awk '{ a += $1; d += $2 } END { printf "%d %d", a, d }')
  stashes=$(git_ stash list | wc -l | tr -d ' ')

  # --- PR: number and link come from Claude Code; CI via gh, cached for 2 min in the background ---
  root=$(git_ rev-parse --show-toplevel)
  cache="${TMPDIR:-/tmp}/claude-statusline-pr-$(printf '%s' "$root:$branch" | shasum | cut -c1-16)"
  if [ ! -f "$cache" ] || [ -n "$(find "$cache" -mmin +2 2>/dev/null)" ]; then
    touch "$cache"
    # "ok" only when the PR is cleared to merge (mergeStateStatus): a required check that has not
    # reported yet (e.g. a delayed Cloud Build) does not show in the rollup, and using it alone would give ✓ too early
    ( cd "$root" && gh pr view "$branch" --json number,state,url,mergeStateStatus,statusCheckRollup --jq '
        [.statusCheckRollup[]? | (.conclusion // .state // "")] as $c
        | "\(.number) \(.state) \(
            if any($c[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "fail"
            elif (.mergeStateStatus == "CLEAN" or .mergeStateStatus == "HAS_HOOKS") then "ok"
            elif ($c | length) == 0 then "none"
            else "pending" end) \(.url)"' > "$cache.tmp" 2>/dev/null; mv -f "$cache.tmp" "$cache" ) >/dev/null 2>&1 &
  fi
  read -r c_num pr_state pr_ci c_url < "$cache" 2>/dev/null
  pr_num="${pr_num:-$c_num}"; pr_url="${pr_url:-$c_url}"
  if [ -n "$pr_num" ]; then
    [ "$c_num" = "$pr_num" ] || { pr_state=""; pr_ci=""; }   # cache from another branch/PR
    case "$pr_state" in
      MERGED) pr_c=$MAUVE; pr_txt="PR #${pr_num} merged" ;;
      CLOSED) pr_c=$DIM;   pr_txt="PR #${pr_num} closed" ;;
      *) case "$pr_ci" in
           ok)      pr_c=$GREEN;  pr_txt="PR #${pr_num} ✓" ;;
           fail)    pr_c=$RED;    pr_txt="PR #${pr_num} ✗" ;;
           pending) pr_c=$YELLOW; pr_txt="PR #${pr_num} ⏳" ;;
           *)       pr_c=$BLUE;   pr_txt="PR #${pr_num}" ;;
         esac ;;
    esac
  fi
fi

# --- working agents: this session's sub-agents with a transcript written in the last minute -----
# (<project>/<session>/subagents/agent-<id>.jsonl + .meta.json with the agentType)
agents_txt=""; bg=0; agent_lines=()
subdir="${transcript%/*}/${session_id}/subagents"
if [ -n "$session_id" ] && [ -d "$subdir" ]; then
  # each active one becomes "<type> <shape>"; shape = background when it was launched in the background
  active=$(find "$subdir" -name 'agent-*.jsonl' -mtime -60s 2>/dev/null | while read -r f; do
             jq -r '"\(.agentType // "") \(.requestShape // "")"' "${f%.jsonl}.meta.json" 2>/dev/null
           done)
  while read -r n type; do
    [ -z "$type" ] && continue
    agents_txt+="${agents_txt:+ }${GREEN}@${type}${R}"
    [ "$n" -gt 1 ] && agents_txt+="${DIM}×${n}${R}"
  done < <(awk 'NF { print $1 }' <<<"$active" | sort | uniq -c)
  bg=$(awk '$2 == "background"' <<<"$active" | grep -c .)

  # one line per active sub-agent (up to 3, most recent first): pace, current action, steps, time
  agent_lines=()
  while read -r f; do
    [ -n "$f" ] || continue
    type=$(jq -r '.agentType // "agent"' "${f%.jsonl}.meta.json" 2>/dev/null)
    # all the agent's tool_use: "<tool>\t<target>" (target = file, pattern, URL or description, depending on the tool)
    calls=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
             | .name as $n | .input as $i
             | [$n, ((if   ($n | test("^(Read|Edit|Write|NotebookEdit)$")) then $i.file_path
                      elif ($n | test("^(Grep|Glob)$"))                    then $i.pattern
                      elif ($n | test("^Web"))                             then ($i.query // $i.url)
                      else ($i.description // $i.command // $i.prompt) end) // ""
                 | tostring | split("\n")[0])] | @tsv' "$f" 2>/dev/null)
    steps=$(grep -c . <<<"$calls")
    # pace: the last 8 steps, one ▰ per step colored by type (read blue, search lilac, edit green, command yellow)
    spark=""
    while IFS=$'\t' read -r tool _; do
      case "$tool" in
        Read|Glob)                       spark+="${SKY}▰" ;;
        Grep|WebSearch|WebFetch)         spark+="${LAV}▰" ;;
        Edit|Write|NotebookEdit)         spark+="${GREEN}▰" ;;
        Bash)                            spark+="${YELLOW}▰" ;;
        *)                               spark+="${DIM}▰" ;;
      esac
    done < <(tail -n 8 <<<"$calls")
    # current action: emoji + verb + short target (files by name only); single
    # code point emojis (no variation selector) so the width is predictable
    IFS=$'\t' read -r tool target < <(tail -n 1 <<<"$calls")
    case "$tool" in
      Read)                    act="📖 reading ${target##*/}" ;;
      Edit|Write|NotebookEdit) act="📝 editing ${target##*/}" ;;
      Bash)                    act="💻 ${target}" ;;
      Grep|Glob)               act="🔍 searching \"${target}\"" ;;
      WebSearch|WebFetch)      act="🌐 web ${target}" ;;
      Agent|Task)              act="🤝 delegating ${target}" ;;
      SubagentHandback)        act="✅ delivering report" ;;
      "")                      act="💭 thinking" ;;
      *)                       act="🔧 ${tool} ${target}" ;;
    esac
    [ "${#act}" -gt 60 ] && act="${act:0:59}…"
    age=$(( $(date +%s) - $(stat -f %B "$f" 2>/dev/null || date +%s) ))
    if [ "$age" -ge 3600 ]; then age_txt="$((age / 3600))h$(printf '%02d' $((age % 3600 / 60)))m"
    elif [ "$age" -ge 60 ]; then age_txt="$((age / 60))m$(printf '%02d' $((age % 60)))s"
    else age_txt="${age}s"; fi
    agent_lines+=("${GREEN}${B}@${type}${R} ${spark}${R} ${act}${SEP}${DIM}step ${steps}${R}${SEP}${DIM}${age_txt}${R}")
  done < <(find "$subdir" -name 'agent-*.jsonl' -mtime -60s -print0 2>/dev/null \
             | xargs -0 ls -t 2>/dev/null | head -3)
fi
[ -n "$agents_txt" ] || agents_txt="${GREEN}@${main_agent:-main}${R}"
[ "${bg:-0}" -gt 0 ] && agents_txt+=" ${YELLOW}⟳${bg}${R}"   # how many run in the background

# line1 <level>: the higher the level, the leaner
#   1 no stash · 2 no +/- · 3 "⚠" without "PROD" · 4 shortened branch · 5 no company · 6 no cluster
line1() {
  local l=$1 out="" br=$branch
  if [ "$l" -lt 5 ]; then
    out+="${SEP}${prof_c}${B}☁ ${gprofile:-?}${R}${SEP}${agents_txt}"
  fi
  if [ "$l" -lt 6 ]; then
    if [ -z "$kctx" ]; then out+="${SEP}${DIM}⎈ no context${R}"
    elif [[ $kctx == *prod* ]]; then
      if [ "$l" -lt 3 ]; then out+="${SEP}${RED}${B}⎈ ${kctx} ⚠ PROD${R}"; else out+="${SEP}${RED}${B}⎈ ${kctx} ⚠${R}"; fi
    else out+="${SEP}${TEAL}⎈ ${kctx}${R}"; fi
  fi
  if [ -n "$branch" ]; then
    [ "$l" -ge 4 ] && [ "${#br}" -gt 18 ] && br="${br:0:17}…"
    out+="${SEP}${MAUVE}⎇ ${br}${R}"
    [ "${ahead:-0}" -gt 0 ] && out+=" ${SKY}⇡${ahead}${R}"     # commits to push
    [ "${behind:-0}" -gt 0 ] && out+=" ${PEACH}⇣${behind}${R}"  # commits to pull
    [ "$l" -lt 2 ] && out+=" ${GREEN}+${ins:-0}${R}${DIM}/${R}${RED}-${del:-0}${R}"
    [ "$l" -lt 1 ] && [ "${stashes:-0}" -gt 0 ] && out+=" ${YELLOW}⚑ ${stashes}${R}"
    if [ -n "$pr_num" ]; then
      if [ -n "$pr_url" ]; then out+="${SEP}${pr_c}$(link "$pr_url" "$pr_txt")${R}"
      else out+="${SEP}${pr_c}${pr_txt}${R}"; fi
    fi
  fi
  printf '%s' "${out#"$SEP"}"
}

# ===== line 2 data: session ===================================================================

case "$model" in   # model badge: background by family, dark text
  *Opus*)   mc="250 179 135" ;;   # peach
  *Sonnet*) mc="137 180 250" ;;   # blue
  *Haiku*)  mc="166 227 161" ;;   # green
  *Fable*)  mc="203 166 247" ;;   # lilac
  *)        mc="180 190 254" ;;
esac
case "$effort" in
  low) en=1 ;; medium) en=2; effort=med ;; high) en=3 ;; xhigh) en=4 ;; max) en=5 ;; *) en=0 ;;
esac
dots=""; for ((i = 1; i <= 5; i++)); do [ "$i" -le "$en" ] && dots+="●" || dots+="○"; done
pct=""; [ "${size:-0}" -gt 0 ] && pct=${ctx_pct:-$(( ctx * 100 / size ))}
budget="${STATUSLINE_BUDGET_USD:-10}"
cost_pct=$(awk -v c="$cost" -v b="$budget" 'BEGIN { printf "%d", (b > 0 ? c * 100 / b : 0) }')
rl5_at=""; [ -n "$rl5_reset" ] && rl5_at=$(date -r "${rl5_reset%.*}" +%H:%M 2>/dev/null)
dur_s=$(( ${dur_ms%.*} / 1000 ))
if [ "$dur_s" -ge 3600 ]; then dur_txt="$((dur_s / 3600))h$(printf '%02d' $((dur_s % 3600 / 60)))m"
else dur_txt="$((dur_s / 60))m"; fi

# line2 <level>: the higher the level, the leaner
#   1 no cache · 2 no 7d · 3 no ctx tokens · 4 no 5h reset · 5 no effort label
#   6 $ without bar · 7 ctx without bar · 8 5h without bar · 9 no effort/🧠/⚡ · 10 no duration
line2() {
  local l=$1 out
  # shellcheck disable=SC2086
  out="$(fg $mc)▐$(bg $mc)$(fg 30 30 46)${B}✦ ${model}${R}$(fg $mc)▌${R}"
  if [ "$l" -lt 9 ]; then
    if [ "$en" -gt 0 ]; then
      out+=" ${PEACH}${dots}${R}"; [ "$l" -lt 5 ] && out+=" ${DIM}${effort}${R}"
    fi
    [ "$thinking" = "true" ] && out+=" 🧠"
    [ "$fast" = "true" ] && out+=" ⚡"
  fi
  if [ -n "$pct" ]; then
    out+="${SEP}${LAV}Ctx${R} "; [ "$l" -lt 7 ] && out+="$(bar "$pct") "
    out+="$(pct_color "$pct")${B}${pct}%${R}"; [ "$l" -lt 3 ] && out+=" ${DIM}$(fmt_k "$ctx")${R}"
  else
    out+="${SEP}${LAV}Ctx${R} ${DIM}$(fmt_k "$ctx")${R}"
  fi
  out+="${SEP}${YELLOW}\$${R} "; [ "$l" -lt 6 ] && out+="$(bar "$cost_pct") "
  out+="$(pct_color "$cost_pct")${B}$(printf '$%.2f' "$cost")${R}"
  if [ -n "$rl5_pct" ]; then
    out+="${SEP}${LAV}5h${R} "; [ "$l" -lt 8 ] && out+="$(bar "$rl5_pct" 6) "
    out+="$(pct_color "$rl5_pct")${B}${rl5_pct}%${R}"
    [ "$l" -lt 4 ] && [ -n "$rl5_at" ] && out+=" ${DIM}↻${rl5_at}${R}"
  fi
  if [ "$l" -lt 2 ] && [ -n "$rl7_pct" ]; then
    out+="${SEP}${LAV}7d${R} $(bar "$rl7_pct" 6) $(pct_color "$rl7_pct")${B}${rl7_pct}%${R}"
  fi
  if [ "$l" -lt 1 ] && [ -n "$cache_hit" ]; then   # prompt cache: warm = blue, cold = gray
    if [ "$cache_warm" = "true" ]; then out+="${SEP}${SKY}❄ ${cache_hit}%${R}"
    else out+="${SEP}${DIM}❄ ${cache_hit}% cold${R}"; fi
  fi
  [ "$l" -lt 10 ] && out+="${SEP}${LAV}⏱ ${dur_txt}${R}"
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

# --- PRs created in THIS session (and by its sub-agents), with state and checks ------------------
# They come from the session history: each `gh pr create` and the URL it returned. They stay until
# merged (closed without merge stay, marked as closed). Another session in the same
# repo is not included. State/checks via gh, cached for 2 min and refreshed in the background.
pr_lines=()
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
        # required checks from the base branch rules: the ones that have not reported yet ("Expected")
        # do not show in the PR rollup, so they count as pending
        repo=$(sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#' <<<"$u")
        pr=$(gh pr view "$u" --json number,title,url,state,isDraft,baseRefName,mergeStateStatus,statusCheckRollup 2>/dev/null) || continue
        base=$(jq -r .baseRefName <<<"$pr")
        required=$(gh api "repos/$repo/rules/branches/$base" --jq '[.[] | select(.type == "required_status_checks")
                     | .parameters.required_status_checks[].context]' 2>/dev/null || echo '[]')
        jq -r --argjson req "${required:-[]}" '
          [.statusCheckRollup[]? | {name: (.name // .context), r: (.conclusion // .state // "")}] as $c
          | ($req - [$c[].name]) as $missing
          | ([$c[].r] + [$missing[] | "EXPECTED"]) as $all
          | [.number, .state, .isDraft, ($all | length),
             ([$all[] | select(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")] | length),
             # green = all reported checks succeeded (and the required ones, if any, present);
             # does not depend on "cleared to merge": main may not require checks
             (if any($all[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "fail"
              elif ($all | length) == 0 then "none"
              elif any($all[]; . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "") then "pending"
              else "ok" end),
             .url, .title] | @tsv' <<<"$pr"
      done > "$prs_cache.tmp"
      mv -f "$prs_cache.tmp" "$prs_cache"
    ) >/dev/null 2>&1 &
  fi
  while IFS=$'\t' read -r n state draft total passed ci url title; do
    [ -n "$n" ] || continue
    case "$state" in MERGED|CLOSED) continue ;; esac   # open PRs only: merged and closed ones disappear from the bar
    [ "${#pr_lines[@]}" -ge 6 ] && break
    case "$state:$ci" in
      MERGED:*)  c=$MAUVE;  icon="⇄" ;;
      CLOSED:*)  c=$DIM;    icon="⊘" ;;
      *:ok)      c=$GREEN;  icon="✓" ;;
      *:fail)    c=$RED;    icon="✗" ;;
      *:pending) c=$YELLOW; icon="⏳" ;;
      *)         c=$DIM;    icon="○" ;;
    esac
    [ "${#title}" -gt 70 ] && title="${title:0:69}…"
    line="${c}${B}${icon} $(link "$url" "#${n}")${R} ${title}"
    case "$state" in
      MERGED) line+="${SEP}${MAUVE}merged${R}" ;;
      CLOSED) line+="${SEP}${DIM}closed${R}" ;;
      *) [ "$total" -gt 0 ] && line+="${SEP}${c}checks ${passed}/${total}${R}"
         [ "$draft" = "true" ] && line+="${SEP}${DIM}draft${R}" ;;
    esac
    pr_lines+=("$line")
  done < "$prs_cache" 2>/dev/null
fi

# frame: without PRs, two lines; with PRs, a "│" separates, one line per PR and a "╰─" closes
fit_line() { local a=$1; while [ "$(vis "$a")" -gt "$max" ] && [ "${#a}" -gt 20 ]; do a="${a%?}"; done; printf '%s' "$a"; }
l1=$(fit line1 6); l2=$(fit line2 10)
# --- agent map: panel of active sub-agents (image in the terminal, text elsewhere) --------
# The hook runs without a controlling terminal, so it walks up the process tree until it finds
# Claude's tty: the image is transmitted through it (the TUI filters the sequence on stdout).
map_lines=()
if [ -n "$session_id" ] && [ -d "$subdir" ]; then
  amtty=""; ampid=$PPID
  for _ in 1 2 3 4 5 6; do
    read -r ampid amt _ <<<"$(ps -o ppid=,tty=,comm= -p "$ampid" 2>/dev/null)"
    [ -z "$ampid" ] && break
    case "$amt" in tty*) amtty=$amt; break ;; esac
  done
  while IFS= read -r ml; do
    [ -n "$ml" ] && map_lines+=("$ml")
  done < <(python3 "$CONFDIR/agent-map.py" "$subdir" "${amtty:--}" "$cols" "$session_id" 2>/dev/null)
fi

first="${SEPC}╭─${R} $l1"
if [ -n "$session_name" ]; then
  # session name as the frame label: "╭─ name ───", with the rule up to the content width
  title=$session_name
  [ "${#title}" -gt $(( max - 8 )) ] && title="${title:0:$(( max - 9 ))}…"
  w1=$(vis "$l1"); w2=$(vis "$l2"); w=$(( w1 > w2 ? w1 : w2 ))
  fill=$(( w - ${#title} - 1 )); [ "$fill" -lt 3 ] && fill=3
  rule=$(printf '%*s' "$fill" '' | sed 's/ /─/g')
  printf '%s\n' "${SEPC}╭─${R} ${PINK}${B}${title}${R} ${SEPC}${rule}${R}"
  first="${SEPC}│${R}  $l1"
fi
if [ "${#pr_lines[@]}" -eq 0 ] && [ "${#map_lines[@]}" -eq 0 ]; then
  printf '%s\n%s' "$first" "${SEPC}╰─${R} $l2"
else
  printf '%s\n%s' "$first" "${SEPC}├─${R} $l2"
  # the session PRs (active agents already show on line 1: @executor×2 ⟳2)
  if [ "${#pr_lines[@]}" -gt 0 ]; then
    printf '\n%s' "${SEPC}│${R}"
    for a in "${pr_lines[@]}"; do printf '\n%s %s' "${SEPC}├─${R}" "$(fit_line "$a")${R}"; done
  fi
  # the agents panel: ready-made lines (image placeholders or the text drawing),
  # printed raw — cutting them would break the cell↔image mapping
  for a in "${map_lines[@]}"; do printf '\n%s' "$a"; done
  # closes the frame on its own line: separates it from the Claude Code line (auto mode…)
  printf '\n%s' "${SEPC}╰─${R}"
fi
