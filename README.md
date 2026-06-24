# repos — Dropbox-style on/off toggle for GitHub repos

Keep 55+ GitHub repos without keeping them all on disk. The GitHub remote is the
"cloud" copy; you hydrate only what you're working on. Frees storage on the
MacBook Neo while keeping every repo one click (or one command) away.

## Components

| File | What it does |
|------|--------------|
| `repo` | CLI: `repo on/off/list/status`. Symlinked onto PATH at `~/.local/bin/repo`. |
| `repo-toggle` | Click handler for the menu bar — toggles a repo and shows a macOS notification. |
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

## Requirements

`git` (≥2.19 for partial clone), [`gh`](https://cli.github.com), and SwiftBar for the menu bar.
