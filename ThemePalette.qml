import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Tile colors for RootTileView come straight from the active theme's own
// named palette (colors.toml) — the same red/orange/yellow/green/cyan/blue
// /magenta roles every Omarchy theme defines for terminals — so tiles read
// as "this theme's colors," not an algorithmic guess. Color.qml only
// exposes foreground/background/accent/urgent/muted for shell surfaces, so
// this reads colors.toml directly via a watched FileView, the same pattern
// Menu.qml already uses for the JSONC menu sources.
Item {
  id: root

  readonly property string path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  property var palette: []

  function parse(raw) {
    var text = String(raw || "")
    var keys = ["red", "orange", "yellow", "green", "cyan", "blue", "magenta", "brown"]
    var colors = []
    for (var i = 0; i < keys.length; i++) {
      var re = new RegExp("^\\s*" + keys[i] + "\\s*=\\s*\"(#[0-9a-fA-F]{3,8})\"", "m")
      var m = text.match(re)
      if (m) colors.push(m[1])
    }
    return colors
  }

  // JS's % can return a negative result (e.g. -1 % 8 === -1), which turns
  // into an out-of-bounds array read (undefined) whenever a GridView
  // delegate briefly sees index -1 during a model-count transition — wrap
  // properly instead of using % directly.
  function positiveMod(n, m) {
    return ((n % m) + m) % m
  }

  function colorFor(index) {
    if (root.palette.length > 0) return root.palette[root.positiveMod(index, root.palette.length)]

    // Fallback for a theme whose colors.toml doesn't define that role set:
    // rotate hues off the accent color instead of a fixed color.
    var base = Color.accent
    var h = root.positiveMod(base.hslHue + (index * 0.13), 1.0)
    var s = Math.max(0.4, Math.min(0.85, base.hslSaturation))
    var l = Math.max(0.28, Math.min(0.58, base.hslLightness))
    return Qt.hsla(h, s, l, 1.0)
  }

  FileView {
    path: root.path
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = root.parse(text())
    onLoadFailed: root.palette = []
    onFileChanged: reload()
  }
}
