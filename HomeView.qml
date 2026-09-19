import QtQuick
import qs.Commons
import qs.Ui

// Home content (right of Sidebar): Pinned row, Recent row, then a "More"
// tile grid for every other root JSONC id (Apps/Web Apps/Settings are
// promoted to Sidebar destinations instead of appearing here — see
// Menu.qml's rebuildDisplay()). Only ever loaded while tileMode is active
// (Menu.qml's viewLoader), same lifecycle discipline as every other view.
Item {
  id: root

  property var listModel: null
  property int pinnedCount: 0
  property int recentCount: 0
  property int columns: 4
  property int cellSize: 0
  property int tileSizePx: 0
  property int layoutSerial: 0
  property color foreground: Color.menu.text
  property color appTileSurface: Color.menu.background
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: 0
  property var selectedBorderSpec: null
  property bool cursorActive: false
  property int selectedIndex: -1
  property var colorFor: function() { return "transparent" }
  property var appIconSource: function() { return "" }

  signal hoverSelect(int index, var item, var mouse)
  signal activate(int index)

  function snapshotRow(r) {
    return { itemId: r.itemId, kind: r.kind, icon: r.icon, iconFont: r.iconFont, appIcon: r.appIcon, appId: r.appId, label: r.label }
  }

  // Dependency args mirror Menu.qml's own rowListHeight()/dmenuRowListHeight()
  // idiom: layoutSerial (etc.) makes this recompute exactly when
  // Menu.qml's displayModel actually changed, without binding directly to
  // the ListModel's own change signals.
  function sliceFor(_serial, start, count) {
    var out = []
    if (!root.listModel) return out
    // moreCount reads listModel.count directly, so a listModel mutation can
    // make it (and moreRows) recompute mid-cascade, a beat before
    // pinnedCount/recentCount (sourced from Menu.qml's separate homeSections
    // write) catch up — get() past the model's current bounds returns
    // undefined for that instant. Skip rather than crash; the cascade
    // settles within the same synchronous pass and re-triggers this anyway.
    var limit = Math.min(start + count, root.listModel.count)
    for (var i = start; i < limit; i++) {
      var r = root.listModel.get(i)
      if (r) out.push(root.snapshotRow(r))
    }
    return out
  }

  readonly property var pinnedRows: sliceFor(layoutSerial, 0, pinnedCount)
  readonly property var recentRows: sliceFor(layoutSerial, pinnedCount, recentCount)
  readonly property int moreStart: pinnedCount + recentCount
  readonly property int moreCount: root.listModel ? Math.max(0, root.listModel.count - moreStart) : 0
  readonly property var moreRows: sliceFor(layoutSerial, moreStart, moreCount)
  readonly property bool hasSections: pinnedRows.length > 0 || recentRows.length > 0

  function revealCursor() {
    // Every tile is always fully realized (no virtualization at Home's
    // scale) and the card's own height already fits everything or scrolls
    // via homeFlickable below — just make sure a keyboard move into a
    // clipped edge scrolls it into view.
    if (root.selectedIndex < 0) return
    var y = tileY(root.selectedIndex)
    if (y < 0) return
    var itemBottom = y + root.cellSize
    if (itemBottom > homeFlickable.contentY + homeFlickable.height)
      homeFlickable.contentY = Math.min(itemBottom - homeFlickable.height, Math.max(0, homeFlickable.contentHeight - homeFlickable.height))
    if (y < homeFlickable.contentY)
      homeFlickable.contentY = Math.max(0, y)
  }

  // Absolute y of a global row index's tile, for revealCursor(). Walks the
  // same three stacked sections the Column below lays out, using each
  // AppTileRow's own reported titleHeight/height rather than re-deriving it.
  function tileY(globalIndex) {
    var y = 0
    if (globalIndex < pinnedCount)
      return y + pinnedSection.titleHeight + Math.floor(globalIndex / root.columns) * root.cellSize
    if (pinnedCount > 0) y += pinnedSection.height + column.spacing

    var recentLocal = globalIndex - pinnedCount
    if (recentLocal < recentCount)
      return y + recentSection.titleHeight + Math.floor(recentLocal / root.columns) * root.cellSize
    if (recentCount > 0) y += recentSection.height + column.spacing

    var moreLocal = globalIndex - moreStart
    return y + moreSection.titleHeight + Math.floor(moreLocal / root.columns) * root.cellSize
  }

  Flickable {
    id: homeFlickable
    anchors.fill: parent
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    contentWidth: width
    contentHeight: column.implicitHeight

    Column {
      id: column
      width: parent.width
      spacing: Style.space(20)

      AppTileRow {
        id: pinnedSection
        title: "Pinned"
        rows: root.pinnedRows
        startIndex: 0
        columns: root.columns
        cellSize: root.cellSize
        tileSizePx: root.tileSizePx
        foreground: root.foreground
        appTileSurface: root.appTileSurface
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        selectedBorderSpec: root.selectedBorderSpec
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex
        colorFor: root.colorFor
        appIconSource: root.appIconSource
        onHoverSelect: function(index, item, mouse) { root.hoverSelect(index, item, mouse) }
        onActivate: function(index) { root.activate(index) }
      }

      AppTileRow {
        id: recentSection
        title: "Recent"
        rows: root.recentRows
        startIndex: root.pinnedCount
        columns: root.columns
        cellSize: root.cellSize
        tileSizePx: root.tileSizePx
        foreground: root.foreground
        appTileSurface: root.appTileSurface
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        selectedBorderSpec: root.selectedBorderSpec
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex
        colorFor: root.colorFor
        appIconSource: root.appIconSource
        onHoverSelect: function(index, item, mouse) { root.hoverSelect(index, item, mouse) }
        onActivate: function(index) { root.activate(index) }
      }

      AppTileRow {
        id: moreSection
        title: root.hasSections ? "More" : ""
        rows: root.moreRows
        startIndex: root.moreStart
        columns: root.columns
        cellSize: root.cellSize
        tileSizePx: root.tileSizePx
        foreground: root.foreground
        appTileSurface: root.appTileSurface
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        selectedBorderSpec: root.selectedBorderSpec
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex
        colorFor: root.colorFor
        appIconSource: root.appIconSource
        onHoverSelect: function(index, item, mouse) { root.hoverSelect(index, item, mouse) }
        onActivate: function(index) { root.activate(index) }
      }
    }
  }
}
