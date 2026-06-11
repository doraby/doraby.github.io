# Task Time Tracker (macOS, 100% local)

A small menu-bar app for macOS that automatically tracks how long you spend in
each application (like RescueTime), turns those blocks into a daily task list
you can rename and annotate, and optionally takes periodic screenshots.

**Everything is stored only on your Mac.** The app contains no network code —
nothing is ever uploaded anywhere.

## Features

- **Automatic tracking** — every 5 seconds the app notes which application is
  in the foreground (and its window title) and builds contiguous "task" blocks.
- **Idle detection** — if you don't touch the keyboard/mouse for 3 minutes,
  the clock stops.
- **Daily task list** — open the dashboard from the menu-bar icon to see the
  tasks for any day. Each block gets an automatic title
  (`App — Window title`); click a title or description to edit it. Edits are
  saved immediately.
- **Per-app totals** — the dashboard also shows total time per application
  and for the whole day.
- **Optional screenshots** — toggle "Enable Screenshots" in the menu to save a
  JPEG of your main display every 5 minutes (off by default).
- **Pause/Resume** tracking any time from the menu.

## Where your data lives

```
~/Library/Application Support/TaskTimeTracker/
├── 2026-06-11.json          # one plain-JSON file per day
└── Screenshots/
    └── 2026-06-11/…jpg      # only if screenshots are enabled
```

Use "Open Data Folder" in the menu to jump there. Delete files to delete data.

## Build & run (requires Xcode or Command Line Tools)

```bash
cd timetracker
./build-app.sh
mv -f TaskTimeTracker.app /Applications/
open /Applications/TaskTimeTracker.app
```

A clock icon appears in the menu bar. (For a quick test without bundling you
can also run `swift run`, but permissions then attach to your terminal app,
so the bundled .app is recommended.)

## Permissions

macOS requires **Screen Recording** permission for two optional features:
reading other apps' **window titles** and taking **screenshots**. Grant it in
*System Settings → Privacy & Security → Screen Recording* by adding
TaskTimeTracker, then relaunch the app.

Without that permission the app still works — tasks are titled with just the
application name.

## Start at login

System Settings → General → Login Items → "+" → choose TaskTimeTracker.app.

## Tuning

Constants at the top of `Sources/TaskTimeTracker/Tracker.swift`:

- `interval` — polling frequency (default 5 s)
- `idleLimit` — idle cutoff (default 180 s)
- `mergeGap` — switching back to an app within this gap extends the previous
  task instead of creating a new one (default 180 s)

Screenshot frequency: `interval` in `Screenshotter.swift` (default 300 s).
