# claudecode-statusbar

A two-line status line for Claude Code, with a map of the active sub-agents drawn as an image inside the terminal.

## Install

```
curl -fsSL https://raw.githubusercontent.com/danielfnfaria/claudecode-statusbar/main/install.sh | sh
```

Uninstall: `... | sh -s -- --uninstall`

The installer checks its dependencies, validates both scripts before replacing anything, keeps a timestamped backup of every file it touches, and leaves an existing `statusLine` command alone when it already points at the script.

## What it shows

**Line 1 — work**: active cloud profile, running agents, kubectl context (red warning on production), branch with ahead/behind, local changes and stashes, and the session's PR with its CI state.

**Line 2 — session**: model, effort, context, cost, 5-hour and 7-day limits, cache and duration — all as gradient bars.

Both lines adapt to the terminal width: as it narrows, items are dropped from the least to the most important.

## Agent map

While a sub-agent is running, a compact flow chart appears: the root is the session and each small box is one agent, colored by state. With no active agent it takes up no lines at all.

It works the way it does because the Claude Code TUI strips escape sequences from the status line output. So the image is transmitted straight to the tty using the kitty graphics protocol, and the status line itself prints only Unicode placeholders, which are ordinary text. On a terminal without that support it falls back to a text drawing.

Needs Ghostty, kitty or WezTerm, and Pillow. Without them the rest of the status line works exactly the same.

## Configuration

Copy `statusline.conf.example` to `~/.claude/statusline.conf`:

- `PROFILE_COLORS` — color of the cloud profile, by prefix
- `KCTX_STRIP_PREFIX` — prefix to strip from the kubectl context name

Agent map variables: `AGENT_MAP_BG`, `AGENT_MAP_ROWS`, `AGENT_MAP_MAX_AGE`, `AGENT_MAP_FONT`.

## Dependencies

`bash`, `jq`. Optional: `python3` + Pillow (agent map), `git` (branch), `gh` (pull requests).
