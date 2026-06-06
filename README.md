# AICreditsBar

A native macOS **menu-bar** widget that continuously shows how much token/quota is
left for **Codex**, **Claude**, and **Gemini** — and flags when a window has refilled.

```
  Cx 54%  ·  Cl 31%  ·  Gm —
```

- **Green** > 50% left · **Yellow** 20–50% · **Red** < 20% · **Gray** unknown/stale · **↑** just refilled.
- **Auto-detects** which AI CLIs you use — it just reads each tool's local data dir. Nothing to configure to get started.
- Click the bar for a breakdown (5h + weekly windows, reset countdown, plan, burn rate).
- Auto-refreshes every 30s (configurable) and on every menu open. **No network calls** — everything is read from local CLI data on disk.

## What each provider shows

| Provider | Source | Accuracy |
|---|---|---|
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` → `rate_limits` | **Exact official %** — 5h (`primary`) + weekly (`secondary`), straight from the server, with real reset times. |
| **Claude** | `~/.claude/projects/**/*.jsonl` token usage | **Estimate** vs a budget (ccusage-style 5h block + 7-day sum). Anthropic stores no official % on disk, so you **calibrate** it once for accuracy (see below). |
| **Gemini** | `~/.gemini/` | Install / login status only — Gemini CLI exposes no local quota %. Shows `—`. |

> Numbers update only when that CLI actually makes a request, so a snapshot can be a few
> minutes old (shown as "snapshot Nm ago"). Stale Codex windows are greyed instead of shown as confident green.

## Build & run

```bash
bash build.sh          # compiles main.swift → AICreditsBar.app (needs Xcode CLT: swiftc)
open AICreditsBar.app  # launches the menu-bar agent (no Dock icon)
```

Quit from the menu (**Quit AICreditsBar**) or `pkill -f aicreditsbar`. Print values as text without the GUI:

```bash
./AICreditsBar.app/Contents/MacOS/aicreditsbar --once
```

## Settings

Open **Settings…** from the menu (⌘,). Everything persists across launches:

- **Show in menu bar** — 5-hour window · Weekly window · Both (`5h/week`) · Lowest of the two.
- **Providers** — toggle Codex / Claude / Gemini, and whether to show the `Cx/Cl/Gm` labels.
- **Refresh interval**.
- **Colors & thresholds** — pick your own High / Mid / Low / Unknown colors and the green/yellow cutoffs.
- **Claude budget** — choose a plan (Pro / Max 5x / Max 20x) or a custom token budget.

### Calibrate Claude for accuracy

Because Claude has no official % on disk, the cleanest accurate fix is a one-time calibration:

1. In Claude Code, run `/usage` and note your real **5h used %** and **weekly used %**.
2. In **Settings → Calibrate**, type those two numbers and click **Calibrate**.

The app back-computes your token budgets from the current usage so the displayed % matches
reality, then tracks proportionally as you spend tokens. Re-calibrate occasionally if it drifts.

## Start at login (optional)

```bash
bash install-login-item.sh     # registers a LaunchAgent that runs it at login
bash install-login-item.sh -u  # remove it
```

## Files

- `main.swift` — the whole app (data readers + menu-bar UI + settings).
- `build.sh` — compile + assemble the `.app` bundle.
- `install-login-item.sh` — add/remove the login LaunchAgent.
- `probe.py` — reference reader in Python; prints the same numbers (used to validate the Swift).

## How it works / privacy

AICreditsBar never makes network requests and never touches your credentials. It only reads the
usage/limit data the CLIs already write to disk under `~/.codex`, `~/.claude`, and `~/.gemini`,
computes the numbers locally, and draws them in the menu bar.

## License

MIT — see [LICENSE](LICENSE).
