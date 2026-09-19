import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Recently-launched-apps persistence for the Home view's Recent row. Same
// FileView-read / printf-redirect-write pattern as PinStore.qml. State lives
// at ~/.local/state/omarchy/menu-recent.json. Written once per launch via a
// detached process (never blocks the launch itself), capped at maxEntries so
// the file and the Recent row both stay small.
Item {
  id: root

  readonly property string path: Quickshell.env("HOME") + "/.local/state/omarchy/menu-recent.json"
  readonly property int maxEntries: 12
  property var recentIds: []
  property bool loaded: false

  signal changed()

  // Moves appId to the front, dropping any earlier occurrence, capped at
  // maxEntries. Called from AppSource.launch() — must never throw or block.
  function recordLaunch(appId) {
    var id = String(appId || "")
    if (!id) return
    var next = [id]
    for (var i = 0; i < root.recentIds.length; i++) {
      if (root.recentIds[i] !== id) next.push(root.recentIds[i])
    }
    if (next.length > root.maxEntries) next = next.slice(0, root.maxEntries)
    root.recentIds = next
    root.save()
  }

  function parse(raw) {
    try {
      var data = JSON.parse(String(raw || "[]"))
      if (!Array.isArray(data)) return []
      var out = []
      for (var i = 0; i < data.length && out.length < root.maxEntries; i++) {
        var v = String(data[i] || "")
        if (v && out.indexOf(v) < 0) out.push(v)
      }
      return out
    } catch (e) {
      return []
    }
  }

  // Fire-and-forget: uses Util.execDetached rather than a Process property
  // owned by this Item, so a launch that immediately closes the menu (the
  // normal case — Menu.qml sets opened = false right after calling launch())
  // never risks the write being torn down mid-flight with the component.
  function save() {
    var json = JSON.stringify(root.recentIds)
    // Write-then-rename, never a redirect straight onto the real file: `>`
    // truncates before it writes, so a crash/kill in between — or two saves
    // racing, each its own detached shell — could leave an empty or half-
    // written file, which parse() reads back as "nothing saved". rename() is
    // atomic, and $$ keeps two racing saves off each other's temp file.
    var tmp = Util.shellQuote(root.path) + ".$$.tmp"
    Util.execDetached("mkdir -p " + Util.shellQuote(Quickshell.env("HOME") + "/.local/state/omarchy")
      + " && printf '%s' " + Util.shellQuote(json) + " > " + tmp
      + " && mv -f " + tmp + " " + Util.shellQuote(root.path))
  }

  FileView {
    id: recentFile
    path: root.path
    watchChanges: false
    printErrors: false
    onLoaded: { root.recentIds = root.parse(text()); root.loaded = true; root.changed() }
    onLoadFailed: { root.recentIds = []; root.loaded = true; root.changed() }
  }

  onRecentIdsChanged: root.changed()
}
