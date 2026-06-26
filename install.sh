#!/usr/bin/env bash
# install.sh — set up the `repos` toolkit on this Mac. Idempotent; safe to re-run.
# Resolves wherever you cloned the repo, so no fixed path is assumed.
#   ./install.sh            install / update
#   ./install.sh uninstall  remove the launchd agent + PATH symlink
set -euo pipefail

REPOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LABEL="com.aerviz.repos.netwatch"
AGENT_SRC="$REPOS_DIR/launchd/$LABEL.plist"
AGENT_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"
TOKEN_FILE="$HOME/.config/gh/swiftbar-token"
PLUGIN_DIR="$REPOS_DIR/swiftbar-plugins"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
say()  { printf '    %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname)" = "Darwin" ] || { echo "This toolkit is macOS-only (launchd + SwiftBar)."; exit 1; }

# ---------------------------------------------------------------- uninstall ---
if [ "${1:-}" = "uninstall" ]; then
  step "Uninstalling"
  launchctl unload "$AGENT_DST" 2>/dev/null || true
  rm -f "$AGENT_DST"; ok "removed launchd agent"
  if [ -L "$BIN_DIR/repo" ]; then rm -f "$BIN_DIR/repo"; ok "removed repo PATH symlink"; fi
  say "Left in place (harmless): token file, built notifier app, SwiftBar plugin-dir pref."
  exit 0
fi

# ------------------------------------------------------------- prerequisites ---
step "Checking prerequisites"
missing=""
have gh || missing+=" gh"
if [ -n "$missing" ]; then
  warn "missing required tool(s):$missing"
  say  "install, then re-run:  brew install$missing"
  exit 1
fi
ok "gh present"
have rsvg-convert || warn "rsvg-convert missing — notifier will fall back to the Script Editor icon (brew install librsvg)"
[ -d "/Applications/SwiftBar.app" ] || warn "SwiftBar not installed — the menu bar won't appear (brew install --cask swiftbar)"

# Git usually preserves the +x bit, but restore it just in case.
chmod +x "$REPOS_DIR/repo" "$REPOS_DIR/repo-toggle" "$REPOS_DIR/repo-netwatch" \
         "$REPOS_DIR/notifier/build.sh" 2>/dev/null || true

# --------------------------------------------------------- repo CLI on PATH ---
step "Linking the repo CLI onto PATH"
mkdir -p "$BIN_DIR"
ln -sf "$REPOS_DIR/repo" "$BIN_DIR/repo"
ok "$BIN_DIR/repo → $REPOS_DIR/repo"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH — add it in your shell profile";;
esac

# ------------------------------------------------------------- notifier app ---
step "Building the GitHub-icon notifier"
if have rsvg-convert; then
  if "$REPOS_DIR/notifier/build.sh" >/dev/null 2>&1; then
    ok 'built "GitHub Repos.app"'
  else
    warn "notifier build failed — notifications will use the default icon"
  fi
else
  warn "skipped — no rsvg-convert"
fi

# ------------------------------------------------------------- token file -----
# Lets gh authenticate from the menu-bar/launchd context, which can't read the
# keychain. `gh auth token` prints the active token if you're already logged in.
step "Writing the GitHub token file"
if gh auth token >/dev/null 2>&1; then
  mkdir -p "$(dirname "$TOKEN_FILE")"
  gh auth token > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "wrote $TOKEN_FILE"
else
  warn "not logged in to GitHub"
  say  "run: gh auth login"
  say  "then: gh auth token > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
fi

# ------------------------------------------------------ SwiftBar plugin dir ---
step "Pointing SwiftBar at the plugins"
if [ -d "/Applications/SwiftBar.app" ]; then
  defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"
  ok "PluginDirectory = $PLUGIN_DIR"
  if pgrep -x SwiftBar >/dev/null; then
    osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1 || true
    sleep 1
  fi
  open -a SwiftBar >/dev/null 2>&1 || true
  ok "SwiftBar (re)started"
else
  warn "SwiftBar not installed — skipped"
fi

# --------------------------------------------------------- launchd agent ------
# Start from the committed plist but replace ProgramArguments with THIS clone's
# absolute path, so the install works no matter where the repo was cloned.
step "Installing the auto-reconnect agent"
mkdir -p "$(dirname "$AGENT_DST")"
launchctl unload "$AGENT_DST" 2>/dev/null || true
rm -f "$AGENT_DST"
cp "$AGENT_SRC" "$AGENT_DST"
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$AGENT_DST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$AGENT_DST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $REPOS_DIR/repo-netwatch" "$AGENT_DST"
launchctl load "$AGENT_DST"
# Note: plain grep (not grep -q) so it reads to EOF — grep -q would close the
# pipe early, SIGPIPE launchctl, and pipefail would flag a false negative.
if launchctl list | grep "$LABEL" >/dev/null; then
  ok "agent loaded ($LABEL)"
else
  warn "agent did not load — check: launchctl list | grep repos"
fi

step "Done"
say "Auto-reconnect is live. Flip wifi off then on to see the menu bar refresh + a notification."
say "Uninstall any time with:  ./install.sh uninstall"
