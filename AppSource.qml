import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Everything app-related for the menu, in one place: reading installed
// apps, native-vs-webapp classification, icon resolution (cached), launch/
// uninstall actions, and the async file-location lookup used by the info
// panel. One instance lives in Menu.qml for the plugin's whole lifetime
// (Home's Pinned/Recent tiles and root-level search need app rows too, not
// just AppBrowserView) — so anything in here has to be free while idle.
//
// Reads Quickshell's DesktopEntries singleton directly rather than through
// the shell-provided AppLibrary proxy (shell.appLibrary): on this Omarchy
// build, shell.pluginShellFor()'s scoped-API path
// (createScopedPluginShell -> pluginShellApiComponent.createObject) comes
// back with a null `shell`/`appLibrary` for a cloned menu+bar-widget
// plugin, so a clone's Apps submenu is always empty through that path — a
// gap in shell.qml's third-party plugin scoping, not fixable from a
// plugin (that file lives under /usr/share and can't be edited).
// DesktopEntries has no such scoping, so reading it directly sidesteps
// the gap entirely.
Item {
  id: root

  required property string omarchyPath
  // Set by Menu.qml to the shared RecentStore instance. Optional so this file
  // stays testable/usable standalone; launch() just skips recording if unset.
  property var recentStore: null

  // ---------------------------------------------------------- hidden apps
  // Same curated "don't clutter the launcher with config utilities" list
  // the stock Apps menu applies (avahi-discover, cups, kvantummanager, etc).
  property var hiddenIds: ({})

  function parseHiddenIds(raw) {
    var next = ({})
    var lines = String(raw || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = lines[i].trim()
      if (id.length > 0 && id.charAt(0) !== "#") next[id] = true
    }
    return next
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: { root.hiddenIds = root.parseHiddenIds(text()); root.rowsChanged() }
    onLoadFailed: root.hiddenIds = ({})
    onFileChanged: reload()
  }

  // ------------------------------------------------------------- webapps
  // Omarchy webapps are ordinary .desktop entries whose Exec runs
  // omarchy-launch-webapp/omarchy-webapp-handler (see omarchy-webapp-install
  // and the stock "remove.webapp" when: clause, which detects them the same
  // way from bash). Splitting on that keeps native apps and browser-backed
  // webapps in separate submenus instead of interleaved alphabetically.
  //
  // The other kind is a PWA installed from the browser's own "Install app"
  // button: Chromium-family browsers (Chrome, Chromium, Brave, Edge, Vivaldi)
  // all write a chrome-<id>-<Profile>.desktop whose Exec is the browser
  // binary with --app-id=<32 chars a-p>. Just as much a web app, but the
  // Omarchy-launcher test alone filed these under Apps (found on this machine:
  // GitHub, Claude, VirusTotal), so they got no web-app badge and sat among
  // native apps. The id's fixed shape keeps this from catching an ordinary
  // app that happens to take some other --app-id flag.
  function isWebapp(entry) {
    var exec = String((entry && entry.execString) || "")
    return /^\s*(omarchy-launch-webapp|omarchy-webapp-handler)\b/.test(exec)
      || /\s--app-id=[a-p]{32}(\s|$)/.test(exec)
  }

  // Steam writes/rewrites one .desktop file per installed game, repeatedly,
  // in the background — the confirmed cause of a past hitching incident (see
  // the appRowsRefreshDebounce comment in Menu.qml). Detecting these routes
  // them to their own "steam" parent entirely, split out at buildRows() the
  // same way Web Apps already are — not a sub-group inside Apps. That way a
  // game being installed/removed can only reshuffle the Steam list itself;
  // it can never touch an unrelated app's position/index in Apps at all.
  // `steam://rungameid/` is the exec pattern Steam's own generated shortcuts
  // use; the Steam client's own launcher entry has no rungameid and stays a
  // normal app.
  function isSteamApp(entry) {
    return /steam:\/\/rungameid\//i.test(String((entry && entry.execString) || ""))
  }

  // First recognized top-level freedesktop category, e.g. "Game" or
  // "Development" — skips qualifiers like "GTK"/"Qt"/"X-*" that mean nothing
  // to a user. Falls back to "Other" for an app that declares none. Only
  // ever called for a plain Apps row — Steam/Web App rows are split out
  // before this and don't get sub-categorized.
  readonly property var primaryCategories: ["Game", "Development", "Graphics", "Network",
    "Office", "AudioVideo", "System", "Settings", "Utility", "Education"]

  function categoryFor(entry) {
    var cats = (entry && entry.categories && typeof entry.categories.join === "function") ? entry.categories : []
    for (var i = 0; i < cats.length; i++) {
      if (root.primaryCategories.indexOf(cats[i]) >= 0) return cats[i]
    }
    return "Other"
  }

  function entryName(entry) {
    return String((entry && entry.name) || (entry && entry.id) || "")
  }

  function entrySubtext(entry) {
    return String((entry && entry.genericName) || "")
  }

  function byLabel(a, b) {
    var an = a.label.toLowerCase(), bn = b.label.toLowerCase()
    if (an < bn) return -1
    if (an > bn) return 1
    return 0
  }

  function findEntry(appId) {
    var id = String(appId || "")
    if (!id) return null
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    for (var i = 0; i < values.length; i++) {
      if (values[i] && String(values[i].id || "") === id) return values[i]
    }
    return null
  }

  // Fires whenever the underlying app list *might* have changed (install/
  // uninstall, hidden-list reload) — Menu.qml listens and re-merges. "Might"
  // is doing real work there: see the Connections comment below.
  signal rowsChanged()

  // This signal is NOT a reliable "something was installed" event. Measured
  // (2026-09-19, Quickshell 0.3.1): it fires in bursts of 10 every ~500ms,
  // forever, fully idle, with zero inotify activity in any applications dir
  // — each burst being the same entries vanishing and reappearing, and those
  // entries being exactly the desktop ids present in more than one XDG dir
  // (a ~/.local/share/applications override shadowing a /usr/share or
  // flatpak copy). So nothing expensive may hang off it directly, and no
  // plain debounce can tame it: an icon-index rescan used to sit here behind
  // a 750ms debounce, which a signal arriving every ~500ms restarts forever
  // — confirmed it never fired once after startup. Menu.qml's
  // refreshAppRows() decides whether the app set *really* changed (by
  // content fingerprint) and calls refreshIconIndex() itself when it did.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.rowsChanged() }
  }

  // One pass over every installed app, split into native/web/Steam rows in
  // the shape MenuData.mergeAppRows() expects. Steam games get their own
  // parent entirely (not a sub-group inside Apps) — same treatment as Web
  // Apps, and for the same kind of reason: Steam repeatedly rewrites its
  // games' .desktop files in the background (the confirmed cause of a past
  // hitching incident), so keeping them out of the main Apps list means that
  // churn can never reshuffle an unrelated app's position/index there at
  // all, not just within a sub-section of it. Comment/categoriesText ride
  // along as extra fields for AppInfoPanel — mergeAppRows keeps unknown
  // keys as-is, and Menu.item() reads them back later.
  function buildRows() {
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var appRows = []
    var webappRows = []
    var steamRows = []
    for (var j = 0; j < values.length; j++) {
      var entry = values[j]
      if (!entry || entry.noDisplay) continue
      var appId = String(entry.id || "")
      if (!appId || root.hiddenIds[appId]) continue
      var name = root.entryName(entry)
      if (!name) continue
      var subtext = root.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      var isWeb = root.isWebapp(entry)
      var isSteam = !isWeb && root.isSteamApp(entry)
      var parentId = isWeb ? "webapps" : (isSteam ? "steam" : "apps")
      var list = isWeb ? webappRows : (isSteam ? steamRows : appRows)
      var categoriesText = (entry.categories && typeof entry.categories.join === "function")
        ? entry.categories.join(", ") : ""
      list.push({
        id: parentId + "." + appId,
        parent: parentId,
        kind: "app",
        icon: "",
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: name,
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        order: 0,
        comment: String(entry.comment || ""),
        categoriesText: categoriesText,
        category: (isWeb || isSteam) ? "" : root.categoryFor(entry)
      })
    }

    appRows.sort(root.byLabel)
    webappRows.sort(root.byLabel)
    steamRows.sort(root.byLabel)
    return { apps: appRows, webapps: webappRows, steam: steamRows }
  }

  // ------------------------------------------------------------- actions
  // Same commands AppLibrary.qml uses, run directly since the shell-
  // provided proxy isn't available to a clone (see header comment).
  function launch(desktopId) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
    if (root.recentStore) root.recentStore.recordLaunch(id)
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached(Util.shellQuote(root.omarchyPath + "/bin/omarchy-remove-launcher-entry") + " " + Util.shellQuote(id) + " " + Util.shellQuote(String(name || id)))
  }

  function copyLaunchCommand(appId) {
    var entry = root.findEntry(appId)
    var execString = entry ? String(entry.execString || "") : ""
    if (!execString) return
    // The menu closes right after this (clipboard contents are invisible,
    // and the next thing anyone does with them is paste somewhere else), so
    // the notification is the only confirmation the copy happened.
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(execString) + " | wl-copy"
      + "; command -v notify-send >/dev/null && notify-send -t 2500 'Launch command copied' " + Util.shellQuote(execString)])
  }

  // Opens now if the paths are already looked up, otherwise as soon as the
  // lookup lands. The panel's button only enables once they're ready, but
  // Ctrl+O has no such gate — pressed inside AppBrowserView's 150ms lookup
  // debounce (or from Home, which never requests paths at all) it used to
  // have nothing to open and silently did nothing.
  property string pendingOpenId: ""

  function openFileLocation(appId) {
    var id = String(appId || "")
    if (!id) return
    var paths = root.pathCache[id]
    if (!paths) {
      root.pendingOpenId = id
      root.requestPaths(id)
      return
    }
    root.pendingOpenId = ""
    var entry = root.findEntry(id)
    var isWeb = entry ? root.isWebapp(entry) : false
    var dir = isWeb ? paths.desktopDir : (paths.execDir || paths.desktopDir)
    if (!dir) return
    Util.execDetached("xdg-open " + Util.shellQuote(dir))
  }

  // ---------------------------------------------------------- icon lookup
  // Quickshell.iconPath() resolves against the on-disk icon theme — a real
  // per-call lookup cost, not a cheap string op. Caching it (iconCache
  // below) only pays off on a *repeat* visit to the same app; scrolling
  // steadily through a long, mostly-unvisited Apps list hits a fresh,
  // synchronous, on-the-UI-thread cache miss on nearly every row — this
  // was the actual cause of the periodic hitching while scrolling Apps.
  //
  // AppLibrary.qml avoids this by building a name→path index with one
  // background `find` over the icon theme directories, so lookups become
  // an O(1) dictionary hit instead of a per-icon theme search. Restored
  // here for the same reason, re-scanned whenever the app list changes
  // (a fresh install may need icons this process hasn't indexed yet).
  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  function iconIndexScanCommand() {
    // SVGs before PNGs so the parser (which keeps the first hit per name)
    // prefers scalable icons; app/device icons only, plus /usr/share/pixmaps
    // for the odd desktop entry (e.g. printer icons) that isn't in a theme.
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  function refreshIconIndex() {
    if (!iconIndexScan.running) iconIndexScan.running = true
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    // Swapping the index alone isn't enough to make newly found icons
    // appear: iconSource() answers from iconCache first, and an icon that
    // wasn't indexed yet when its row first drew is cached there as the
    // generic fallback — permanently, since nothing else ever evicted it
    // (a fresh install opened before this scan finished kept the placeholder
    // until the shell restarted). Drop the cache along with the swap.
    //
    // Order matters: index first, cache second. Reassigning iconCache is
    // what re-evaluates every iconSource() binding (they all read it); doing
    // that *before* the new index is in place would just re-resolve — and
    // re-cache — every miss against the old one.
    onExited: {
      root.iconIndex = root.pendingIconIndex
      root.iconCache = ({})
    }
  }

  Component.onCompleted: root.refreshIconIndex()

  property var iconCache: ({})

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)

    var cached = root.iconCache[value]
    if (cached !== undefined) return cached

    var indexed = root.iconIndex[value]
    var resolved
    if (indexed) {
      resolved = Util.fileUrl(indexed)
    } else {
      var themed = Quickshell.iconPath(value, true)
      resolved = themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
    }
    // Mutated in place, not reassigned — a per-icon write must not notify,
    // or every resolved icon would re-evaluate every other icon's binding.
    // The one deliberate reassignment is iconIndexScan's onExited, which
    // wants exactly that (see there).
    root.iconCache[value] = resolved
    return resolved
  }

  // ------------------------------------------------- file-location lookup
  // Neither the .desktop file's own path nor the resolved binary's path is
  // exposed by DesktopEntries, so both are found on demand: the .desktop
  // file by searching the same directories (and in the same priority
  // order) the stock hidden-entries.sh already uses, the binary via
  // `command -v` on the parsed Exec's argv[0].
  property var pathCache: ({})
  property string pendingId: ""

  function pathsReady(appId) {
    return root.pathCache[String(appId || "")] !== undefined
  }

  function lookupScript(appId) {
    var dirs = "\"$HOME/.local/share/applications\" \"$HOME/.nix-profile/share/applications\""
    return 'id=' + Util.shellQuote(appId) + '\n'
      + 'IFS=":" read -ra data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"\n'
      + 'dirs=(' + dirs + ')\n'
      + 'for d in "${data_dirs[@]}"; do dirs+=("$d/applications"); done\n'
      + 'desktop=""\n'
      + 'for d in "${dirs[@]}"; do\n'
      + '  [[ -f "$d/$id.desktop" ]] && { desktop="$d/$id.desktop"; break; }\n'
      + 'done\n'
      + 'printf "DESKTOP:%s\\n" "$desktop"\n'
  }

  function requestPaths(appId) {
    var id = String(appId || "")
    if (!id || root.pathCache[id] !== undefined) return

    // Process ignores a command change while already running (same
    // constraint the guard batch elsewhere in the menu works around) —
    // remember the newest request and re-run it once the in-flight lookup
    // exits, instead of silently losing it.
    if (lookupProc.running) {
      root.pendingId = id
      return
    }

    var entry = root.findEntry(id)
    var program = entry && entry.command && entry.command.length > 0 ? String(entry.command[0] || "") : ""

    lookupProc.appId = id
    lookupProc.collected = ""
    lookupProc.command = ["bash", "-c", root.lookupScript(id)
      + (program ? 'command -v ' + Util.shellQuote(program) + ' 2>/dev/null | while read -r p; do printf "EXEC:%s\\n" "$p"; done\n' : '')]
    lookupProc.running = true
  }

  Process {
    id: lookupProc
    property string appId: ""
    property string collected: ""
    stdout: SplitParser { onRead: function(line) { lookupProc.collected += line + "\n" } }
    onExited: {
      var desktopDir = ""
      var execDir = ""
      var lines = lookupProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        if (line.indexOf("DESKTOP:") === 0) {
          var dPath = line.slice(8)
          if (dPath) desktopDir = dPath.slice(0, dPath.lastIndexOf("/"))
        } else if (line.indexOf("EXEC:") === 0) {
          var ePath = line.slice(5)
          // A bare program name resolves via `command -v` to itself with
          // no slash if it's a shell builtin/function — not a real file.
          if (ePath.indexOf("/") >= 0) execDir = ePath.slice(0, ePath.lastIndexOf("/"))
        }
      }
      var next = ({})
      for (var k in root.pathCache) next[k] = root.pathCache[k]
      next[lookupProc.appId] = { desktopDir: desktopDir, execDir: execDir }
      root.pathCache = next

      if (root.pendingOpenId === lookupProc.appId) root.openFileLocation(lookupProc.appId)

      if (root.pendingId && root.pendingId !== lookupProc.appId) {
        var pending = root.pendingId
        root.pendingId = ""
        Qt.callLater(function() { root.requestPaths(pending) })
      } else {
        root.pendingId = ""
      }
    }
  }
}
