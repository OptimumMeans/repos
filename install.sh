#!/usr/bin/env bash
# install.sh — set up the `repos` toolkit on this Mac. Idempotent; safe to re-run.
# Resolves wherever you cloned the repo, so no fixed path is assumed.
#   ./install.sh            install / update
#   ./install.sh uninstall  remove the launchd agents + PATH symlink
set -euo pipefail

REPOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$HOME/.local/bin"
TOKEN_FILE="$HOME/.config/gh/swiftbar-token"
NETWATCH=com.aerviz.repos.netwatch
APP_AGENT=com.aerviz.repos.app

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
say()  { printf '    %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname)" = "Darwin" ] || { echo "This toolkit is macOS-only (launchd + a SwiftUI menu-bar app)."; exit 1; }

# Install (or replace) a launchd agent from a committed plist, rewriting its
# ProgramArguments to PROG so the path matches wherever the repo was cloned.
install_agent() { # label, src_plist, program_path
  local label="$1" src="$2" prog="$3"
  local dst="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$(dirname "$dst")"
  launchctl unload "$dst" 2>/dev/null || true
  rm -f "$dst"
  cp "$src" "$dst"
  /usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$dst" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$dst"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $prog" "$dst"
  launchctl load "$dst"
  # plain grep (not -q): -q closes the pipe early, SIGPIPEs launchctl, and
  # pipefail would then flag a false negative.
  if launchctl list | grep "$label" >/dev/null; then ok "agent loaded ($label)"; else warn "agent did not load ($label)"; fi
}

remove_agent() { # label
  local dst="$HOME/Library/LaunchAgents/$1.plist"
  launchctl unload "$dst" 2>/dev/null || true
  rm -f "$dst"
}

# ---------------------------------------------------------------- uninstall ---
if [ "${1:-}" = "uninstall" ]; then
  step "Uninstalling"
  remove_agent "$APP_AGENT"; pkill -x Repos 2>/dev/null || true; ok "removed menu-bar app agent + quit Repos"
  remove_agent "$NETWATCH"; ok "removed reconnect agent"
  if [ -L "$BIN_DIR/repo" ]; then rm -f "$BIN_DIR/repo"; ok "removed repo PATH symlink"; fi
  say "Left in place (harmless): token file, built apps."
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
have swiftc || warn "swiftc missing — the menu-bar app + notifier need Xcode Command Line Tools (xcode-select --install)"
have rsvg-convert || warn "rsvg-convert missing — notifier falls back to the Script Editor icon (brew install librsvg)"

# Git usually preserves the +x bit, but restore it just in case.
chmod +x "$REPOS_DIR/repo" "$REPOS_DIR/repo-netwatch" "$REPOS_DIR/repo-notify" \
         "$REPOS_DIR/notifier/build.sh" "$REPOS_DIR/menubar/build.sh" 2>/dev/null || true

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
if have rsvg-convert && have swiftc; then
  if "$REPOS_DIR/notifier/build.sh" >/dev/null 2>&1; then
    ok 'built "GitHub Repos.app"'
    # Fire once now so the one-time macOS "Allow Notifications" prompt appears
    # while you're here, establishing authorization before the first reconnect.
    if "$REPOS_DIR/repo-notify" --app "Setup" "Notifications enabled ✓" >/dev/null 2>&1; then
      ok "notifications authorized"
    else
      warn "if macOS shows a notification prompt, click Allow (else alerts use the default icon)"
    fi
  else
    warn "notifier build failed — notifications fall back to the Script Editor icon"
  fi
else
  warn "skipped (needs rsvg-convert + swiftc) — notifications fall back to the Script Editor icon"
fi

# --------------------------------------------------------- menu-bar app -------
step "Building the Repos menu-bar app"
if have swiftc; then
  if "$REPOS_DIR/menubar/build.sh" >/dev/null 2>&1; then ok 'built "Repos.app"'; else warn "menu-bar app build failed"; fi
else
  warn "skipped — no swiftc (xcode-select --install)"
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

# ----------------------------------------------------------- launchd agents ---
step "Installing the menu-bar app (launch at login)"
pkill -x Repos 2>/dev/null || true   # avoid a duplicate instance; the agent relaunches it
install_agent "$APP_AGENT" "$REPOS_DIR/launchd/$APP_AGENT.plist" \
              "$REPOS_DIR/menubar/Repos.app/Contents/MacOS/Repos"

step "Installing the auto-reconnect agent"
install_agent "$NETWATCH" "$REPOS_DIR/launchd/$NETWATCH.plist" \
              "$REPOS_DIR/repo-netwatch"

step "Done"
say "The Repos app is in your menu bar now and will start at login."
say "Auto-reconnect notifications are live — no manual refresh."
say "Uninstall any time with:  ./install.sh uninstall"
