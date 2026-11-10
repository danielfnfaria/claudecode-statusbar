#!/bin/sh
# Installer for the Claude Code status line.
#
#   curl -fsSL https://raw.githubusercontent.com/danielfnfaria/claudecode-statusbar/main/install.sh | sh
#
# Uninstall:    ... | sh -s -- --uninstall
# Variables:    CLAUDE_CONFIG_DIR (default ~/.claude), STATUSBAR_REF (branch/tag),
#               STATUSBAR_SRC (install from a local directory instead of downloading).
set -eu

REPO="${STATUSBAR_REPO:-danielfnfaria/claudecode-statusbar}"
REF="${STATUSBAR_REF:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"
DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SET="$DIR/settings.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILES="statusline.sh agent-map.py"
ACTION=install

for arg in ${@+"$@"}; do
  case "$arg" in
    --uninstall) ACTION=uninstall ;;
    --help|-h)   sed -n '2,10p' "$0" 2>/dev/null || true; exit 0 ;;
    *)           printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq / apt install jq)"
[ -d "$DIR" ] || mkdir -p "$DIR"
[ -f "$SET" ] || printf '{}\n' > "$SET"

# ---------------------------------------------------------------- uninstall
if [ "$ACTION" = uninstall ]; then
  say "Uninstalling from $DIR"
  cp "$SET" "$SET.bak-$STAMP" && ok "settings.json saved to settings.json.bak-$STAMP"
  tmp="$(mktemp)"
  jq 'del(.statusLine)' "$SET" > "$tmp" && mv "$tmp" "$SET"
  ok "statusLine removed from settings.json"
  for f in $FILES; do
    [ -f "$DIR/$f" ] && mv "$DIR/$f" "$DIR/$f.removed-$STAMP" && ok "$f moved to $f.removed-$STAMP"
  done
  rm -rf "$DIR/cache/agent-map" && ok "agent map cache deleted"
  say ""
  say "Done. statusline.conf was kept, since it is yours."
  exit 0
fi

# ---------------------------------------------------------------- dependencies
say "Claude Code status line -> $DIR"
say ""
say "Dependencies:"
command -v bash >/dev/null 2>&1 || die "bash not found"
ok "bash"
ok "jq"
if command -v python3 >/dev/null 2>&1; then
  ok "python3"
  if python3 -c 'import PIL' >/dev/null 2>&1; then
    ok "Pillow (image agent map)"
  else
    warn "Pillow missing: the agent map falls back to the text drawing"
    warn "to enable the image: python3 -m pip install --user Pillow"
  fi
else
  warn "python3 missing: the agent map is disabled (the rest of the status line works)"
fi
command -v git >/dev/null 2>&1 || warn "git missing: the branch/PR line stays empty"
command -v gh  >/dev/null 2>&1 || warn "gh missing: PR status is not shown"

# ---------------------------------------------------------------- files
say ""
say "Files:"
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT INT TERM
for f in $FILES; do
  if [ -n "${STATUSBAR_SRC:-}" ]; then
    cp "$STATUSBAR_SRC/$f" "$tmpd/$f" || die "could not find $STATUSBAR_SRC/$f"
  else
    curl -fsSL "$RAW/$f" -o "$tmpd/$f" || die "failed to download $f from $RAW"
  fi
  [ -s "$tmpd/$f" ] || die "$f came back empty"
done
bash -n "$tmpd/statusline.sh" || die "statusline.sh failed the syntax check"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmpd/agent-map.py" \
    || die "agent-map.py failed the syntax check"
fi
for f in $FILES; do
  if [ -f "$DIR/$f" ] && ! cmp -s "$tmpd/$f" "$DIR/$f"; then
    cp "$DIR/$f" "$DIR/$f.bak-$STAMP"
    ok "$f: previous version saved to $f.bak-$STAMP"
  fi
  cp "$tmpd/$f" "$DIR/$f"
  chmod +x "$DIR/$f"
  ok "$f installed"
done

# ---------------------------------------------------------------- settings.json
say ""
say "settings.json:"
cp "$SET" "$SET.bak-$STAMP"
CMD="$DIR/statusline.sh"
antes="$(jq -r '.statusLine.command // ""' "$SET")"
tmp="$(mktemp)"
jq --arg cmd "$CMD" '
    .statusLine = (.statusLine // {})
  | .statusLine.type = "command"
  | .statusLine.command = (if ((.statusLine.command // "") | test("statusline\\.sh"))
                           then .statusLine.command else $cmd end)
  | .statusLine.refreshInterval = (.statusLine.refreshInterval // 5)
' "$SET" > "$tmp" || die "could not edit settings.json (invalid JSON?)"
mv "$tmp" "$SET"
depois="$(jq -r '.statusLine.command' "$SET")"
if [ "$antes" = "$depois" ] && [ -n "$antes" ]; then
  ok "command kept (already pointed to statusline.sh)"
else
  ok "statusLine configured"
fi
ok "previous copy in settings.json.bak-$STAMP"

# ---------------------------------------------------------------- end
say ""
say "Done. Open a new Claude Code session to see it."
say ""
say "  Local settings, in $DIR/statusline.conf (the installer does not write it):"
say "    PROFILE_COLORS=\"acme=orange other=ice\"   color of the cloud profile, by prefix"
say "    AGENT_MAP=inline                        inline · on (panel below) · off"
say "  Agent map:"
say "    shows up on its own while a sub-agent is active in the session"
say "    AGENT_MAP_BG=rrggbb  AGENT_MAP_MAX_AGE=60  AGENT_MAP_ROWS=4 (panel only)"
say "  Uninstall:"
say "    curl -fsSL $RAW/install.sh | sh -s -- --uninstall"
