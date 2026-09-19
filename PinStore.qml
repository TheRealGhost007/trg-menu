import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Pinned-apps persistence for the Home view's Pinned row. Modeled on
// AppSource.qml's own FileView-read / Process-write / try-catch-parse
// pattern. State lives at ~/.local/state/omarchy/menu-pinned.json, a flat
// file alongside this plugin family's other persisted state (clipboard-
// history.json, notifications.json) rather than a new subdirectory.
Item {
  id: root

  readonly property string path: Quickshell.env("HOME") + "/.local/state/omarchy/menu-pinned.json"
  property var pinnedIds: []
  property bool loaded: false

  signal changed()

  function isPinned(appId) {
    var id = String(appId || "")
    if (!id) return false
    return root.pinnedIds.indexOf(id) >= 0
  }

  function togglePin(appId) {
    var id = String(appId || "")
    if (!id) return
    var next = root.pinnedIds.slice()
    var at = next.indexOf(id)
    if (at >= 0) next.splice(at, 1)
    else next.push(id)
    root.pinnedIds = next
    root.save()
  }

  function parse(raw) {
    try {
      var data = JSON.parse(String(raw || "[]"))
      if (!Array.isArray(data)) return []
      var out = []
      for (var i = 0; i < data.length; i++) {
        var v = String(data[i] || "")
        if (v && out.indexOf(v) < 0) out.push(v)
      }
      return out
    } catch (e) {
      return []
    }
  }

  // Matches Menu.qml's finishRequest() pattern (printf into a redirect) rather
  // than Process.write() over stdin: Quickshell's Process exposes write() but
  // no way to close/EOF the stream from QML, so a `cat > file` reading stdin
  // would never see end-of-input and hang forever. Fire-and-forget via
  // Util.execDetached (same as AppSource.qml's launch()/remove()) since
  // nothing needs to observe completion.
  function save() {
    var json = JSON.stringify(root.pinnedIds)
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
    id: pinFile
    path: root.path
    watchChanges: false
    printErrors: false
    onLoaded: { root.pinnedIds = root.parse(text()); root.loaded = true; root.changed() }
    onLoadFailed: { root.pinnedIds = []; root.loaded = true; root.changed() }
  }

  onPinnedIdsChanged: root.changed()
}
