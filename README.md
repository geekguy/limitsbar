# LimitsBar

A tiny macOS menu bar app that shows Claude Code and Codex usage limits — 5-hour, weekly, and Fable — across every account you're logged into, with reset countdowns.

## What it shows

- **Menu bar:** the lowest 5-hour usage per provider, e.g. `C 18% · X 100%`, i.e. the account with the most headroom right now.
- **Dropdown:** every account, most headroom first, with 5-hour / weekly / Fable bars, a countdown and time for each reset, a thin timeline of how far along each window is, Codex credit status, and Codex "limit reset" credits with the expiry date of each. Refreshes every 5 minutes.

## Primary account

Each row has a **make primary** action; the current one shows a `primary` tag. It writes the profile dir to `~/.claude/.primary` or `~/.codex/.primary` (empty means the base dir). A shell wrapper that reads that file at launch can then open the bare `claude` / `codex` command on that account, while explicit per-profile wrappers and running sessions are unaffected. The file is a plain path, so a shell command like `claude-primary engg` can write it just as well.

## How it finds accounts

It reads the same profiles the CLIs use, so there is nothing to configure:

- **Claude Code:** `~/.claude` plus any `~/.claude-*` config dir (the `CLAUDE_CONFIG_DIR` convention). The token comes from the Keychain item the CLI stores for that dir; if it has expired, the CLI's own cached usage is shown instead.
- **Codex:** `~/.codex` plus any `~/.codex-*` dir (the `CODEX_HOME` convention), via each dir's `auth.json`.

## Install

Requirements: macOS 14+, Xcode command line tools (`swiftc`), `python3`.

```sh
git clone git@github.com:geekguy/limitsbar.git && cd limitsbar
ln -s "$PWD/limits" ~/.local/bin/limits   # the fetch script the app runs
./build.sh                                # builds ~/Applications/LimitsBar.app and launches it
```

To start at login, add `~/Applications/LimitsBar.app` under System Settings → General → Login Items.

## Files

- `main.swift` — the SwiftUI `MenuBarExtra` app, one file.
- `build.sh` — compiles, bundles, ad-hoc signs, and relaunches the app.
- `limits` — stdlib-only Python that fetches usage from `api.anthropic.com/api/oauth/usage` and `chatgpt.com/backend-api/wham/usage`. Also works standalone: `limits`, `limits --watch`, `limits --json`.
