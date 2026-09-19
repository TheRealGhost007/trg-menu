# Changelog: bugs found and fixed

A running log of real bugs hit while building this, how they were diagnosed,
and what actually fixed them — kept because "it was hitching, we fixed it"
isn't useful to anyone else hitting a similar symptom. Every entry below was
confirmed via instrumentation/reproduction before being called fixed, not
just theorized.

## Selection jumps during Apps navigation (pre-dates this repo)

**Symptom:** Arrow-key navigation in Apps would intermittently "fight" the
user — the cursor would snap to a different row while navigating, especially
noticeable as "can't get past [app name]."

**Root cause:** Steam repeatedly rewrites its installed games' `.desktop`
files in the background. Quickshell's `DesktopEntries.applications` fired
`onValuesChanged` in tight bursts whenever this happened, with the reported
count fluctuating by a few either way each time. The menu rebuilt its Apps
list on every single one of those blips, and `selectedIndex`'s clamp against
a transiently-smaller row count fought the user's own arrow-key presses.

**Fix:** Debounce `AppSource`'s `rowsChanged` signal 400ms before triggering
a rebuild, so only the settled count after a churn burst is applied.

## HomeView crash: "Value is undefined and could not be converted to an object"

**Symptom:** Opening Home with pinned/recent apps present intermittently
crashed with a QML `TypeError` in `HomeView.qml`.

**Root cause:** `Menu.qml` originally set `homePinnedCount`/`homeRecentCount`
as two separate `property int`s, both read by `HomeView`'s tile-slicing
logic. Writing them as two sequential property assignments fired two
separate reactive updates — the first with only one of the two counts
updated against the other's still-stale value — and one of those
intermediate states asked the (at that moment incompletely-populated)
`displayModel` for a row index that didn't exist yet.

**Fix:** Combined both counts into one `property var homeSections: {pinned,
recent}` object, written as a single atomic assignment *after* `displayModel`
is fully repopulated, so any reactive read downstream only ever sees a
consistent pair against a fully-populated model. Also hardened
`HomeView.sliceFor()` to clamp against the model's actual current bounds
regardless.

## Pinned/Recent tiles silently never appeared

**Symptom:** Pinning an app (or launching one, for Recent) never made it show
up on Home.

**Root cause:** App rows were only merged into the menu's item tree lazily,
the first time the user visited Apps or Web Apps. Home's Pinned/Recent
sections tried to resolve pinned/recent app ids against that tree
immediately on open, before any such visit had ever happened — so the
lookup always came back empty.

**Fix:** `openExistingMenu()` now eagerly merges app rows on every open. This
is a plain in-memory iteration over `DesktopEntries`' already-resident list
(no filesystem scan), so it's cheap enough to always do.

## Steam category showed as lowercase, and was always empty when opened directly

**Symptom:** Opening a category menu (e.g. `category.Graphics`) via IPC
showed the header as `graphics…` and reported "Nothing here yet" even though
apps in that category existed.

**Root cause:** The route-resolution path (`resolveRoute()`) lowercases
every id it's given, which is correct for JSONC's own lowercase-with-dashes
ids but wrong for a case-sensitive synthetic id like `category.Graphics` —
it came back as `category.graphics`, which matched nothing.

**Fix:** Synthetic menu ids (`recent`, `steam`, `category.<Name>`) now skip
route resolution entirely in `openRoute()` — they have no JSONC alias to
resolve in the first place.

## Sidebar got clipped/force-scrolled despite empty screen space

**Symptom:** Once category destinations made the Sidebar long (up to ~16
entries), it would clip or force a scroll even when the actual content next
to it (a short tile grid, a small category) left most of the card empty.

**Root cause:** The card's height was computed purely from the active view's
own content, with no awareness of how tall the Sidebar itself needed to be.

**Fix:** Added a height floor derived from the Sidebar's actual destination
count, so the card grows to fit the Sidebar when the Sidebar is the taller
of the two.

## The actual "hitching"/hover-flicker bug in this rebuild

**Symptom:** Visible stutter/flicker when hovering Home's tiles; a general
sense that switching between menu pages was janky.

**Investigation:** Instrumented `DesktopEntries.applications.onValuesChanged`
directly. It fired on a steady ~500ms cadence *even at complete idle*, with
the reported app count oscillating in a narrow band — confirmed this was not
Steam (it wasn't running) and not any real file change (no `.desktop` file
anywhere on the system had been touched in over 14 hours). The existing
400ms debounce didn't help, because each firing's gap from the last exceeded
400ms — it fired on schedule every cycle instead of ever coalescing a burst.
Every firing unconditionally rebuilt the menu's item tree and called
`rebuildDisplay()`, which reassigns brand-new JS array objects to Home's
tile-row properties — and a `Repeater` handed a *new* array (as opposed to
an in-place mutation) tears down and recreates every one of its delegates.
Confirmed directly via temporary creation/destruction logging: this was
happening roughly twice a second, continuously, regardless of any user
interaction.

Separately measured actual page-switch cost (Loader swap to fully loaded)
directly: consistently 3-17ms across several transitions — ruling out
"page construction at switch time" as a real cost worth architecting around.

**Fix:** `refreshAppRows()` now fingerprints the incoming set of app ids and
returns immediately if it's identical to the last successful merge, before
touching the item tree or calling `rebuildDisplay()` at all. This closes the
gap a timing-based debounce can't: it doesn't matter how often the signal
fires if nothing it reports has actually changed.

**Remaining known limitation:** ~~the underlying ~500ms `DesktopEntries`
re-emission itself is still unexplained~~ — explained below (2026-09-19); it
is internal to Quickshell, and this fix neutralizes its effect rather than
its cause.

## The ~500ms `DesktopEntries` churn, identified

**Investigation:** Logged the id set on every `onValuesChanged` and diffed
consecutive firings. Each ~500ms cycle is a burst of 10 signals inside 1ms:
the same 5 entries vanish one by one, then reappear one by one (count
84→79→84). `inotifywait` across every applications dir showed zero
filesystem activity while it happened. The 5 flapping ids were
`modrinth-app`, `imv`, `foot`, `mpv`, `com.nvidia.geforcenow` — and listing
every desktop id present in more than one XDG dir produced *exactly* that
set, no more, no fewer.

**Root cause:** Quickshell 0.3.1's `DesktopEntries` periodically drops and
re-adds any entry whose id exists in more than one XDG applications dir (a
`~/.local/share/applications` override shadowing a `/usr/share` or flatpak
copy). What triggers its rescan is still internal to Quickshell; *which*
entries churn, and why the count oscillates by the amount it does, is
confirmed. Not fixable from a plugin, and deleting the overrides isn't a fix.

## Reopening the menu showed the previous session's rows for ~650ms

**Symptom:** Open any submenu (e.g. Style), close, reopen Home: for the
first ~650ms Home drew the *submenu's* rows as tiles (Theme, Background,
Font, ...). Enter inside that window activated the stale row, not the tile
it appeared to be on.

**Root cause:** A regression between two earlier fixes. `openExistingMenu()`
had dropped its own `rebuildDisplay()` because `refreshAppRows()` "already
calls it" — true until the fingerprint fix above gave `refreshAppRows()` an
early return, which is taken on every open after the first. Nothing rebuilt
the display until the async guard batch finished (measured headlessly by
generating the real guard script with node and timing it: 625-735ms).
Confirmed via a screenshot taken 250ms after reopening.

**Fix:** `refreshAppRows()` returns whether it rebuilt; `openExistingMenu()`
rebuilds itself when it didn't — exactly one rebuild either way. Verified by
re-running the same reproduction at the same timing.

## Every app list went empty after a JSONC reload

**Root cause:** `rebuildItemsFromSources()` replaces the item tree with
JSONC-only content (dropping every app row) but left the app-row fingerprint
in place, so the next `refreshAppRows()` saw "same apps as last time" and
never merged them back — Apps, Web Apps, Steam, every category, Pinned and
Recent all stayed empty until an app was (un)installed or the shell
restarted. Triggered by editing the user JSONC, `omarchy menu refresh`, or an
Omarchy update touching the default menu file. Found by code reading (the
pre-fix failure was not reproduced); the fixed build was verified by forcing
a reload with `omarchy menu refresh` and opening a category.

**Fix:** Reset the fingerprint alongside the item tree, and re-merge app rows
immediately if the menu is open.

## Icon index never re-scanned; missing icons stuck forever

**Root cause (two halves):** the rescan sat behind a 750ms debounce
restarted by a signal that arrives every ~500ms (see the churn entry above)
— measured: 40 bursts in 20s, largest gap 534ms, zero rescans after the
startup one. And even had it run, `iconSource()` answers from `iconCache`
first, where an icon not yet indexed at first draw was cached as the generic
fallback with nothing ever evicting it.

**Fix:** The rescan is now driven by `refreshAppRows()` detecting a *real*
change to the app set, not by the raw signal; the cache is dropped when a new
index lands (index first, then cache — the other order re-caches every miss
against the old index). The app-row refresh is also skipped entirely while
the menu is closed, so the churn costs nothing at idle.

## Smaller fixes (2026-09-19)

- The app-row fingerprint covered ids only, so an app update that changed a
  name/icon/category under the same id was ignored until restart. It now
  covers every field a row is drawn from.
- Home's greeting only recomputed when `tileMode` flipped, which a
  close-from-Home/reopen-to-Home cycle never does — "Good morning" could
  persist into the evening. Now recomputed per open.
- Up/Down on Home stepped ±columns through one flat index, but Pinned/
  Recent/More are separate grids with ragged last rows, so crossing a section
  landed in the wrong column. Now section-aware (`MenuData.tileMove()`,
  covered by `tests/menudata.test.js`). PageUp/PageDown clamp instead of
  wrapping past the end back to the top.
- "Open File Location" (and "Copy Launch Command") left the menu open — a
  fullscreen exclusive-focus overlay — so the file manager opened *behind*
  it. Both now dismiss the menu; the copy confirms via a notification.
- Browser-installed PWAs (`google-chrome --app-id=…`) were classified as
  native apps because web-app detection only knew Omarchy's own launcher.
  Now detected for every Chromium-family browser and listed under Web Apps.
- Pin/recent state is written via temp-file + rename instead of a truncating
  redirect, so a crash or two racing saves can't leave an empty file.

## Improvements (2026-09-19)

- Every Sidebar destination keeps the Sidebar and the wide card: searching
  from Home no longer collapses the card from ~700px to 300px on the first
  keystroke, and Settings (the whole `setup` tree) no longer drops the
  Sidebar it was reached from.
- Keyboard shortcuts for the info panel's actions — `Ctrl+P` pin, `Ctrl+O`
  open file location, `Ctrl+C` copy launch command — working on any selected
  app (Home tiles included), with hints shown on the panel's buttons.
  Pinning from Home follows the tile to its new section.
- Web-app globe badge on Home tiles and in mixed lists (Recent, search).
- Friendly category names (Audio & Video, Internet, Games, Utilities); one
  shared category order for the Sidebar and the Apps view's headers.
- Shift+Tab toggles Sidebar focus like Tab.
- Removed dead `RootTileView.qml`; added `tests/menudata.test.js`.
