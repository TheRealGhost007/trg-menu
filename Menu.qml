import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuData.js" as MenuData

// Root orchestrator: owns the plugin's IPC lifecycle, the shared reactive
// menu state (items/displayModel/activeMenu/filterText/selection), guard
// evaluation, and the card/window chrome. Rendering is delegated to one of
// three view components (RootTileView / ListMenuView / AppBrowserView),
// swapped by `viewLoader` below based on mode — each exists only while it's
// actually the active one, so browsing e.g. Style never instantiates the
// Apps info panel's tree or the app-selection reactivity that goes with it.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon omarchy.menu ...` and close() when hidden.
  property string pendingInitialMenu: "root"

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  property string fontFamily: Style.font.menuFamily
  // JSONC menu definitions. The shell parses both at startup and merges
  // the user file on top of the defaults, so the keybind → IPC → visible
  // path doesn't have to shell out to bash + jq on every open.
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // Sidebar keyboard focus (Home-only). Tab toggles into/out of it; while
  // focused, Up/Down move the highlight and Enter/Right navigate. Any other
  // key drops focus back to the content grid first (see keyCatcher below) so
  // typing to search never leaves a stale sidebar highlight showing.
  property bool sidebarFocused: false
  property int sidebarFocusIndex: 0

  function sidebarIndexFor(menuId) {
    var destinationId = root.sidebarDestinationFor(menuId)
    var destinations = MenuData.homeDestinations()
    for (var i = 0; i < destinations.length; i++) {
      if (destinations[i].id === destinationId) return i
    }
    return 0
  }

  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }
  // Bound to the central [menu] section in shell.toml via Color.qml.
  // Each color already includes its alpha companion (composed in the
  // singleton), so consumers can drop them straight into a Rectangle.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first hidden row stays visible at the fold — enough to
  // read as a cut-off row rather than a bottom border.
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  readonly property int categoryHeaderHeight: Style.space(28)
  property bool searchDivider: false
  property int layoutSerial: 0

  // ---------------------------------------------------------- root tiles
  // Root menu renders as a colorful tile grid (Start-menu style) instead of
  // the usual list — but only at the top level, with no search running and
  // outside dmenu mode. Column/height math stays here (not in
  // RootTileView) because the card's own size depends on it before the
  // view even loads.
  readonly property bool tileMode: !root.dmenuActive && root.activeMenu === "root" && !root.filterText.trim()
  readonly property int tileIdealColumns: 4
  readonly property int tileSize: Style.space(96)
  readonly property int tileSpacing: Style.space(14)
  readonly property int tileCellSize: tileSize + tileSpacing
  readonly property int tileGridWidth: tileIdealColumns * tileCellSize
  // The card's own border eats into the content area on top of contentMargin
  // (see card.contentLeftInset/RightInset below) — account for it explicitly
  // so the grid gets exactly tileGridWidth of content, not a few px less.
  readonly property real cardBorderInsetH: Border.left(root.borderSpec) + Border.right(root.borderSpec)
  // cardWidth (below) still clamps to the screen, so a narrow output fits
  // fewer than tileIdealColumns — derive the real count from the width it
  // actually got, or height/keyboard nav would assume columns never drawn.
  readonly property int sidebarWidth: Style.space(176)
  readonly property int sidebarContentGap: Style.space(18)
  readonly property int tileContentWidth: cardWidth - contentMargin * 2 - cardBorderInsetH - (root.tileMode ? (sidebarWidth + sidebarContentGap) : 0)
  readonly property int tileColumns: root.tileMode ? Math.max(1, Math.floor(tileContentWidth / tileCellSize)) : tileIdealColumns
  readonly property int tileGridHeight: Math.ceil(Math.max(1, displayModel.count) / tileColumns) * tileCellSize

  // Section boundaries within displayModel when tileMode is active: rows
  // [0, pinned) are Pinned, [pinned, +recent) are Recent, the rest are
  // "more" tiles. Recomputed by rebuildDisplay(), and always written as one
  // object in one property write (never two separate int properties) — two
  // sequential writes would fire HomeView's bindings twice, the first time
  // with only one of the two counts updated against the other's stale value,
  // risking an out-of-range ListModel.get() in HomeView.sliceFor().
  property var homeSections: ({ pinned: 0, recent: 0 })
  readonly property int homeMoreCount: Math.max(0, displayModel.count - homeSections.pinned - homeSections.recent)
  // Estimated section-title row height (label + gap before its tile grid) —
  // must stay close to AppTileRow.qml's actual titleText.implicitHeight +
  // Style.space(8), since this feeds the card's own height budget ahead of
  // AppTileRow ever being instantiated. A few px of drift is a cosmetic risk
  // (a hair of clipping/slack), not a functional one.
  readonly property int homeTitleHeight: Style.font.bodySmall + Style.space(10)
  readonly property int homeSectionGap: Style.space(20)

  function homeContentHeightFor(_serial, _sections, _more, _columns) {
    var sections = 0
    var h = 0
    if (root.homeSections.pinned > 0) { h += root.homeTitleHeight + Math.ceil(root.homeSections.pinned / root.tileColumns) * root.tileCellSize; sections++ }
    if (root.homeSections.recent > 0) { h += root.homeTitleHeight + Math.ceil(root.homeSections.recent / root.tileColumns) * root.tileCellSize; sections++ }
    if (root.homeMoreCount > 0) {
      h += (sections > 0 ? root.homeTitleHeight : 0) + Math.ceil(root.homeMoreCount / root.tileColumns) * root.tileCellSize
      sections++
    }
    h += Math.max(0, sections - 1) * root.homeSectionGap
    return Math.max(h, root.tileCellSize)
  }
  readonly property int homeContentHeight: homeContentHeightFor(layoutSerial, homeSections, homeMoreCount, tileColumns)

  ThemePalette { id: themePalette }

  // ------------------------------------------------------------ app browse
  // Apps/Web Apps get a wider card with a side panel showing details for
  // whichever row is highlighted. Every other submenu, dmenu mode, and the
  // root tile grid are unaffected.
  // "recent" is a synthetic menu id (no JSONC entry, no provider) — it reuses
  // AppBrowserView exactly like apps/webapps, just fed a recency-ordered row
  // set built in rebuildDisplay() instead of the full alphabetical app list.
  readonly property bool appBrowseMode: !root.dmenuActive && (root.activeMenu === "apps" || root.activeMenu === "webapps" || root.activeMenu === "recent")
  readonly property int browseListWidth: Style.space(300)
  readonly property int infoPanelWidth: Style.space(260)
  readonly property int browseGap: Style.space(14)
  // The persistent nav shows on Home and while browsing Apps/Web Apps/
  // Recent — every destination it links to — but not in a plain drilldown
  // submenu (Trigger/Style/Setup/...) or dmenu, which keep today's simpler
  // header+list card.
  readonly property bool sidebarMode: root.tileMode || root.appBrowseMode

  // Named *Service/*Store, not appSource/pinStore/recentStore — a component
  // property sharing the instance's own name silently self-references instead
  // of resolving to this outer one when wired into a view (see project memory
  // on AppBrowserView's `appSource` property collision).
  PinStore { id: pinStoreService }
  RecentStore { id: recentStoreService }
  AppSource { id: appSourceService; omarchyPath: root.omarchyPath; recentStore: recentStoreService }

  // Debounced: some environments (Steam is a known offender — it rewrites
  // its games' .desktop files repeatedly in the background) make
  // DesktopEntries.applications fire changed signals in a tight, sustained
  // loop, with the reported entry count fluctuating by a couple either way
  // each time. Rebuilding immediately on every one of those blips used to
  // reset selectedIndex's clamp against a briefly-smaller count, which
  // fought with the user's own Down presses and pinned the cursor at
  // whatever index the fluctuation's lower bound happened to land on.
  // Waiting for the churn to go quiet for a moment fixes that without
  // losing real updates (an actual install/uninstall still lands, just
  // slightly after the fact).
  Connections {
    target: appSourceService
    function onRowsChanged() {
      if (root.providersLoaded["apps"] || root.providersLoaded["webapps"] || root.providersLoaded["recent"]) appRowsRefreshDebounce.restart()
    }
  }

  Timer {
    id: appRowsRefreshDebounce
    interval: 400
    onTriggered: root.refreshAppRows()
  }

  function refreshAppRows() {
    // The debounce upstream (appRowsRefreshDebounce) already stops a Steam
    // churn burst from rebuilding on every blip; this covers the case it
    // doesn't: a single settled rebuild (a real install/uninstall, Steam or
    // otherwise) still reshuffles alphabetical positions, and rebuildDisplay()
    // only clamps selectedIndex numerically — it doesn't re-find the same
    // row. Without this, browsing Apps while an unrelated app installs could
    // silently move your cursor onto a different app. Category-grouping
    // Steam (see the "apps" sort above) already limits *how far* such a
    // reshuffle can reach; this closes the remaining gap by id instead of
    // index.
    var selectedId = (root.cursorActive && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count)
      ? displayModel.get(root.selectedIndex).itemId : ""

    var rows = appSourceService.buildRows()
    var merged = MenuData.mergeAppRows(root.items, root.itemOrder, rows.apps.concat(rows.webapps))
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) {
      root.rebuildDisplay()
      if (selectedId) root.restoreSelectionById(selectedId)
    }
  }

  // Re-finds a row by itemId after a rebuild and restores selectedIndex to
  // its new position. A no-op (falls through to rebuildDisplay's own clamp)
  // if the row no longer exists — e.g. the selected app was just uninstalled.
  function restoreSelectionById(itemId) {
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).itemId === itemId) {
        root.selectedIndex = i
        return
      }
    }
  }

  property int cardWidth: Math.min(root.tileMode ? Math.ceil(sidebarWidth + sidebarContentGap + tileGridWidth + contentMargin * 2 + cardBorderInsetH)
      : root.appBrowseMode ? Math.ceil(sidebarWidth + sidebarContentGap + browseListWidth + browseGap + infoPanelWidth + contentMargin * 2 + cardBorderInsetH)
      : (root.dmenuActive ? Style.space(root.dmenuWidth) : ((root.activeMenu === "trigger.capture.screenrecord" || root.activeMenu === "style.font") ? Style.space(520) : Style.space(300))), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: root.tileMode ? homeContentHeight : (root.dmenuActive ? dmenuRowListHeight(layoutSerial, displayModel.count, filterText) : rowListHeight(layoutSerial, displayModel.count, filterText, searchDivider))
  property int cardHeight: root.dmenuActive
    ? Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)
    : Math.min(contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight, panel.height - Style.gapsOut * 2)

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined) {
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(selection) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return

    Util.execDetached(command)
  }

  // Menu rows only surface their detail while a search is narrowing them;
  // dmenu rows carry caller-supplied subtext that must always be visible.
  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Height the card can devote to rows before running off the screen — or
  // past the frozen top edge once a search has pinned the card in place.
  // Uses panel.cardTop rather than effectiveCardTop: the centered top is
  // derived from the card height, which this value feeds.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var available = panel.height - top - Style.gapsOut - root.contentMargin * 2 - root.headerHeight - root.contentSpacing
    // The starting menu sets the ceiling along with the offset: drilling into
    // a longer submenu scrolls behind the fold instead of growing the card.
    if (panel.maxRowsHeight >= 0) available = Math.min(available, panel.maxRowsHeight)
    // A card that swallows the whole screen reads as a page, not a menu —
    // except Apps/Web Apps, which routinely hold far more entries than any
    // other menu and benefit from showing more of the list at once.
    var capFraction = root.appBrowseMode ? 0.88 : 0.7
    return Math.min(available, Math.round(panel.height * capFraction))
  }

  // When every row fits, the list gets its full height. When they don't,
  // the card must end mid-row: a clipped row is what tells the eye there is
  // more below the fold, so never come out even on a row boundary.
  function foldedListHeight(totals, available) {
    var count = totals.length
    if (count === 0) return root.baseRowHeight
    if (totals[count - 1] <= available) return totals[count - 1]

    var peek = root.rowPeek
    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + peek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)

    return totals[full - 1] + root.rowSpacing + peek
  }

  function rowListHeight(_serial, _count, _filter, _divider) {
    if (displayModel.count === 0) return root.baseRowHeight

    var totals = []
    var total = 0
    var previousSection = ""

    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      // A search's drilldown divider and an Apps category header are both
      // "entering a new section" — the same displayModel.section field, just
      // used for two different purposes depending on the view (search vs.
      // plain browse never happen at once, so there's no ambiguity).
      if (row.section !== previousSection) {
        if (row.section === "drilldown") total += root.dividerHeight
        else if (row.section) total += root.categoryHeaderHeight
      }
      total += root.rowHeightForDetail(row.detail)
      previousSection = row.section
      totals.push(total)
    }

    return foldedListHeight(totals, availableRowsHeight())
  }

  function dmenuRowListHeight(_serial, _count, _filter) {
    if (root.mode === "input") return 0
    if (displayModel.count === 0) return root.baseRowHeight

    var available = availableRowsHeight()
    if (root.dmenuMaxHeight > 0) available = Math.min(available, Style.space(root.dmenuMaxHeight))

    var totals = []
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      if (i > 0) total += root.rowSpacing
      total += root.rowHeightForDetail(displayModel.get(i).detail)
      totals.push(total)
    }

    return foldedListHeight(totals, available)
  }

  // Home's greeting header. Recomputed whenever tileMode flips true (the
  // property read makes it a binding dependency), which covers every menu
  // open/close — freshness beyond that isn't worth tracking a clock for.
  function greetingText() {
    var hour = new Date().getHours()
    var part = hour < 5 ? "night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : hour < 21 ? "evening" : "night"
    var user = Quickshell.env("USER") || Quickshell.env("LOGNAME") || "there"
    return "Good " + part + ", " + user
  }

  function item(id) {
    return root.items[id] || null
  }

  // Pinned/recent store rows only, ever: a bare desktop appId (e.g.
  // "firefox"), not a full item id. Apps and webapps share the same
  // namespace, so check both parents; returns null (silently) for an
  // uninstalled/renamed app rather than throwing — pin/recent lists are
  // allowed to hold a stale id that simply never renders.
  function appItemForId(appId) {
    var id = String(appId || "")
    if (!id) return null
    return root.items["apps." + id] || root.items["webapps." + id] || null
  }

  // ------------------------------------------------------------------
  // JSONC → normalized item array. Mirrors the bash bin's jq pipeline so
  // the on-disk authoring format stays untouched.
  // ------------------------------------------------------------------

  function stripJsonc(raw) {
    return MenuData.stripJsonc(raw)
  }

  function normalizeAliases(value) {
    return MenuData.normalizeAliases(value)
  }

  function normalizeItem(id, raw) {
    return MenuData.normalizeItem(id, raw)
  }

  function parseMenuJsonc(raw) {
    return MenuData.parseMenuJsonc(raw)
  }

  // Merge defaults + user extension. Later entries override earlier ones
  // on a per-key basis (so the user can tweak label/icon/action without
  // re-declaring the whole row).
  function rebuildItemsFromSources() {
    var mergedMenu = MenuData.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rowsLoaded = true
    root.evaluateGuards()
    if (root.opened) {
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim()) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  // Each known provider is a tiny bash one-liner that enumerates a list and
  // emits one tab-delimited row per item: `label\tvalue\tcurrent`. The shell
  // turns those into menu items children of `menuId`. A `volatile` provider
  // re-runs every time its submenu is entered, so a font installed since the
  // shell started shows up without restarting it.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function slugify(value) {
    return MenuData.slugify(value)
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps" || entry.provider === "webapps") {
      root.providersLoaded[id] = true
      root.refreshAppRows()
      return
    }
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      // Distinct values can slugify alike — Fira Code and Fira-Code both give
      // fira-code — and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }
    var merged = MenuData.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return

    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue

      root.startProviderForMenu(id)
      return
    }
  }

  // Entering a submenu is the one moment a volatile list is worth paying for
  // again: it may have been reshaped by the last pick from it. Search doesn't
  // invalidate, or every keystroke would restart the same enumeration.
  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    // Recent has no JSONC entry/provider of its own — it just needs the same
    // native app rows apps/webapps load, so opening Recent directly (without
    // ever visiting Apps first) still resolves real entries.
    if (id === "recent") {
      if (!root.providersLoaded["recent"]) {
        root.providersLoaded["recent"] = true
        root.providersLoaded["apps"] = true
        root.providersLoaded["webapps"] = true
        root.refreshAppRows()
      }
      return
    }

    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return

    // Native providers don't touch providerProc, so they never need to queue.
    if (entry.provider === "apps" || entry.provider === "webapps") {
      root.startProviderForMenu(id)
      return
    }

    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }

    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    var active = root.item(root.activeMenu) ? root.activeMenu : "root"

    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue
      if (active !== "root" && entry.id !== active && !root.isDescendantOf(entry.id, active)) continue

      root.loadProviderForMenu(entry.id)
    }
  }

  function depthFor(id) {
    return MenuData.depthFor(root.items, id)
  }

  function pathFor(id) {
    return MenuData.pathFor(root.items, id)
  }

  function parentPathFor(id) {
    return MenuData.parentPathFor(root.items, id)
  }

  function isDescendantOf(id, ancestorId) {
    return MenuData.isDescendantOf(root.items, id, ancestorId)
  }

  function childCount(id) {
    return MenuData.childCount(root.items, root.itemOrder, id)
  }

  // Guarded items are hidden when their `when:` evaluates false. Static
  // submenus are also hidden when none of their descendants are visible;
  // provider-backed menus stay visible because their rows load on demand.
  function isVisible(entry) {
    return MenuData.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }

  // Label with the ✓ marker baked in when `checked:` evaluated truthy.
  function labelFor(entry) {
    return MenuData.labelFor(entry, root.checkedResults)
  }

  function searchableToken(value) {
    return MenuData.searchableToken(value)
  }

  function leafIdFor(id) {
    return MenuData.leafIdFor(id)
  }

  function nameSearchText(entry) {
    return MenuData.nameSearchText(entry)
  }

  function termInSearchWords(term, text) {
    return MenuData.termInSearchWords(term, text)
  }

  function descriptionTextMatches(query, text) {
    return MenuData.descriptionTextMatches(query, text)
  }

  function matchesQuery(entry, query) {
    return MenuData.matchesQuery(entry, query, root.isVisible(entry))
  }

  function searchScore(entry, query) {
    return MenuData.searchScore(root.items, entry, query)
  }

  function displayRow(entry, detail, score, section) {
    return MenuData.displayRow(root.items, root.itemOrder, root.checkedResults, entry, detail, score, section)
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()
    root.searchDivider = false

    if (root.mode === "input") {
      layoutSerial += 1
      return
    }

    var query = root.filterText.trim().toLowerCase()
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      // An option is "<label>", "<glyph>\t<label>", or
      // "<glyph>\t<label>\t<subtext>". The glyph never comes back with the
      // selection; the subtext renders under the label, filters alongside it,
      // and returns with the selection as a stable key for same-named rows.
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      displayModel.append({
        itemId: "dmenu." + i,
        kind: "dmenu",
        icon: icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: ""
      })
    }

    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function rebuildDisplay() {
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    displayModel.clear()

    if (!root.rowsLoaded) return

    var active = (root.activeMenu === "recent" || root.item(root.activeMenu)) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()
    root.searchDivider = false

    if (query && active === "recent") {
      // Recent isn't a real parent in the items graph, so the generic
      // isDescendantOf() search below always comes back empty for it —
      // filter the same recency-ordered id list directly instead.
      var recentQuery = query.toLowerCase()
      var recentSearchIds = recentStoreService.recentIds
      for (var rq = 0; rq < recentSearchIds.length; rq++) {
        var recentQueryEntry = root.appItemForId(recentSearchIds[rq])
        if (recentQueryEntry && root.matchesQuery(recentQueryEntry, recentQuery))
          rows.push(root.displayRow(recentQueryEntry, recentQueryEntry.description, rq))
      }
    } else if (query) {
      var currentRows = []
      var drilldownRows = []

      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!root.isDescendantOf(entry.id, active)) continue
        if (!root.matchesQuery(entry, query)) continue

        var detail = root.parentPathFor(entry.id)
        var row = root.displayRow(entry, detail, root.searchScore(entry, query))
        if (entry.parent === active) currentRows.push(row)
        else drilldownRows.push(row)
      }

      var searchSort = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return a.path.localeCompare(b.path)
      }

      currentRows.sort(searchSort)
      drilldownRows.sort(searchSort)
      root.searchDivider = currentRows.length > 0 && drilldownRows.length > 0
      if (root.searchDivider) {
        for (var d = 0; d < drilldownRows.length; d++) drilldownRows[d].section = "drilldown"
      }
      rows = currentRows.concat(drilldownRows)
    } else if (active === "recent") {
      // Synthetic menu, not a real JSONC id — no siblings/guards apply.
      // Order is recency, never re-sorted.
      var recentIds = recentStoreService.recentIds
      for (var r = 0; r < recentIds.length; r++) {
        var recentEntry = root.appItemForId(recentIds[r])
        if (recentEntry) rows.push(root.displayRow(recentEntry, recentEntry.description, r))
      }
    } else {
      var siblings = []
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        // Apps/Web Apps/Settings get their own Sidebar destination in Home —
        // omitting them here avoids listing the same destination twice.
        if (root.tileMode && (child.id === "apps" || child.id === "webapps" || child.id === "setup")) continue
        if (!root.isVisible(child)) continue
        siblings.push(child)
      }

      // An explicit "sort" in JSONC wins; everything else keeps the order it
      // was declared in (defaults, then the user extension file). Apps/Web
      // Apps are force-alphabetized below regardless, so skip this pass for
      // them rather than sort twice.
      if (active !== "apps" && active !== "webapps") {
        var naturalIndex = ({})
        for (var s = 0; s < siblings.length; s++) naturalIndex[siblings[s].id] = s
        siblings.sort(function(a, b) {
          var aKey = (a.sort !== null && a.sort !== undefined) ? a.sort : (1000000 + naturalIndex[a.id])
          var bKey = (b.sort !== null && b.sort !== undefined) ? b.sort : (1000000 + naturalIndex[b.id])
          if (aKey !== bKey) return aKey - bKey
          return naturalIndex[a.id] - naturalIndex[b.id]
        })
      }

      for (var sIdx = 0; sIdx < siblings.length; sIdx++) {
        var sibling = siblings[sIdx]
        rows.push(root.displayRow(sibling, sibling.description, sibling.order))
      }

      // DesktopEntries can reorder its values when an application starts.
      // Keep the Apps/Web Apps menus alphabetical independently of that.
      // Apps additionally group by category first (Steam's per-game
      // shortcuts always last — see AppSource.categoryFor()), so a Steam
      // install/uninstall reshuffling that one group never moves the index
      // of an unrelated app that happens to sort near it alphabetically.
      // Recent/Web Apps stay flat — recency order and a single flat list
      // respectively are the point of those views. One comparator (not a
      // category pass after an alphabetical pass) so correctness never
      // depends on Array.sort being stable.
      if (active === "apps") {
        for (var ci = 0; ci < rows.length; ci++) {
          var catItem = root.item(rows[ci].itemId)
          rows[ci].section = (catItem && catItem.category) || "Other"
        }
      }
      if (active === "apps" || active === "webapps") {
        rows.sort(function(a, b) {
          if (active === "apps" && a.section !== b.section) {
            if (a.section === "Steam") return 1
            if (b.section === "Steam") return -1
            return a.section < b.section ? -1 : 1
          }
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          var aId = String(a.itemId || "")
          var bId = String(b.itemId || "")
          if (aId < bId) return -1
          if (aId > bId) return 1
          return 0
        })
      }
    }

    // Home prepends Pinned then Recent app tiles ahead of the "more" tiles
    // built above — one flat displayModel/selectedIndex, as everywhere else
    // in this file, with the section boundaries recorded for HomeView to
    // draw section headers/rows at the right offsets.
    //
    // homePinnedCount/homeRecentCount are only assigned *after* displayModel
    // is fully repopulated below (never here) even though the counts are
    // known now: each is a plain `property int` on root, so writing it fires
    // HomeView's pinnedCount/recentCount bindings — and their sliceFor()
    // dependency — synchronously, mid-function, however displayModel.clear()
    // above has already run and the new rows aren't appended yet. Assigning
    // a non-zero count against that briefly-empty/stale model would have
    // sliceFor() call ListModel.get() out of range.
    var nextHomePinnedCount = 0
    var nextHomeRecentCount = 0
    if (root.tileMode && !query) {
      var pinnedRows = []
      var pinnedIds = pinStoreService.pinnedIds
      var pinnedSet = ({})
      for (var p = 0; p < pinnedIds.length; p++) {
        var pinnedEntry = root.appItemForId(pinnedIds[p])
        if (!pinnedEntry) continue
        pinnedSet[pinnedIds[p]] = true
        pinnedRows.push(root.displayRow(pinnedEntry, pinnedEntry.description, p))
      }
      var homeRecentRows = []
      var homeRecentIds = recentStoreService.recentIds
      for (var hr = 0; hr < homeRecentIds.length; hr++) {
        if (pinnedSet[homeRecentIds[hr]]) continue
        var homeRecentEntry = root.appItemForId(homeRecentIds[hr])
        if (!homeRecentEntry) continue
        homeRecentRows.push(root.displayRow(homeRecentEntry, homeRecentEntry.description, hr))
      }
      nextHomePinnedCount = pinnedRows.length
      nextHomeRecentCount = homeRecentRows.length
      rows = pinnedRows.concat(homeRecentRows, rows)
    }

    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])
    // One write, after displayModel already holds every row these counts
    // describe — see the comment on the homeSections property declaration.
    root.homeSections = { pinned: nextHomePinnedCount, recent: nextHomeRecentCount }
    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  // Dispatches to whichever view is currently loaded — RootTileView never
  // needs this (the grid sizes to fit every root item, so nothing scrolls)
  // and simply doesn't expose the function, which the check below handles.
  function revealCursor() {
    if (viewLoader.item && typeof viewLoader.item.revealCursor === "function") viewLoader.item.revealCursor()
  }

  function select(delta) {
    if (displayModel.count === 0) return

    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    revealCursor()
  }

  function setFilter(nextFilter) {
    panel.freezeCardTop()
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = root.mode !== "input"
    root.disarmPointer()
    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    panel.freezeCardTop()
    root.sidebarFocused = false
    if (id !== "recent" && !root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    if (fromPointer) pointerGate.allowInitialSample()
    else root.disarmPointer()
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false

    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }

    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      return
    }

    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      applySerial = requestSerial
      opened = false
      filterText = ""
      appSourceService.launch(appId)
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    appSourceService.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }

    applySerial = requestSerial
    opened = false
    filterText = ""
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = (initialMenu === "recent" || root.item(initialMenu)) ? initialMenu : "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = true
    root.sidebarFocused = false
    root.disarmPointer()
    root.evaluateGuards()
    opened = true
    // Home's Pinned/Recent rows need real app rows resolvable immediately,
    // not only after the user has drilled into Apps/Web Apps at least once.
    // This is a plain in-memory merge of DesktopEntries' already-resident
    // list (see AppSource.buildRows()) — no filesystem scan, so it's cheap
    // enough to just always do on open rather than only when non-empty.
    // refreshAppRows() already calls rebuildDisplay() once opened is true
    // (set above) — don't call it again here, a second back-to-back
    // clear()+rebuild was observed to transiently desync HomeView's
    // listModel.count-driven moreCount from its still-stale pinnedCount/
    // recentCount mid-cascade.
    root.providersLoaded["apps"] = true
    root.providersLoaded["webapps"] = true
    root.refreshAppRows()
    invalidateVolatileProvider(activeMenu)
    loadProviderForMenu(activeMenu)

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select"))
    dmenuOptions = Array.isArray(payload.options) ? payload.options : []
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    dmenuWidth = Math.max(1, Number(payload.width || 300))
    dmenuMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    activeMenu = "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = mode !== "input"
    root.sidebarFocused = false
    root.disarmPointer()
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  ListModel { id: displayModel }

  // ----------------------------------------------------------- route surface
  //
  // The menu is opened through the standard plugin lifecycle:
  // `omarchy-shell shell summon omarchy.menu '{"menu":"system"}'`.
  // Callers may pass a real id (`system`, `setup.power`) or an alias declared
  // in JSONC (`power`, `reminder-set`). Unknown strings fall through to the
  // id-as-route behavior so misspellings still attempt to open the literal id.
  function resolveRoute(input) {
    return MenuData.resolveRoute(root.items, root.itemOrder, input)
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    // If the resolved id is an action (i.e. the user invoked an alias for
    // a leaf, e.g. `omarchy menu summon screenrecord-stop`), run it directly
    // instead of opening an action with no children.
    if (entry && entry.kind === "action" && entry.action) {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    // If it's a link (a redirect to another menu), follow the link.
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.pendingInitialMenu = id
    root.openExistingMenu(id)
    return "ok"
  }

  // Which Sidebar destination should read as "active" for a given activeMenu.
  // Settings stays highlighted for any submenu underneath it (e.g. browsing
  // Setup > Power), not just the exact "setup" id.
  function sidebarDestinationFor(menuId) {
    if (menuId === "recent" || menuId === "apps" || menuId === "webapps") return menuId
    if (menuId === "setup" || root.isDescendantOf(menuId, "setup")) return "setup"
    return "root"
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim()) root.loadProvidersForSearch()
      }
      root.startNextProvider()
    }
  }

  Process {
    id: resultProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // The JSONC sources are watched so live edits to the default file (or the
  // user extension at ~/.config/omarchy/extensions/omarchy-menu.jsonc) take
  // effect without restarting the shell.
  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // ---------------------------------------------------------------- guards
  //
  // `when:` (visibility) and `checked:` (✓ marker) are bash expressions the
  // shell wasn't allowed to evaluate before the perf rewrite. Now the shell
  // batches them into one bash subprocess per (re)load so the open path
  // never has to wait on them.

  property var whenResults: ({})       // id → true|false (allow visibility)
  property var checkedResults: ({})    // id → true|false (show ✓)
  property bool guardsPending: false

  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite
    // the first: it would throw away the lines already read and never start.
    // The surviving tail then lands as the whole answer, and every id lost
    // with it goes back to showing, since a `when:` only hides on an explicit
    // false. Wait for the run in flight and evaluate once it lands instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuData.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered shows.
      // Keep the last complete set rather than let a half-read one through.
      // A signal leaves the exit code at 0, so the status is what tells us.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.opened) root.rebuildDisplay()
      // Run the evaluation that had to stand aside. Deferred by a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }
  PanelWindow {
    id: panel
    visible: root.opened && root.rowsLoaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The card opens centered exactly as always. The first search keystroke
    // or submenu move freezes the top line where it currently sits — from
    // then on the card grows and shrinks downward instead of re-centering
    // on every resize, which made the menu jump around. The rows height is
    // frozen at the same moment, so the starting menu also caps how tall the
    // card may grow from there. Closing unfreezes both.
    property int cardTop: -1
    property int maxRowsHeight: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    function freezeCardTop() {
      if (visible && cardTop < 0) {
        cardTop = effectiveCardTop
        maxRowsHeight = root.visibleRowsHeight
      }
    }
    onVisibleChanged: if (!visible) { cardTop = -1; maxRowsHeight = -1 }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - panel.effectiveCardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.effectiveCardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (root.sidebarMode && event.key === Qt.Key_Tab) {
            root.sidebarFocused = !root.sidebarFocused
            if (root.sidebarFocused) root.sidebarFocusIndex = root.sidebarIndexFor(root.activeMenu)
            event.accepted = true
            return
          }

          if (root.sidebarFocused) {
            var homeDestinations = MenuData.homeDestinations()
            if (event.key === Qt.Key_Up) {
              root.sidebarFocusIndex = (root.sidebarFocusIndex - 1 + homeDestinations.length) % homeDestinations.length
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Down) {
              root.sidebarFocusIndex = (root.sidebarFocusIndex + 1) % homeDestinations.length
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
              root.sidebarFocused = false
              root.setActiveMenu(homeDestinations[root.sidebarFocusIndex].id, true)
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left) {
              root.sidebarFocused = false
              event.accepted = true
              return
            }
            // Any other key (typing to search, PageUp/Down, Delete, ...):
            // drop sidebar focus and fall through to the normal handling
            // below, so it never lingers highlighted once the user moves on.
            root.sidebarFocused = false
          }

          if (event.key === Qt.Key_Delete) {
            root.requestDeleteSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.cancel()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (root.tileMode && event.key === Qt.Key_Left) {
            root.select(-1)
            event.accepted = true
          } else if (root.tileMode && event.key === Qt.Key_Right) {
            root.select(1)
            event.accepted = true
          } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && !root.filterText) {
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(root.tileMode ? -root.tileColumns : -1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(root.tileMode ? root.tileColumns : 1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
            if (root.dmenuActive) {
              if (root.mode === "input") root.applyDmenuSelection(root.filterText)
              else if (displayModel.count > 0) root.activateIndex(root.cursorActive ? root.selectedIndex : 0)
            } else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm

          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to uninstall " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Uninstall"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }

      Row {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.sidebarMode ? root.sidebarContentGap : 0

        // Persistent nav on Home and while browsing Apps/Web Apps/Recent.
        // Plain submenus and dmenu keep today's simple header+list card.
        Sidebar {
          id: sidebar
          visible: root.sidebarMode
          width: root.sidebarMode ? root.sidebarWidth : 0
          height: parent.height
          activeDestination: root.sidebarDestinationFor(root.activeMenu)
          focused: root.sidebarFocused
          focusedIndex: root.sidebarFocusIndex
          foreground: root.foreground
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onNavigate: function(id) { root.sidebarFocused = false; root.setActiveMenu(id, true) }
        }

        Column {
          width: parent.width - (root.sidebarMode ? (root.sidebarWidth + root.sidebarContentGap) : 0)
          height: parent.height
          spacing: root.contentSpacing

          Rectangle {
            width: parent.width
            height: root.headerHeight
            radius: root.cornerRadius
            color: "transparent"

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              // Accent-tinted monogram in place of a profile photo — no
              // reliable avatar-photo backend exists on this system without
              // a new dependency, see the redesign plan.
              Rectangle {
                visible: root.tileMode
                width: Style.space(28)
                height: Style.space(28)
                radius: width / 2
                color: themePalette.accent
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: (Quickshell.env("USER") || Quickshell.env("LOGNAME") || "?").charAt(0).toUpperCase()
                  color: "#ffffff"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.Bold
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width - (root.tileMode ? Style.space(38) : 0)
                anchors.verticalCenter: parent.verticalCenter
                text: root.filterText || (root.dmenuActive ? (root.dmenuPrompt + "…") : (root.tileMode ? root.greetingText() : ((root.activeMenu === "recent" ? "Recent" : (root.item(root.activeMenu) ? (root.item(root.activeMenu).title || root.item(root.activeMenu).label) : "Go")) + "…")))
                color: root.foreground
                opacity: root.filterText ? 1 : 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }
            }
          }

          Item {
            width: parent.width
            height: root.visibleRowsHeight

            // Exactly one of the three views ever exists — swapped whenever
            // the mode that selects between them changes, not per keystroke
            // (tileMode/appBrowseMode/mode:"input" all only change on
            // navigation, not on selection or search-text edits).
            Loader {
              id: viewLoader
              anchors.fill: parent
              active: root.rowsLoaded && !(root.dmenuActive && root.mode === "input")
              sourceComponent: root.tileMode ? tileViewComponent
                : root.appBrowseMode ? appBrowserViewComponent
                : listViewComponent
            }
          }

          Item {
            width: parent.width
            height: 0
          }
        }
      }
    }
  }

  Component {
    id: tileViewComponent
    HomeView {
      listModel: displayModel
      pinnedCount: root.homeSections.pinned
      recentCount: root.homeSections.recent
      columns: root.tileColumns
      cellSize: root.tileCellSize
      tileSizePx: root.tileSize
      layoutSerial: root.layoutSerial
      cursorActive: root.cursorActive
      selectedIndex: root.selectedIndex
      cornerRadius: root.cornerRadius
      fontFamily: root.fontFamily
      foreground: root.foreground
      appTileSurface: themePalette.surfaceElevated
      selectedBorderSpec: root.selectedBorderSpec
      colorFor: function(index) { return themePalette.colorFor(index) }
      appIconSource: function(icon) { return appSourceService.iconSource(icon) }
      onHoverSelect: function(index, item, mouse) { root.selectFromPointer(index, item, mouse) }
      onActivate: function(index) {
        root.cursorActive = true
        root.selectedIndex = index
        root.activateIndex(index, true)
      }
    }
  }

  Component {
    id: listViewComponent
    ListMenuView {
      model: displayModel
      cursorActive: root.cursorActive
      selectedIndex: root.selectedIndex
      filterText: root.filterText
      dmenuActive: root.dmenuActive
      background: root.background
      foreground: root.foreground
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      selectedBorderSpec: root.selectedBorderSpec
      cornerRadius: root.cornerRadius
      fontFamily: root.fontFamily
      rowReservedBorderLeft: root.rowReservedBorderLeft
      rowReservedBorderRight: root.rowReservedBorderRight
      rowSpacing: root.rowSpacing
      dividerHeight: root.dividerHeight
      categoryHeaderHeight: root.categoryHeaderHeight
      baseRowHeight: root.baseRowHeight
      detailRowHeight: root.detailRowHeight
      onHoverSelect: function(index, item, mouse) { root.selectFromPointer(index, item, mouse) }
      onActivate: function(index) {
        root.cursorActive = true
        root.selectedIndex = index
        root.activateIndex(index, true)
      }
    }
  }

  Component {
    id: appBrowserViewComponent
    AppBrowserView {
      model: displayModel
      cursorActive: root.cursorActive
      selectedIndex: root.selectedIndex
      filterText: root.filterText
      layoutSerial: root.layoutSerial
      background: root.background
      foreground: root.foreground
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      selectedBorderSpec: root.selectedBorderSpec
      cornerRadius: root.cornerRadius
      fontFamily: root.fontFamily
      rowReservedBorderLeft: root.rowReservedBorderLeft
      rowReservedBorderRight: root.rowReservedBorderRight
      rowSpacing: root.rowSpacing
      dividerHeight: root.dividerHeight
      categoryHeaderHeight: root.categoryHeaderHeight
      baseRowHeight: root.baseRowHeight
      detailRowHeight: root.detailRowHeight
      listWidth: root.browseListWidth
      panelWidth: root.infoPanelWidth
      gap: root.browseGap
      appSource: appSourceService
      pinStore: pinStoreService
      itemFor: function(id) { return root.item(id) }
      onHoverSelect: function(index, item, mouse) { root.selectFromPointer(index, item, mouse) }
      onActivate: function(index) {
        root.cursorActive = true
        root.selectedIndex = index
        root.activateIndex(index, true)
      }
      onUninstallRequested: root.requestDeleteSelected()
    }
  }
}
