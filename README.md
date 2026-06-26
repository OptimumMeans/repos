# repos — Dropbox-style on/off toggle for GitHub repos

Keep any number of GitHub repos without keeping them all on disk. The GitHub
remote is the "cloud" copy; you hydrate only what you're working on. Frees storage
on the MacBook while keeping every repo one click (or one command) away — via a
native menu-bar app or the `repo` CLI.

## Quick start

```bash
# prerequisites
xcode-select --install        # Swift compiler for the apps (skip if already installed)
brew install gh librsvg
gh auth login

# clone anywhere, then run the installer
git clone https://github.com/OptimumMeans/repos && cd repos
./install.sh
```

`install.sh` is idempotent and location-independent: it links the `repo` CLI onto
your PATH, builds the menu-bar app + notifier, writes the `gh` token file, and
installs two launchd agents (the app at login + the reconnect watcher) — resolving
every path from wherever you cloned. Undo it all with `./install.sh uninstall`.

## Components

| File | What it does |
|------|--------------|
| `install.sh` | One-shot, idempotent setup: PATH symlink, app + notifier builds, token file, launchd agents. `./install.sh uninstall` to undo. |
| `repo` | CLI: `repo on/off/list/status`. Symlinked onto PATH at `~/.local/bin/repo`. |
| `menubar/` | Native SwiftUI menu-bar app (`Repos.app`) — the Dropbox-style UI. Built with `swiftc`. |
| `repo-netwatch` | Runs on network changes; on reconnect posts a "Back online" notification. |
| `repo-notify` | Shared notification helper — GitHub-icon app with an osascript fallback. |
| `notifier/` | Builds `GitHub Repos.app`, a tiny Swift notifier (Apple `UserNotifications`) so alerts show the GitHub mark. |
| `launchd/` | The two launchd agents: `com.aerviz.repos.app` (app at login) and `com.aerviz.repos.netwatch` (reconnect watcher). |

## Menu-bar app

`Repos.app` is a native SwiftUI `MenuBarExtra` that launches at login. Click its
menu-bar icon for a popover:

- **Repo list** grouped into **On this Mac** (sticky, at top) and **Cloud only**,
  each row with size, status, and an on/off **switch** (clone ⇄ offload).
- **Search** to filter by name.
- **Clone progress** — a live % bar streamed from git while a repo downloads.
- **File browser** — click an on-disk repo to browse its files in-app: descend
  folders, open files in their default app, or jump to Finder.
- **⋯ menu** — fire a test notification (debug) or quit.

It drives the `repo` CLI underneath and reads the `gh` token from a file so it
works in the GUI context (a menu-bar process can't read the keychain).

## CLI usage

```bash
repo list                 # all GitHub repos; ● = on this machine, with sizes
repo on  <name>           # clone into ~/dev (blobless partial clone — small & fast)
repo off <name>           # remove local copy; refuses if unsaved/unpushed work
repo off --force <name>   # remove anyway
repo status               # disk usage of cloned repos
```

Names accept `repo` (your account) or `owner/repo`. Clone location overridable via `REPO_DIR`.

## How it saves space

- **Partial clone** (`--filter=blob:none`) pulls history metadata but not every
  historical file blob; blobs fetch on demand. Large repos land small.
- **Offloading** idle repos removes them from disk entirely. They stay safe on
  GitHub, and `repo off` won't delete anything not yet pushed.

## Auto-reconnect (no manual refresh)

When the Mac is offline, `gh` can't reach GitHub. On reconnect everything recovers
on its own: the app watches connectivity (`NWPathMonitor`) and re-pulls its list,
and a launchd agent (`repo-netwatch`, watching
`/Library/Preferences/SystemConfiguration` — rewritten on every network change)
posts a **"Back online — Signed in to GitHub ✓"** notification. No polling, no clicking.

## Notifications

Alerts show the GitHub mark (not the Script Editor icon) via `notifier/` — a tiny
signed Swift app posting through Apple's `UserNotifications`. (An `osacompile`
applet can't register as a notification client on modern macOS; a real signed app
can.) The first post triggers the one-time "Allow Notifications" prompt, which
`install.sh` fires during setup.

## Requirements

macOS, [`gh`](https://cli.github.com), and the Swift compiler (`swiftc`, from the
Xcode Command Line Tools) for the apps. `rsvg-convert` (`brew install librsvg`)
renders the notifier icon. Everything else is macOS built-ins.
