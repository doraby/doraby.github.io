# Task Time Tracker (macOS, local by default)

A small menu-bar app for macOS that automatically tracks how long you spend in
each application (like RescueTime), turns those blocks into a daily task list
you can rename and annotate, and optionally takes screenshots.

**Everything is stored only on your Mac by default.** Tracking, screenshots,
task rules, grouping — none of it involves the network. The one exception is
the fully optional **AI features** (see below): if you set an OpenAI API key,
selected screenshots and task summaries get sent to OpenAI's API to auto-name
tasks and generate workflow recommendations. Until you set a key, that code
path never runs — nothing leaves your Mac at all.

## Features

- **Automatic tracking** — every 5 seconds the app notes which application is
  in the foreground (and its window title) and builds contiguous "task" blocks.
- **Idle detection** — if you don't touch the keyboard/mouse for 3 minutes,
  the clock stops.
- **Daily task list** — open the dashboard from the menu-bar icon to see the
  tasks for any day. Each block gets an automatic title
  (`App — Window title`); click a title or description to edit it. Edits are
  saved immediately.
- **Automatic, specific titles via rules** — instead of the generic
  `App — Window title`, you can define text-pattern rules (no AI, no
  screenshots — just matching the window title macOS already reports) that
  turn a block into something like "Building Task Tracker" or "Writing
  customer email". See **Task rules** below.
- **Per-app and per-category totals** — the dashboard shows total time per
  application, per category (from your rules), and for the whole day.
- **Optional screenshots** — toggle "Enable Screenshots" in the menu to save a
  JPEG of your main display every 5 minutes (off by default).
- **Pause/Resume** tracking any time from the menu.

## Task rules (specific task titles, no screenshots needed)

The tracker only ever sees two things macOS itself already exposes: the
frontmost app's name, and its window title (e.g. Xcode shows the file and
project name, Safari shows the page title, Mail shows the subject/recipient).
No AI and no screen-content reading is involved — screenshots are a fully
separate, optional feature.

Rules let you turn those window titles into specific task names. Open
**"Edit Task Rules…"** from the menu bar — it opens
`~/Library/Application Support/TaskTimeTracker/rules.json`, an editable JSON
list. Each rule has:

- `pattern` — a case-insensitive regular expression tested against
  `"AppName — Window Title"`. The first matching rule wins.
- `title` — the task title to use when it matches (optional; leave it out to
  keep the automatic title but still tag a category).
- `category` — an optional grouping label shown in "Time per category".

The app ships with a starter file covering exactly the examples you gave:

```json
[
  { "pattern": "(Xcode|Visual Studio Code|Cursor).*(TaskTimeTracker|timetracker)",
    "title": "Building Task Tracker", "category": "Coding" },
  { "pattern": "unschooler", "title": "Testing Unschooler", "category": "QA" },
  { "pattern": "Mail.*(Compose|New Message)",
    "title": "Writing customer email", "category": "Communication" },
  { "pattern": "linkedin", "title": "Editing LinkedIn post", "category": "Marketing" }
]
```

Edit these to match your real project/window-title wording (open the app you
mean and check the exact title shown, e.g. via Mission Control or the Window
menu, to get the pattern right), add new rules for other tasks, then click
**"Reload Task Rules"** in the menu — no rebuild needed. Rules only apply to
*new* blocks going forward; existing entries keep their titles until you edit
them by hand in the dashboard.

## AI features (optional — the only thing that uses the network)

Off by default, and inert until you set an API key. Two things, both
running on a timer every 3 hours (also triggerable anytime via **"Run AI
Task Analysis Now"**):

1. **Auto-describe tasks from a screenshot.** For each task today that has
   a screenshot and hasn't been processed yet, sends *one* screenshot plus
   its current title to a cheap vision model (`gpt-4o-mini`) and asks what
   the task actually is. The response becomes the task's new title, and
   gets appended to its description. Only tasks lasting 20s+ are sent (a
   handful of quick blips isn't worth an API call), capped at 25 per cycle.
2. **Workflow recommendations.** After that, sends a full text log of the
   day — every task, every underlying block/switch, down to the second —
   to the same model and asks for concrete recommendations (reducing
   context-switching, batching similar work, etc). Saved with a timestamp
   to `workflow-recommendations.txt` in the data folder; open it anytime
   via **"Open Workflow Recommendations"** in the menu.

**Setup:** menu bar → **"Set OpenAI API Key…"** → paste a key from
[platform.openai.com](https://platform.openai.com/api-keys). It's stored in
your macOS Keychain (`security find-generic-password -s TaskTimeTracker`),
never in a file in this repo or on disk in plain text. Clear it the same way
(leave the field blank and click "Clear") to turn the feature back off —
the cron then does nothing but check for a key and skip.

**What actually gets sent, and when:** nothing, until a key is set. Once
set: one screenshot + a short title per newly-finished task (not every
screenshot — see `aiDescribed`/`ai-log.txt` in the data folder for what
ran), and once per cycle, the day's task titles/timestamps as plain text.
Screenshot image *files* stay local either way; only the one selected per
task is uploaded as part of that API call.

**Keeping the app name after a rename.** Every block still stores its own
`appName` (e.g. "Cursor") and an immutable `autoTitle` — the original
"App — window" label captured the moment it was created — regardless of
how many times `title` gets rewritten (by a rule, by you, or by the AI
pass). The dashboard shows the apps used ("Cursor · 4 blocks · …") on every
task card so you can always see what actually happened even after the
title becomes something abstract like "Coding the Time Tracker app".

## Where your data lives

```
~/Library/Application Support/TaskTimeTracker/
├── 2026-06-11.json               # one plain-JSON file per day
├── rules.json                    # your task-naming rules
├── categories.json                # domain -> category map
├── screenshot-log.txt            # diagnostic log for the screenshot feature
├── ai-log.txt                    # diagnostic log for the AI cron (see below)
├── workflow-recommendations.txt  # AI-generated recommendations, if enabled
└── Screenshots/
    └── 2026-06-11/…jpg      # only if screenshots are enabled
```

Use "Open Data Folder" in the menu to jump there. Delete files to delete data.

## Build & run (requires Xcode or Command Line Tools)

**One-time setup**, before your first build — gives the app a stable
identity so macOS permissions survive rebuilds (see **Permissions** below
for why this matters):

```bash
cd timetracker
./setup-dev-cert.sh
```

Then, every time you build:

```bash
cd timetracker
./build-app.sh
rm -rf /Applications/TaskTimeTracker.app
mv -f TaskTimeTracker.app /Applications/
open /Applications/TaskTimeTracker.app
```

(The `rm -rf` first matters: `mv` into an existing `TaskTimeTracker.app`
nests the new build *inside* the old one instead of replacing it, silently
leaving you running stale code.)

A clock icon appears in the menu bar.

`build-app.sh` compiles the sources directly with `swiftc` rather than
`swift build`, since some Command Line Tools-only installations fail to
link SwiftPM's own manifest compiler (a toolchain issue unrelated to this
app) — `swiftc` only needs the macOS SDK, so it's more reliable. If you
have a full Xcode install and prefer `swift build`/`swift run`, that also
works, but permissions then attach to your terminal app instead of to the
bundled .app.

## Permissions

macOS requires **Screen Recording** permission for reading other apps'
**window titles** and for taking **screenshots**. Grant it in *System
Settings → Privacy & Security → Screen Recording* by adding
TaskTimeTracker, then relaunch the app. Chrome tab tracking additionally
needs one-time **Automation** approval (macOS asks automatically the first
time).

Without Screen Recording permission the app still works — tasks are
titled with just the application name, and screenshots silently do
nothing (check `screenshot-log.txt` in the data folder if unsure).

**Important:** run `./setup-dev-cert.sh` once (see above) *before*
granting these permissions. Without it, `build-app.sh` signs the app
"ad-hoc," and ad-hoc signatures change on every rebuild — so a permission
you grant gets silently revoked the next time you rebuild, with no error
and no re-prompt. This is why screenshots/window titles can appear to
"work once, then never again." If you already hit this: run
`setup-dev-cert.sh`, then in System Settings remove any existing
TaskTimeTracker entries from Screen Recording (and Automation) before
rebuilding and re-granting — the permission should then persist across
every future rebuild.

## Start at login

System Settings → General → Login Items → "+" → choose TaskTimeTracker.app.

## Tuning

Constants at the top of `Sources/TaskTimeTracker/Tracker.swift`:

- `interval` — polling frequency (default 5 s)
- `idleLimit` — idle cutoff (default 180 s)
- `mergeGap` — switching back to an app within this gap extends the previous
  task instead of creating a new one (default 180 s)

Screenshot frequency: `interval` in `Screenshotter.swift` (default 300 s).
