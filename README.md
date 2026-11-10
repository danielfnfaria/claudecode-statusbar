# claudecode-statusbar

A single-line status line for Claude Code, with a map of the active sub-agents drawn as an image inside the terminal.

![The status line while sub-agents are spawned, nested and finished](docs/statusline.gif)

## Install

```
curl -fsSL https://raw.githubusercontent.com/danielfnfaria/claudecode-statusbar/main/install.sh | sh
```

Uninstall: `... | sh -s -- --uninstall`

The installer checks its dependencies, validates both scripts before replacing anything, keeps a timestamped backup of every file it touches, and leaves an existing `statusLine` command alone when it already points at the script.

## What it shows

![The status line, item by item](docs/statusline.png)

One line, in this order:

| item | what it is |
| --- | --- |
| `✦ Opus 5` | the model, in a badge colored by family |
| `☁ profile` | the active cloud profile (gcloud), colored by prefix |
| `⎇ main ⇡7 ⇣1 +7/-1 ⚑ 1` | branch, commits to push and to pull, lines changed, stashes |
| `#482 ✓ #483 ⏳` | the PRs opened in this session that are still open: one link each, green as soon as every check passes |
| `🧠 33% 66k` | the context window in use |
| `⏳ 5h 46% ↻13:00` | the 5-hour limit and when it resets |
| `📅 7d 61%` | the 7-day limit |
| `⏱ 1h22m` | how long the session has been running |

Context and limits come as bars with a green → yellow → red gradient, filled to an eighth of a
character. A session name (`/rename`, `--name` or the automatic title) opens the line.

The line adapts to the terminal width: as it narrows, items are dropped from the least to the
most important — the stash goes first, the model and the context window are the last to go.

## Agent map

While a sub-agent is running, a compact flow chart appears below the line: the root is the session and each small box is one agent, colored by state. With no active agent it takes up no lines at all.

![The map up close: the session, two agents under it, and one nested deeper](docs/agent-map-detail.png)

A green outline is an agent working right now; a gray one is waiting for the agents it spawned.

It works the way it does because the Claude Code TUI strips escape sequences from the status line output. So the image is transmitted straight to the tty using the kitty graphics protocol, and the status line itself prints only Unicode placeholders, which are ordinary text. On a terminal without that support it falls back to a text drawing.

Needs Ghostty, kitty or WezTerm, and Pillow. Without them the rest of the status line works exactly the same.

## Configuration

Copy `statusline.conf.example` to `~/.claude/statusline.conf`:

- `PROFILE_COLORS` — color of the cloud profile, by prefix
- `AGENT_MAP` — `off` turns the agent map off entirely

Agent map variables: `AGENT_MAP_BG`, `AGENT_MAP_ROWS`, `AGENT_MAP_MAX_AGE`, `AGENT_MAP_FONT`.

## Dependencies

`bash`, `jq`. Optional: `python3` + Pillow (agent map), `git` (branch), `gh` (pull requests).
