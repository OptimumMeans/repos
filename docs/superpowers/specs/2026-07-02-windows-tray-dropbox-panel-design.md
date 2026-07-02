# Windows tray: Dropbox-style flyout panel

Date: 2026-07-02
Status: Approved (design), pending implementation plan

## Problem

The Windows port of the `repos` tray app (`windows/ReposTray.ps1`) uses a bare
WinForms `ContextMenuStrip`. It works, but it looks like a gray system menu, not
a polished app. The macOS version has a rich menu-bar popover; the goal is to
give Windows a comparable, Dropbox-style flyout panel with feature parity.

## Goals

- A borderless, rounded, shadowed flyout panel that opens on left-click of the
  tray icon and hides on click-away, anchored bottom-right above the taskbar.
- Feature parity with the macOS app:
  - Sectioned repo list (ON THIS PC / CLOUD ONLY) with per-row icon, name, size,
    and a toggle switch to clone/offload.
  - Live search that filters the list as you type.
  - Inline clone/offload progress (spinner) on the affected row.
  - File browsing: click an on-disk repo to walk its files, open a file in its
    default app, or jump to Explorer.
  - Repo actions: Open in Explorer, Copy clone URL, Open on GitHub.
  - Footer: Refresh, Open clone dir, Quit.
- No new toolchain. Built-in Windows PowerShell 5.1 only (WPF + WinForms ship
  with it).
- `install.ps1` and `ReposTray.vbs` stay unchanged (same entry filename).

## Non-goals

- Real clone percentage. Blobless partial clones give no honest progress signal,
  so progress is an indeterminate spinner, not a fake percent bar.
- Changing the `repo` CLI, the installer, or the macOS app.
- Auto-pinning the icon into the always-visible tray. That is a user-controlled
  Windows setting by design; out of scope.

## Technology decision: WPF panel + WinForms tray icon

A native context menu cannot be styled to look like Dropbox, and hand-drawing
rounded corners, shadows, and toggle switches in WinForms is heavy GDI+ code that
still looks dated. WPF (also part of PowerShell 5.1 via `PresentationFramework`)
provides rounded corners (`Border.CornerRadius`), a drop shadow
(`DropShadowEffect`), templated toggle switches, and a smooth `ItemsControl`
list with far less code and a more modern result.

WPF has no native tray icon, so the existing `System.Windows.Forms.NotifyIcon`
is kept for the tray icon. The app runs as a single WPF `Application`
(`ShutdownMode = OnExplicitShutdown`) whose Dispatcher provides the message pump
that the `NotifyIcon` needs. This WinForms-icon + WPF-window hybrid is the
established pattern for PowerShell tray apps.

Rejected alternative: pure WinForms, custom owner-drawn. Keeps one framework but
is more code and looks less like Dropbox.

## Architecture: three files (replacing today's single ReposTray.ps1)

The current single file is replaced by a focused split so each unit has one job
and the data layer is testable independently of the GUI.

### RepoOps.ps1 (pure data/ops, no UI)

The only unit-testable part. Functions:

- `Get-RepoDir` - resolve clone root (`$env:REPO_DIR` or `~\dev`).
- `Test-RepoOnDisk($name)` - is the repo cloned (has a `.git`).
- `Get-Repos` - call `gh repo list --json name,nameWithOwner,diskUsage`, return
  objects `{ Name, Slug, SizeMB, OnDisk }` sorted by name. On failure return a
  structured error the UI can show.
- `Format-SizeMB($kilobytes)` - kB -> integer MB (matches current display).
- `Start-RepoToggle($name, $action)` - launch a background `Start-Job` that runs
  `repo.ps1 on|off <name>` via the existing shim, merging stderr (`cmd /c ... 2>&1`).
  Returns the job. (Lifted from today's `Start-Toggle` job body.)
- `Get-RepoFiles($repoName, $relativePath)` - enumerate one directory level for
  the file browser: folders first, then files, each with name, is-directory, and
  size. Rooted at the repo dir; refuses to escape it.
- `Get-RepoUrls($slug)` - return `{ Clone; Web }` for the copy/open actions.

No WPF or WinForms references in this file.

### panel.xaml (the WPF layout)

One rounded, shadowed card (`Window` with `AllowsTransparency=True`,
`WindowStyle=None`, `Background=Transparent`; inner `Border` with corner radius +
`DropShadowEffect`). Two stacked views inside the card, one visible at a time:

- List view: header (title + summary line "N on this PC - X MB"), search
  `TextBox`, scrollable `ItemsControl` with a section header template and a repo
  row template (glyph, name, size, toggle switch, per-row spinner shown while a
  job runs), and a footer bar (Refresh, Open dir, Quit).
- Browse view: breadcrumb + back button, a file/folder `ItemsControl`, and a
  button to open the current folder in Explorer.

Glyphs come from Segoe Fluent Icons / Segoe MDL2 Assets (built into Windows):
package, cloud, refresh, folder, power. No image assets.

Named elements (`x:Name`) are looked up from code with `FindName`; there is no
data binding framework, the code sets `ItemsSource` and text directly.

### ReposTray.ps1 (entry point + wiring)

- Single-instance mutex (kept from today).
- Load `RepoOps.ps1` (dot-source) and `panel.xaml` (parse with
  `XamlReader`), build the `Window`.
- Create the `NotifyIcon` with the code-drawn package glyph (kept from today) and
  a minimal right-click menu whose only item is Quit (fallback).
- Left-click toggles panel visibility. On show: position bottom-right above the
  work area (`SystemParameters.WorkArea`), refresh data, render the list.
- Panel hides on `Deactivated` (click-away).
- Row switch click -> `Start-RepoToggle`, mark the row busy (spinner), disable it.
- Row body click -> switch to browse view for that repo.
- Row right-click -> context menu: Open in Explorer / Copy clone URL / Open on
  GitHub (via `Get-RepoUrls`).
- Search `TextChanged` -> re-render filtered list.
- Footer: Refresh re-fetches; Open dir launches Explorer; Quit shuts down.
- A `DispatcherTimer` (2s) completes finished jobs (balloon on success/failure,
  refresh row) and detects network reconnect (refresh + "Back online" balloon).
  This folds in today's timer logic.
- Run under `[System.Windows.Application]` with `OnExplicitShutdown`.

## Data flow

1. Tray left-click -> `ReposTray` shows the window and calls `Get-Repos`
   (`RepoOps`) which shells out to `gh`.
2. Results render into the XAML list.
3. Switch click -> `Start-RepoToggle` (`RepoOps`) spawns a job running the
   existing `repo.ps1`; row shows a spinner.
4. Timer tick -> job done -> balloon + `Get-Repos`/re-render.
5. Row click -> `Get-RepoFiles` (`RepoOps`) -> browse view.

The GUI never calls `gh`/`git` directly; all shelling out lives in `RepoOps.ps1`.

## Error handling

- `gh repo list` failure: `Get-Repos` returns an error object; the panel shows an
  inline "check gh auth login" row (matches today's `fetchError`).
- Clone/offload failure (including the `repo off` unsaved-work refusal): the job
  exits non-zero; the timer shows an error balloon with the last output line
  (matches today's behavior).
- File browse errors (locked/again removed dir): show an empty state, never throw
  out of an event handler. `$ErrorActionPreference = 'Continue'` is kept for the
  same native-stderr reason documented in today's script.
- Path safety: `Get-RepoFiles` refuses to enumerate outside the repo root.

## Testing

- `RepoOps.ps1`: Pester tests for `Format-SizeMB`, `Test-RepoOnDisk` and
  `Get-RepoFiles` against a temp directory tree, `Get-RepoUrls` string building,
  and `Get-Repos` JSON shaping with a stubbed `gh` output. These run without a
  display.
- GUI: manual verification against a checklist (open/close on click and
  click-away, position above the taskbar, toggle clone then offload with spinner
  and balloon, search filter, browse into a repo and open a file, the three
  right-click actions, Refresh/Open/Quit). WPF interaction is not meaningfully
  auto-testable; this is called out rather than faked.
- Every script parse-checked (`[Parser]::ParseFile`) before the tray is
  relaunched.

## Rollout

- Replace `windows/ReposTray.ps1`; add `windows/RepoOps.ps1`,
  `windows/panel.xaml`, and `windows/RepoOps.Tests.ps1`.
- `install.ps1` and `ReposTray.vbs` are unchanged (same entry filename).
- Update the Windows section of `README.md` to describe the panel.
- Restart the running tray after install to pick up the new UI.

## Style

No em dashes anywhere in code, comments, or docs (user-wide preference).
