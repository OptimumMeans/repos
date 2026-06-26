# repos — Dropbox-style on/off toggle for GitHub repos

Keep any number of GitHub repos without keeping them all on disk. The GitHub
remote is the "cloud" copy; you hydrate only what you're working on — freeing disk
while every repo stays one click (or one command) away. A native macOS menu-bar
app, backed by a small `repo` CLI.

## Quick start

```bash
# prerequisites
xcode-select --install        # Swift compiler (skip if already installed)
brew install gh librsvg
gh auth login

# clone anywhere, then run the installer
git clone https://github.com/OptimumMeans/repos && cd repos
./install.sh
```

`install.sh` is idempotent and location-independent — it builds the app, links the
`repo` CLI onto your PATH, and starts everything at login, resolving paths from
wherever you cloned. Undo it all with `./install.sh uninstall`.

## The app

`Repos.app` lives in your menu bar and launches at login. Click its icon for a popover:

- **Repo list** split into **On this Mac** and **Cloud only**, each row with size,
  status, and an on/off **switch** — flip it to clone or offload.
- **Live download progress** while a repo clones.
- **Search** to filter by name.
- **Browse files** — click an on-disk repo to walk its files right in the popover,
  open any file in its default app, or jump to Finder.
- **Auto-reconnect** — go offline and back and the list refreshes itself, with a
  "Back online" notification. No manual refresh.

## CLI

The same engine, from the terminal:

```bash
repo list                 # all your GitHub repos; ● = on this machine, with sizes
repo on  <name>           # clone into ~/dev (blobless partial clone — small & fast)
repo off <name>           # offload; refuses if you have unsaved/unpushed work
repo off --force <name>   # offload anyway
repo status               # disk usage of cloned repos
```

Names accept `repo` (your account) or `owner/repo`. Override the clone location with `REPO_DIR`.

## How it saves space

- **Partial clone** (`--filter=blob:none`) pulls history metadata but not every
  historical file blob — blobs fetch on demand, so even large repos land small.
- **Offloading** removes an idle repo from disk entirely. It stays safe on GitHub,
  and `repo off` won't delete anything you haven't pushed.

## Requirements

macOS, [`gh`](https://cli.github.com) (authenticated), and the Swift compiler from
the Xcode Command Line Tools. `brew install librsvg` provides the icon renderer.
