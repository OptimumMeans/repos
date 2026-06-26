# repos — Dropbox-style on/off toggle for GitHub repos

Keep any amount of GitHub repos without keeping them all on disk. The GitHub remote is the
"cloud" copy; you hydrate only what you're working on. Frees storage on the
MacBook Neo while keeping every repo one click (or one command) away.

## Quick start

```bash
# prerequisites (Homebrew)
brew install gh librsvg && brew install --cask swiftbar
gh auth login

# clone anywhere, then run the installer
git clone https://github.com/OptimumMeans/repos && cd repos
./install.sh
```

`install.sh` is idempotent and location-independent: it links the `repo` CLI onto
your PATH, builds the notifier app, writes the `gh` token file, points SwiftBar at
the plugins, and installs + loads the auto-reconnect agent — resolving every path
from wherever you cloned. Undo it all with `./install.sh uninstall`.

## Components

| File | What it does |
|------|--------------|
| `install.sh` | One-shot, idempotent setup: PATH symlink, notifier build, token file, SwiftBar wiring, launchd agent. `./install.sh uninstall` to undo. |
| `repo` | CLI: `repo on/off/list/status`. Symlinked onto PATH at `~/.local/bin/repo`. |
| `repo-toggle` | Click handler for the menu bar — toggles a repo and shows a macOS notification. |
| `repo-netwatch` | Runs on network changes: on reconnect, re-checks GitHub auth, refreshes the menu bar, and posts a notification. No manual refresh. |
| `repo-notify` | Shared notification helper — GitHub-icon app with an osascript fallback. Used by the above and the SwiftBar **Debug** menu. |
| `launchd/com.aerviz.repos.netwatch.plist` | launchd agent that triggers `repo-netwatch` on wifi/network changes and at login. |
| `notifier/` | Builds `GitHub Repos.app`, a tiny Swift notifier (Apple `UserNotifications`) so alerts show the GitHub mark, not the Script Editor icon. |
| `swiftbar-plugins/github.5m.sh` | [SwiftBar](https://swiftbar.app) plugin: GitHub icon in the menu bar, dropdown of repos, click to add/offload. |
| `swiftbar-plugins/.github-icon.b64` | Base64 GitHub mark (Octicons) used as the menu-bar template image. |

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

## Menu bar (SwiftBar)

```bash
brew install --cask swiftbar
defaults write com.ameba.SwiftBar PluginDirectory "$HOME/dev/repos/swiftbar-plugins"
open -a SwiftBar
```

Click the GitHub icon → **On machine** (click to offload) and **Cloud only ▸**
(click to add). Requires `gh auth login`.

## Auto-reconnect (no manual refresh)

When the Mac is offline, the menu bar shows **Not logged in** because `gh` can't
reach GitHub. `repo-netwatch` fixes that without polling or clicking: a launchd
agent watches `/Library/Preferences/SystemConfiguration` (rewritten on every
wifi/network change) and fires the watcher. On an offline→online transition it
re-checks auth, force-refreshes the SwiftBar plugin instantly, and posts a
**“Back online — Signed in to GitHub ✓”** notification. It also runs once at login.

Notifications carry the GitHub mark instead of the Script Editor icon via a small
bundled app (`notifier/`). **`./install.sh` builds it and installs the agent for
you** — that's the recommended path.

To do it by hand instead: run `notifier/build.sh`, then copy
`launchd/com.aerviz.repos.netwatch.plist` into `~/Library/LaunchAgents/` and
`launchctl load` it. launchd won't expand `~` in a program path, so the committed
plist invokes the watcher as `/bin/bash -c 'exec "$HOME/dev/repos/repo-netwatch"'`
(assumes the repo at `~/dev/repos`); `install.sh` sidesteps that entirely by
writing the resolved absolute path of wherever you actually cloned. Unload with
`launchctl unload <plist>`.

## Requirements

`git` (≥2.19 for partial clone), [`gh`](https://cli.github.com), and SwiftBar for the menu bar.
The notifier app compiles a tiny Swift binary (`swiftc`, from the Xcode Command Line Tools) plus `rsvg-convert`; everything else is macOS built-ins.
