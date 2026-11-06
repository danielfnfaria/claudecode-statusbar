#!/bin/sh
# Instalador da status line do Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/danielfnfaria/claudecode-statusbar/main/install.sh | sh
#
# Desinstalar:  ... | sh -s -- --uninstall
# Variáveis:    CLAUDE_CONFIG_DIR (padrão ~/.claude), STATUSBAR_REF (branch/tag),
#               STATUSBAR_SRC (instala de um diretório local, em vez de baixar).
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
    *)           printf 'opção desconhecida: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31merro:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq não encontrado (brew install jq / apt install jq)"
[ -d "$DIR" ] || mkdir -p "$DIR"
[ -f "$SET" ] || printf '{}\n' > "$SET"

# ---------------------------------------------------------------- desinstalação
if [ "$ACTION" = uninstall ]; then
  say "Desinstalando de $DIR"
  cp "$SET" "$SET.bak-$STAMP" && ok "settings.json salvo em settings.json.bak-$STAMP"
  tmp="$(mktemp)"
  jq 'del(.statusLine)' "$SET" > "$tmp" && mv "$tmp" "$SET"
  ok "statusLine removido do settings.json"
  for f in $FILES; do
    [ -f "$DIR/$f" ] && mv "$DIR/$f" "$DIR/$f.removido-$STAMP" && ok "$f movido para $f.removido-$STAMP"
  done
  rm -rf "$DIR/cache/agent-map" && ok "cache do agent map apagado"
  say ""
  say "Pronto. O statusline.conf foi mantido, por ser seu."
  exit 0
fi

# ---------------------------------------------------------------- dependências
say "Status line do Claude Code -> $DIR"
say ""
say "Dependências:"
command -v bash >/dev/null 2>&1 || die "bash não encontrado"
ok "bash"
ok "jq"
if command -v python3 >/dev/null 2>&1; then
  ok "python3"
  if python3 -c 'import PIL' >/dev/null 2>&1; then
    ok "Pillow (agent map em imagem)"
  else
    warn "Pillow ausente: o agent map cai no desenho em texto"
    warn "para ativar a imagem: python3 -m pip install --user Pillow"
  fi
else
  warn "python3 ausente: o agent map fica desativado (o resto da status line funciona)"
fi
command -v git >/dev/null 2>&1 || warn "git ausente: a linha de branch/PR fica vazia"
command -v gh  >/dev/null 2>&1 || warn "gh ausente: o estado das PRs não aparece"

# ---------------------------------------------------------------- arquivos
say ""
say "Arquivos:"
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT INT TERM
for f in $FILES; do
  if [ -n "${STATUSBAR_SRC:-}" ]; then
    cp "$STATUSBAR_SRC/$f" "$tmpd/$f" || die "não achei $STATUSBAR_SRC/$f"
  else
    curl -fsSL "$RAW/$f" -o "$tmpd/$f" || die "falha ao baixar $f de $RAW"
  fi
  [ -s "$tmpd/$f" ] || die "$f veio vazio"
done
bash -n "$tmpd/statusline.sh" || die "statusline.sh não passou na checagem de sintaxe"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmpd/agent-map.py" \
    || die "agent-map.py não passou na checagem de sintaxe"
fi
for f in $FILES; do
  if [ -f "$DIR/$f" ] && ! cmp -s "$tmpd/$f" "$DIR/$f"; then
    cp "$DIR/$f" "$DIR/$f.bak-$STAMP"
    ok "$f: versão anterior salva em $f.bak-$STAMP"
  fi
  cp "$tmpd/$f" "$DIR/$f"
  chmod +x "$DIR/$f"
  ok "$f instalado"
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
' "$SET" > "$tmp" || die "não consegui editar o settings.json (JSON inválido?)"
mv "$tmp" "$SET"
depois="$(jq -r '.statusLine.command' "$SET")"
if [ "$antes" = "$depois" ] && [ -n "$antes" ]; then
  ok "comando mantido (já apontava para o statusline.sh)"
else
  ok "statusLine configurado"
fi
ok "cópia anterior em settings.json.bak-$STAMP"

# ---------------------------------------------------------------- fim
say ""
say "Pronto. Abra uma sessão nova do Claude Code para ver."
say ""
say "  Ajustes locais (cores por perfil, prefixo do contexto k8s):"
say "    $DIR/statusline.conf  — modelo em statusline.conf.example"
say "  Agent map:"
say "    aparece sozinho enquanto houver sub-agente ativo na sessão"
say "    AGENT_MAP_BG=rrggbb  AGENT_MAP_ROWS=4  AGENT_MAP_MAX_AGE=60"
say "  Desinstalar:"
say "    curl -fsSL $RAW/install.sh | sh -s -- --uninstall"
