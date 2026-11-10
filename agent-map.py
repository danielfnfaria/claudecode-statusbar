#!/usr/bin/env python3
"""Status line agent map: the tree of ACTIVE sub-agents, as an image.

Usage: agent-map.py <subagents dir> <tty|-> <terminal columns> <session_id> [--inline]

With --inline the whole tree is drawn inside a single text row, to sit in the status line
itself; without it, it is the taller panel that goes below the line.
The image goes straight to the tty (Claude's TUI filters the sequence on stdout);
stdout only gets the kitty protocol Unicode placeholders, which are plain text. Without a
compatible terminal it falls back to a text drawing (one dot per agent, inline).
With no active agent, prints nothing.
"""
import hashlib
import json
import os
import sys
import time

MAX_AGE = int(os.environ.get("AGENT_MAP_MAX_AGE", "60"))   # sec. since the last write
STALE = 1800         # an unfinished agent older than this is treated as abandoned
ROWS = int(os.environ.get("AGENT_MAP_ROWS", "4"))
MAX_ROWS = 8         # the panel grows vertically only up to this
BOX_W = 40           # box size, in logical px
BOX_H, BOX_GAP = 9, 3
SBOX_W, SBOX_H = 13, 7   # mini box of the inline map (one text row)
SLEAVES = 4              # the inline map stacks at most this many boxes
CELL_W, CELL_H, DPR = 10, 20, 2
CACHE = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR")
                     or os.path.expanduser("~/.claude"), "cache", "agent-map")
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

ACTIONS = {"Read": "reading", "Edit": "editing", "Write": "writing", "NotebookEdit": "editing",
         "Bash": "running", "Grep": "searching", "Glob": "searching", "WebSearch": "searching",
         "WebFetch": "reading web", "Agent": "delegating", "Task": "delegating",
         "SubagentHandback": "delivering report"}


def term_bg():
    """Terminal background color: env > Ghostty config > theme file > default."""
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
    """Scans the last lines of the .jsonl backwards, returning the ones that match."""
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
    agents, raw = [], []
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
        if now - st.st_mtime > STALE:
            continue
        meta = {}
        try:
            with open(path[:-6] + ".meta.json", encoding="utf-8") as fh:
                meta = json.load(fh)
        except Exception:
            pass
        if meta.get("stoppedByUser"):
            continue
        done = bool(meta.get("finished"))
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
        verb = ACTIONS.get(tool, tool.lower() if tool else "thinking")
        obj = os.path.basename(target) if tool in ("Read", "Edit", "Write", "NotebookEdit") else target
        raw.append(data)
        agents.append({
            "tuid": meta.get("toolUseId") or "",
            "parent": -1,
            "type": meta.get("agentType") or "agent",
            "desc": meta.get("description") or "",
            "age": fmt_age(now - start), "tok": fmt_tok(tokens), "steps": steps,
            "acao": f"{verb} {obj}".strip()[:38],
            "mtime": st.st_mtime, "dot": GREEN,
            "fresh": (now - st.st_mtime <= MAX_AGE) and not done,
        })
    # parentesco: o toolUseId de um agente aparece no transcript de quem o disparou;
    # quando não aparece em nenhum, ele foi disparado pela sessão principal.
    order = sorted(range(len(agents)), key=lambda i: -agents[i]["mtime"])
    agents = [agents[i] for i in order]
    raw = [raw[i] for i in order]
    for i, a in enumerate(agents):
        if not a["tuid"]:
            continue
        needle = b'"id":"' + a["tuid"].encode() + b'"'
        for j, data in enumerate(raw):
            if j != i and needle in data:
                a["parent"] = j
                break
    ativo = [a["fresh"] for a in agents]
    for _ in range(len(agents)):
        mudou = False
        for i, a in enumerate(agents):
            p = a["parent"]
            if ativo[i] and 0 <= p < len(agents) and not ativo[p]:
                ativo[p] = True
                mudou = True
        if not mudou:
            break
    for i, a in enumerate(agents):
        if ativo[i] and not a["fresh"]:
            a["dot"] = OVER0          # está esperando os filhos, não trabalhando
    novo = [i for i, v in enumerate(ativo) if v]
    pos = {old: new for new, old in enumerate(novo)}
    agents = [agents[i] for i in novo]
    for a in agents:
        a["parent"] = pos.get(a["parent"], -1)
    return agents


def state_key(agents, cols):
    h = hashlib.sha1()
    h.update(f"{cols}|".encode())
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


def tree(agents):
    """-> (filhos, raizes, profundidade, faixa de cada no, total de faixas)"""
    kids = {i: [] for i in range(len(agents))}
    roots = []
    for i, a in enumerate(agents):
        if 0 <= a.get("parent", -1) < len(agents):
            kids[a["parent"]].append(i)
        else:
            roots.append(i)
    depth, slot, nxt = {}, {}, [0]

    def walk(i, d):
        depth[i] = d
        if not kids[i]:
            slot[i] = nxt[0]
            nxt[0] += 1
        else:
            for c in kids[i]:
                walk(c, d + 1)
            slot[i] = sum(slot[c] for c in kids[i]) / len(kids[i])

    for r in roots:
        walk(r, 0)
    return kids, roots, depth, slot, max(nxt[0], 1)


def cap_agents(agents):
    """Keeps only what fits in the tallest panel; a dropped parent promotes its children."""
    usable = MAX_ROWS * CELL_H * DPR - 24 * DPR
    room = max(1, int((usable + BOX_GAP * DPR) // ((5 + BOX_GAP) * DPR)))
    if len(agents) <= room:
        return agents, 0
    kept = agents[:room]                       # já vem do mais recente para o mais antigo
    for a in kept:
        if a.get("parent", -1) >= room:
            a["parent"] = -1
    return kept, len(agents) - room


def panel_size(agents):
    """Cells the panel needs: width from the tree depth, height from the leaf count."""
    _, _, depth, _, leaves = tree(agents)
    maxd = (max(depth.values()) + 1) if depth else 1
    w_px = 15 + 11 + 15 + maxd * (BOX_W + 14) * DPR + 16
    h_px = leaves * (BOX_H + BOX_GAP) * DPR + 24 * DPR
    return (max(10, -(-int(w_px) // (CELL_W * DPR))),
            min(MAX_ROWS, max(ROWS, -(-int(h_px) // (CELL_H * DPR)))))


def render(agents, cols, rows):
    """Flow only: the session, one box per active agent, nested under whoever spawned it."""
    from PIL import Image, ImageDraw
    W, H = cols * CELL_W * DPR, rows * CELL_H * DPR
    img = Image.new("RGB", (W, H), term_bg())
    d = ImageDraw.Draw(img)
    kids, roots, depth, slot, leaves = tree(agents)

    x0, y0, y1 = 15 * DPR, 12 * DPR, H - 12 * DPR
    ry = (y0 + y1) / 2
    d.rounded_rectangle([x0, ry - 7 * DPR, x0 + 11 * DPR, ry + 7 * DPR], radius=3 * DPR,
                        fill=SURF0, outline=OVER0, width=DPR)

    bw = BOX_W * DPR
    gap = BOX_GAP * DPR
    bh = max(5 * DPR, min(BOX_H * DPR, (y1 - y0 - (leaves - 1) * gap) / leaves))
    span = leaves * (bh + gap) - gap
    ytop = ry - span / 2

    def box_x(i):
        return x0 + 26 * DPR + depth[i] * (bw + 14 * DPR)

    def box_y(i):
        return ytop + slot[i] * (bh + gap)

    for i, a in enumerate(agents):
        x, y = box_x(i), box_y(i)
        # ligação com quem o disparou: a sessão (raiz) ou o agente pai
        if i in roots:
            px, py = x0 + 11 * DPR, ry
        else:
            p = a.get("parent", -1)
            px, py = box_x(p) + bw, box_y(p) + bh / 2
        bend = px + 7 * DPR
        d.line([(px, py), (bend, py), (bend, y + bh / 2), (x, y + bh / 2)], fill=SURF1, width=DPR)
        d.rounded_rectangle([x, y, x + bw, y + bh], radius=2 * DPR, fill=SURF0,
                            outline=a["dot"], width=DPR)
        d.rectangle([x + 4 * DPR, y + bh / 2 - 1.5 * DPR, x + 9 * DPR, y + bh / 2 + 1.5 * DPR],
                    fill=a["dot"])
    return img


def inline_size(agents):
    """Cells the one-row map needs: only the tree depth matters, the height is fixed."""
    _, _, depth, _, _ = tree(agents)
    maxd = (max(depth.values()) + 1) if depth else 1
    w_px = (4 + 9 + maxd * (SBOX_W + 5)) * DPR
    return max(3, -(-int(w_px) // (CELL_W * DPR)))


def render_inline(agents, cols):
    """The whole map inside a single text row: the session, then the agents it spawned."""
    from PIL import Image, ImageDraw
    W, H = cols * CELL_W * DPR, CELL_H * DPR
    img = Image.new("RGB", (W, H), term_bg())
    d = ImageDraw.Draw(img)
    kids, roots, depth, slot, leaves = tree(agents)

    x0, ry, pad = 2 * DPR, H / 2, 3 * DPR
    d.rounded_rectangle([x0, ry - 4 * DPR, x0 + 5 * DPR, ry + 4 * DPR], radius=2 * DPR,
                        fill=SURF0, outline=OVER0, width=DPR)
    bw, gap = SBOX_W * DPR, 2 * DPR
    bh = max(3 * DPR, min(SBOX_H * DPR, (H - 2 * pad - (leaves - 1) * gap) / leaves))
    ytop = ry - (leaves * (bh + gap) - gap) / 2

    def box_x(i):
        return x0 + 9 * DPR + depth[i] * (bw + 5 * DPR)

    def box_y(i):
        return ytop + slot[i] * (bh + gap)

    for i, a in enumerate(agents):
        x, y = box_x(i), box_y(i)
        if i in roots:
            px, py = x0 + 5 * DPR, ry
        else:
            p = a["parent"]
            px, py = box_x(p) + bw, box_y(p) + bh / 2
        bend = px + 2 * DPR
        d.line([(px, py), (bend, py), (bend, y + bh / 2), (x, y + bh / 2)], fill=SURF1, width=DPR)
        d.rounded_rectangle([x, y, x + bw, y + bh], radius=1.5 * DPR, fill=SURF0,
                            outline=a["dot"], width=DPR)
        d.rectangle([x + 2 * DPR, y + bh / 2 - DPR, x + 5 * DPR, y + bh / 2 + DPR], fill=a["dot"])
    return img


def cap_inline(agents):
    """Keeps the boxes readable: at most SLEAVES of them, the most recent first."""
    kept = agents[:SLEAVES]
    for a in kept:
        if a.get("parent", -1) >= len(kept):
            a["parent"] = -1
    return kept


def inline_fallback(agents):
    """Image-less fallback: one dot per agent, colored by state."""
    out = ""
    for a in agents:
        r, g, b = a["dot"]
        out += f"\033[38;2;{r};{g};{b}m\u25cf"
    return out + "\033[0m"


def kitty_escape(img, img_id, cols, rows):
    import base64
    import io
    buf = io.BytesIO()
    img.save(buf, "PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    out = []
    for n, c in enumerate(chunks):
        head = f"f=100,t=d,a=T,U=1,i={img_id},q=2,c={cols},r={rows}," if n == 0 else ""
        out.append("\033_G%sm=%d;%s\033\\" % (head, 1 if n < len(chunks) - 1 else 0, c))
    return "".join(out)


def placeholders(img_id, cols, rows, gutter):
    r, g, b = (img_id >> 16) & 0xFF, (img_id >> 8) & 0xFF, img_id & 0xFF
    return [f"{gutter}\033[38;2;{r};{g};{b}m" + PH + chr(DIAC[i]) + chr(DIAC[0])
            + (PH + chr(DIAC[i])) * (cols - 1) + "\033[0m" for i in range(rows)]


def text_fallback(agents, cols, gutter):
    """Image-less fallback: one card per agent (up to 3), otherwise one line per agent."""
    G, S, T, D = "\033[38;2;88;91;112m", "\033[38;2;78;82;106m", "\033[0m", "\033[38;2;165;173;203m"
    GR, R = "\033[38;2;166;218;149m", "\033[0m"
    out = []
    if len(agents) <= 3:
        w = min(36, (cols - 4) // max(len(agents), 1) - 1)
        tops = " ".join("╭" + "─" * w + "╮" for _ in agents)
        bots = " ".join("╰" + "─" * w + "╯" for _ in agents)
        out.append(f"{gutter}{S}{tops}{R}")
        for field in ("at", "desc", "num"):
            row = []
            for a in agents:
                if field == "at":
                    txt = f"{GR}● @{a['type']}{R}"
                    pad = w - 4 - len(a["type"])
                elif field == "desc":
                    s = (a["desc"] or a["acao"])[:w - 3]
                    txt = f"{D}  {s}{R}"
                    pad = w - 3 - len(s)
                else:
                    s = f"{a['age']} · {a['tok']} · step {a['steps']}"[:w - 3]
                    txt = f"{D}  {s}{R}"
                    pad = w - 3 - len(s)
                row.append(f"{S}│{R} {txt}{' ' * max(pad, 0)}{S}│{R}")
            out.append(gutter + " ".join(row))
        out.append(f"{gutter}{S}{bots}{R}")
    else:
        for a in agents[:6]:
            out.append(f"{gutter}{GR}● @{a['type']}{R} {D}{(a['desc'] or a['acao'])[:cols - 40]}"
                       f"{R} {S}·{R} {D}{a['age']} · {a['tok']}{R}")
    return out


def main():
    argv = [a for a in sys.argv[1:] if a != "--inline"]
    inline = "--inline" in sys.argv        # the map inside the status line, in one text row
    if len(argv) < 4:
        return 0
    subdir, tty, cols, session_id = argv[0], argv[1], int(argv[2]), argv[3]
    agents = read_agents(subdir)
    if not agents and os.path.exists(os.path.expanduser("~/.claude/.agent-map-demo")):
        # demo mode: exercises the whole path (image + placeholders) with no agent running
        agents = [{"type": t, "desc": d, "age": a, "tok": k, "steps": p, "acao": "",
                   "dot": GREEN, "parent": par, "tuid": ""}
                  for t, d, a, k, p, par in [
                      ("executor", "Build the admin UI", "12m29s", "134.3k", 48, -1),
                      ("revisor", "Review the whole skeleton", "9m28s", "171.5k", 31, 0),
                      ("geral", "Locate the deployer hooks", "2m04s", "21.8k", 12, 0)]]
    if not agents:
        return 0
    gutter = "\033[38;2;88;91;112m│\033[0m  "
    term_w = max(40, min(cols - 6, 160))          # usable terminal width (text fallback)
    if inline:
        agents = cap_inline(agents)
        cols, rows = inline_size(agents), 1
        gutter = ""
    else:
        agents, extra = cap_agents(agents)
        cols, rows = panel_size(agents)
        cols = max(10, min(cols, term_w))                  # image panel width
    grafico = tty not in ("", "-") and os.path.exists(f"/dev/{tty}") and os.access(f"/dev/{tty}", os.W_OK)
    if not grafico:
        print(inline_fallback(agents) if inline else "\n".join(text_fallback(agents, term_w, gutter)))
        return 0

    img_id = int(hashlib.sha1(session_id.encode()).hexdigest()[:6], 16) or 1
    key = state_key(agents, f"{'i' if inline else 'p'}{cols}x{rows}")
    os.makedirs(CACHE, exist_ok=True)
    esc_path = os.path.join(CACHE, f"{session_id}.esc")
    key_path = os.path.join(CACHE, f"{session_id}.key")
    old = ""
    try:
        with open(key_path) as fh:
            old = fh.read().strip()
    except OSError:
        pass
    # retransmit when the content changes or every 60s (in case the terminal dropped the image)
    stale = True
    try:
        stale = time.time() - os.stat(esc_path).st_mtime > 60
    except OSError:
        pass
    if old != key or stale or not os.path.exists(esc_path):
        try:
            img = render_inline(agents, cols) if inline else render(agents, cols, rows)
            esc = kitty_escape(img, img_id, cols, rows)
        except Exception:
            print(inline_fallback(agents) if inline else "\n".join(text_fallback(agents, term_w, gutter)))
            return 0
        # escrita atômica: outra invocação (refresh de 5s) pode estar lendo o arquivo,
        # e meia sequência kitty deixa o terminal com a imagem antiga.
        tmp_esc = f"{esc_path}.{os.getpid()}"
        with open(tmp_esc, "w") as fh:
            fh.write(esc)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_esc, esc_path)
        tmp_key = f"{key_path}.{os.getpid()}"
        with open(tmp_key, "w") as fh:
            fh.write(key)
        os.replace(tmp_key, key_path)
    try:
        with open(f"/dev/{tty}", "w") as fh, open(esc_path) as src:
            fh.write(src.read())
    except OSError:
        print(inline_fallback(agents) if inline else "\n".join(text_fallback(agents, term_w, gutter)))
        return 0
    print("\n".join(placeholders(img_id, cols, rows, gutter)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
