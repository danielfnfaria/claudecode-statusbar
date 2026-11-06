#!/usr/bin/env python3
"""Agent map da status line: lista dos sub-agentes ATIVOS + fluxograma, como imagem.

Uso:  agent-map.py <dir dos subagents> <tty|-> <colunas do terminal> <session_id>

A imagem vai direto para o tty (o TUI do Claude filtra a sequência no stdout);
no stdout saem só os placeholders Unicode do protocolo kitty, que são texto comum.
Sem terminal compatível, cai para um desenho em texto. Sem agente ativo, não imprime nada.
"""
import hashlib
import json
import os
import sys
import time

MAX_AGE = int(os.environ.get("AGENT_MAP_MAX_AGE", "60"))   # seg. desde a última escrita
ROWS = int(os.environ.get("AGENT_MAP_ROWS", "4"))
PER_COL = 5          # caixas por coluna antes de abrir outra
CELL_W, CELL_H, DPR = 10, 20, 2
CACHE = os.path.expanduser("~/.claude/cache/agent-map")
_H = os.path.expanduser("~")
FONTS = [os.environ["AGENT_MAP_FONT"]] if os.environ.get("AGENT_MAP_FONT") else []
FONTS += [f"{_H}/Library/Fonts/FiraCodeNerdFontMono-{{}}.ttf",
          f"{_H}/Library/Fonts/FiraCode-{{}}.ttf",
          "/usr/share/fonts/truetype/firacode/FiraCode-{}.ttf",
          "/System/Library/Fonts/Menlo.ttc",
          "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]

BASE, SURF0, SURF1, OVER0 = (36, 39, 58), (49, 53, 72), (78, 82, 106), (110, 115, 141)
TEXT, SUB0, PANEL = (202, 211, 245), (165, 173, 203), (30, 32, 48)
GREEN, MAUVE, YELLOW = (166, 218, 149), (198, 160, 246), (238, 212, 159)
DIAC = [0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
        0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357]
PH = chr(0x10EEEE)

ACOES = {"Read": "lendo", "Edit": "editando", "Write": "escrevendo", "NotebookEdit": "editando",
         "Bash": "rodando", "Grep": "buscando", "Glob": "buscando", "WebSearch": "pesquisando",
         "WebFetch": "lendo a web", "Agent": "delegando", "Task": "delegando",
         "SubagentHandback": "entregando o relatório"}


def term_bg():
    """Cor de fundo do terminal: env > config do Ghostty > arquivo do tema > padrão."""
    def parse(v):
        v = v.strip().lstrip("#")
        if len(v) == 6:
            try:
                return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))
            except ValueError:
                return None
        return None

    env = os.environ.get("AGENT_MAP_BG")
    if env and parse(env):
        return parse(env)
    cfg = os.path.expanduser("~/.config/ghostty/config")
    tema = None
    try:
        with open(cfg, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln.startswith("background") and "=" in ln:
                    c = parse(ln.split("=", 1)[1])
                    if c:
                        return c
                if ln.startswith("theme") and "=" in ln:
                    tema = ln.split("=", 1)[1].strip()
    except OSError:
        pass
    if tema:
        f = f"/Applications/Ghostty.app/Contents/Resources/ghostty/themes/{tema}"
        try:
            with open(f, encoding="utf-8") as fh:
                for ln in fh:
                    if ln.strip().startswith("background") and "=" in ln:
                        c = parse(ln.split("=", 1)[1])
                        if c:
                            return c
        except OSError:
            pass
    return (36, 39, 58)


def fmt_age(sec):
    sec = int(sec)
    if sec >= 3600:
        return f"{sec // 3600}h{sec % 3600 // 60:02d}m"
    if sec >= 60:
        return f"{sec // 60}m{sec % 60:02d}s"
    return f"{sec}s"


def fmt_tok(n):
    if n >= 1_000_000:
        return f"{n / 1e6:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)


def last_json_objs(data, want, limit=400):
    """Varre as últimas linhas do .jsonl de trás para frente, devolvendo as que casam."""
    out = []
    for line in reversed(data.splitlines()[-limit:]):
        if not line.startswith(b"{"):
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if want(o):
            out.append(o)
            if len(out) >= 2:
                break
    return out


def read_agents(subdir):
    now = time.time()
    agents = []
    try:
        names = [n for n in os.listdir(subdir) if n.startswith("agent-") and n.endswith(".jsonl")]
    except OSError:
        return []
    for name in names:
        path = os.path.join(subdir, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        if now - st.st_mtime > MAX_AGE:
            continue
        meta = {}
        try:
            with open(path[:-6] + ".meta.json", encoding="utf-8") as fh:
                meta = json.load(fh)
        except Exception:
            pass
        if meta.get("finished") or meta.get("stoppedByUser"):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        steps = data.count(b'"type":"tool_use"')
        tokens, tool, target = 0, "", ""
        for o in last_json_objs(data, lambda o: bool(o.get("message", {}).get("usage"))):
            u = o["message"]["usage"]
            tokens = (u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                      + u.get("cache_read_input_tokens", 0))
            break
        for o in last_json_objs(data, lambda o: o.get("type") == "assistant"):
            for c in o.get("message", {}).get("content", []) or []:
                if c.get("type") == "tool_use":
                    i = c.get("input", {}) or {}
                    tool = c.get("name", "")
                    target = (i.get("file_path") or i.get("pattern") or i.get("query")
                              or i.get("description") or i.get("command") or "")
                    target = str(target).splitlines()[0] if target else ""
            if tool:
                break
        start = st.st_mtime
        try:
            first = data[:data.index(b"\n")]
            ts = json.loads(first).get("timestamp", "")
            start = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
        except Exception:
            try:
                start = st.st_birthtime
            except AttributeError:
                pass
        verbo = ACOES.get(tool, tool.lower() if tool else "pensando")
        alvo = os.path.basename(target) if tool in ("Read", "Edit", "Write", "NotebookEdit") else target
        agents.append({
            "type": meta.get("agentType") or "agente",
            "desc": meta.get("description") or "",
            "age": fmt_age(now - start), "tok": fmt_tok(tokens), "steps": steps,
            "acao": f"{verbo} {alvo}".strip()[:38],
            "mtime": st.st_mtime, "dot": GREEN,
        })
    agents.sort(key=lambda a: -a["mtime"])
    return agents


def state_key(agents, cols):
    h = hashlib.sha1()
    h.update(f"{cols}|{ROWS}|".encode())
    for a in agents:
        h.update(f"{a['type']}|{a['desc']}|{a['age']}|{a['tok']}|{a['acao']}|".encode())
    return h.hexdigest()[:16]


def font(size, bold=False):
    from PIL import ImageFont
    for pat in FONTS:
        p = pat.format("Bold" if bold else "Medium")
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size, index=1 if p.endswith(".ttc") and bold else 0)
            except OSError:
                continue
    return ImageFont.load_default()


def panel_cols(n):
    """Largura do painel em celulas: cresce com o numero de colunas de caixas."""
    ncol = 1 + (n - 1) // PER_COL
    px = 30 + 22 + 26 + ncol * (80 + 14) + 20
    return max(10, -(-px // (CELL_W * DPR)))


def render(agents, cols):
    """So o fluxo: raiz, barramento e uma caixinha por agente ativo. Sem texto."""
    from PIL import Image, ImageDraw
    W, H = cols * CELL_W * DPR, ROWS * CELL_H * DPR
    img = Image.new("RGB", (W, H), term_bg())
    d = ImageDraw.Draw(img)
    n = len(agents)
    ncol = 1 + (n - 1) // PER_COL
    per = -(-n // ncol)
    x0, y0, y1 = 15 * DPR, 12 * DPR, H - 12 * DPR
    ry = (y0 + y1) / 2
    d.rounded_rectangle([x0, ry - 7 * DPR, x0 + 11 * DPR, ry + 7 * DPR], radius=3 * DPR,
                        fill=SURF0, outline=OVER0, width=DPR)
    bw, gap = 40 * DPR, 3 * DPR
    bh = max(5 * DPR, min(9 * DPR, (y1 - y0 - (per - 1) * gap) / per))
    for c in range(ncol):
        inc = min(per, n - c * per)
        span = inc * (bh + gap) - gap
        ytop = ry - span / 2
        x = x0 + 26 * DPR + c * (bw + 7 * DPR)
        bus = x - 7 * DPR
        d.line([(bus, ytop + bh / 2), (bus, ytop + span - bh / 2)], fill=SURF1, width=DPR)
        src = x0 + 11 * DPR if c == 0 else x0 + 26 * DPR + (c - 1) * (bw + 7 * DPR) + bw
        d.line([(src, ry), (bus, ry)], fill=SURF1, width=DPR)
        for k in range(inc):
            a = agents[c * per + k]
            y = ytop + k * (bh + gap)
            d.line([(bus, y + bh / 2), (x, y + bh / 2)], fill=SURF1, width=DPR)
            d.rounded_rectangle([x, y, x + bw, y + bh], radius=2 * DPR, fill=SURF0,
                                outline=a["dot"], width=DPR)
            d.rectangle([x + 4 * DPR, y + bh / 2 - 1.5 * DPR, x + 9 * DPR, y + bh / 2 + 1.5 * DPR],
                        fill=a["dot"])
    return img


def kitty_escape(img, img_id, cols):
    import base64
    import io
    buf = io.BytesIO()
    img.save(buf, "PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    out = []
    for n, c in enumerate(chunks):
        head = f"f=100,t=d,a=T,U=1,i={img_id},q=2,c={cols},r={ROWS}," if n == 0 else ""
        out.append("\033_G%sm=%d;%s\033\\" % (head, 1 if n < len(chunks) - 1 else 0, c))
    return "".join(out)


def placeholders(img_id, cols, gutter):
    r, g, b = (img_id >> 16) & 0xFF, (img_id >> 8) & 0xFF, img_id & 0xFF
    return [f"{gutter}\033[38;2;{r};{g};{b}m" + PH + chr(DIAC[i]) + chr(DIAC[0])
            + (PH + chr(DIAC[i])) * (cols - 1) + "\033[0m" for i in range(ROWS)]


def texto(agents, cols, gutter):
    """Fallback sem imagem: um cartão por agente (até 3), senão uma linha por agente."""
    G, S, T, D = "\033[38;2;88;91;112m", "\033[38;2;78;82;106m", "\033[0m", "\033[38;2;165;173;203m"
    GR, R = "\033[38;2;166;218;149m", "\033[0m"
    out = []
    if len(agents) <= 3:
        w = min(36, (cols - 4) // max(len(agents), 1) - 1)
        tops = " ".join("╭" + "─" * w + "╮" for _ in agents)
        bots = " ".join("╰" + "─" * w + "╯" for _ in agents)
        out.append(f"{gutter}{S}{tops}{R}")
        for campo in ("at", "desc", "num"):
            linha = []
            for a in agents:
                if campo == "at":
                    txt = f"{GR}● @{a['type']}{R}"
                    pad = w - 4 - len(a["type"])
                elif campo == "desc":
                    s = (a["desc"] or a["acao"])[:w - 3]
                    txt = f"{D}  {s}{R}"
                    pad = w - 3 - len(s)
                else:
                    s = f"{a['age']} · {a['tok']} · passo {a['steps']}"[:w - 3]
                    txt = f"{D}  {s}{R}"
                    pad = w - 3 - len(s)
                linha.append(f"{S}│{R} {txt}{' ' * max(pad, 0)}{S}│{R}")
            out.append(gutter + " ".join(linha))
        out.append(f"{gutter}{S}{bots}{R}")
    else:
        for a in agents[:6]:
            out.append(f"{gutter}{GR}● @{a['type']}{R} {D}{(a['desc'] or a['acao'])[:cols - 40]}"
                       f"{R} {S}·{R} {D}{a['age']} · {a['tok']}{R}")
    return out


def main():
    if len(sys.argv) < 5:
        return 0
    subdir, tty, cols, session_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    agents = read_agents(subdir)
    if not agents and os.path.exists(os.path.expanduser("~/.claude/.agent-map-demo")):
        # modo demo: confere o caminho inteiro (imagem + placeholders) sem agente rodando
        agents = [{"type": t, "desc": d, "age": a, "tok": k, "steps": p, "acao": "", "dot": GREEN}
                  for t, d, a, k, p in [
                      ("executor", "Build the admin UI", "12m29s", "134.3k", 48),
                      ("revisor", "Review the whole skeleton", "9m28s", "171.5k", 31),
                      ("geral", "Localizar os hooks do deployer", "2m04s", "21.8k", 12)]]
    if not agents:
        return 0
    gutter = "\033[38;2;88;91;112m│\033[0m  "
    larg = max(40, min(cols - 6, 160))          # largura util do terminal (fallback em texto)
    cols = max(10, min(panel_cols(len(agents)), larg))   # largura do painel de imagem
    grafico = tty not in ("", "-") and os.path.exists(f"/dev/{tty}") and os.access(f"/dev/{tty}", os.W_OK)
    if not grafico:
        print("\n".join(texto(agents, larg, gutter)))
        return 0

    img_id = int(hashlib.sha1(session_id.encode()).hexdigest()[:6], 16) or 1
    key = state_key(agents, cols)
    os.makedirs(CACHE, exist_ok=True)
    esc_path = os.path.join(CACHE, f"{session_id}.esc")
    key_path = os.path.join(CACHE, f"{session_id}.key")
    old = ""
    try:
        with open(key_path) as fh:
            old = fh.read().strip()
    except OSError:
        pass
    # retransmite quando o conteúdo muda ou a cada 60s (caso o terminal tenha largado a imagem)
    stale = True
    try:
        stale = time.time() - os.stat(esc_path).st_mtime > 60
    except OSError:
        pass
    if old != key or stale or not os.path.exists(esc_path):
        try:
            esc = kitty_escape(render(agents, cols), img_id, cols)
        except Exception:
            print("\n".join(texto(agents, larg, gutter)))
            return 0
        with open(esc_path, "w") as fh:
            fh.write(esc)
        with open(key_path, "w") as fh:
            fh.write(key)
    try:
        with open(f"/dev/{tty}", "w") as fh, open(esc_path) as src:
            fh.write(src.read())
    except OSError:
        print("\n".join(texto(agents, larg, gutter)))
        return 0
    print("\n".join(placeholders(img_id, cols, gutter)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
