#!/usr/bin/env bash
# SwiftBar plugin — Dropbox-style on/off toggle for GitHub repos.
# Menu bar GitHub icon → dropdown of repos. Click to add (cloud→machine) or
# offload (machine→cloud). Reuses ~/dev/bin/repo and ~/dev/bin/repo-toggle.
# <xbar.title>GitHub Repos</xbar.title>
# <xbar.desc>Toggle GitHub repos on/off locally to save storage.</xbar.desc>

export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$HOME/dev}"   # where clones live (matches `repo` tool default)
TOGGLE="$HERE/../repo-toggle"        # move-proof: relative to this plugin
ICON="$(cat "$HERE/.github-icon.b64" 2>/dev/null)"

# --- Menu bar icon (template image adapts to light/dark menu bar) ---
if [ -n "$ICON" ]; then
  echo "| templateImage=$ICON"
else
  echo ":logo.github:"   # SF Symbol fallback if the icon file is missing
fi
echo "---"

# --- Not logged in? ---
if ! gh auth status >/dev/null 2>&1; then
  echo "Not logged in to GitHub | color=red"
  echo "Run: gh auth login | font=Menlo size=11 color=gray"
  exit 0
fi

# --- Gather repos (name, owner/repo, size in KB) ---
ROWS="$(gh repo list --limit 200 --json name,nameWithOwner,diskUsage \
        --jq '.[] | "\(.name)\t\(.nameWithOwner)\t\(.diskUsage)"' 2>/dev/null | sort)"

on_count=0; cloud_count=0
on_lines=""; cloud_lines=""
while IFS=$'\t' read -r name slug ku; do
  [ -z "$name" ] && continue
  mb=$(( ku / 1024 ))
  if [ -d "$REPO_DIR/$name/.git" ]; then
    on_count=$((on_count+1))
    on_lines+="● ${name}  (${mb} MB) | bash=\"$TOGGLE\" param1=off param2=\"$name\" terminal=false refresh=true\n"
  else
    cloud_count=$((cloud_count+1))
    cloud_lines+="-- ○ ${name}  (${mb} MB) | bash=\"$TOGGLE\" param1=on param2=\"$name\" terminal=false refresh=true\n"
  fi
done <<< "$ROWS"

# --- On machine (top level, click to offload) ---
echo "On machine — ${on_count} | size=12 color=gray"
if [ "$on_count" -gt 0 ]; then printf "%b" "$on_lines"; else echo "(none — all offloaded) | size=11 color=gray"; fi

echo "---"

# --- Cloud only (submenu, click to add) ---
echo "Cloud only — ${cloud_count}  ▸ | size=12 color=gray"
printf "%b" "$cloud_lines"

echo "---"
echo "Refresh | refresh=true"
echo "Open ~/dev | bash=/usr/bin/open param1=$REPO_DIR terminal=false"
