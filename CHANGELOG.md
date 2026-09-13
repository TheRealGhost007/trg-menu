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

**Remaining known limitation:** the underlying ~500ms `DesktopEntries`
re-emission itself is still unexplained (it appears to be internal to
Quickshell, not this plugin) — this fix neutralizes its effect rather than
its cause.
