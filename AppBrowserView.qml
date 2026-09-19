import QtQuick
import qs.Commons

// Apps / Web Apps: the row list plus a side panel describing whichever row
// is highlighted. Only ever loaded while activeMenu is "apps"/"webapps"
// (see Menu.qml's Loader) — AppInfoPanel and all of the app-selection
// reactivity below exist only for as long as that's true, which is what
// keeps every other submenu free of this cost.
Item {
  id: root

  property alias model: list.model
  property bool cursorActive: false
  property int selectedIndex: -1
  property string filterText: ""
  property int layoutSerial: 0
  property bool showWebBadge: true

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var selectedBorderSpec: null
  property int cornerRadius: 0
  property string fontFamily: Style.font.menuFamily
  property real rowReservedBorderLeft: 0
  property real rowReservedBorderRight: 0
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  property int categoryHeaderHeight: Style.space(28)
  property int baseRowHeight: Style.space(50)
  property int detailRowHeight: Style.space(58)

  property int listWidth: Style.space(300)
  property int panelWidth: Style.space(260)
  property int gap: Style.space(14)

  required property var appSource
  // Optional: not required, so this view keeps working if a future caller
  // ever wires it up without pin support rather than hard-failing.
  property var pinStore: null
  // function(id) -> the underlying merged item (for comment/categoriesText,
  // which displayRow() doesn't carry through to the display model)
  required property var itemFor

  signal hoverSelect(int index, var item, var mouse)
  signal activate(int index)
  signal uninstallRequested()
  // For panel actions whose result lands outside the menu — Menu.qml runs
  // `action` and closes (see its dismissAfter()).
  signal dismissRequested(var action)

  function revealCursor() { list.revealCursor() }

  function selectedRowFor(_serial, _index, _cursor) {
    if (!root.cursorActive) return null
    if (root.selectedIndex < 0 || root.selectedIndex >= list.model.count) return null
    var row = list.model.get(root.selectedIndex)
    return (row && row.kind === "app") ? row : null
  }

  property var selectedRow: root.selectedRowFor(layoutSerial, selectedIndex, cursorActive)
  readonly property string selectedAppId: root.selectedRow ? root.selectedRow.appId : ""
  readonly property var selectedEntry: root.selectedRow ? root.itemFor(root.selectedRow.itemId) : null

  onSelectedAppIdChanged: pathLookupDebounce.restart()

  Timer {
    id: pathLookupDebounce
    interval: 150
    onTriggered: root.appSource.requestPaths(root.selectedAppId)
  }

  Row {
    anchors.fill: parent
    spacing: root.gap

    ListMenuView {
      id: list
      width: root.listWidth
      height: parent.height
      cursorActive: root.cursorActive
      selectedIndex: root.selectedIndex
      filterText: root.filterText
      showWebBadge: root.showWebBadge
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
      appIconSource: function(icon) { return root.appSource.iconSource(icon) }
      onHoverSelect: function(index, item, mouse) { root.hoverSelect(index, item, mouse) }
      onActivate: function(index) { root.activate(index) }
    }

    AppInfoPanel {
      width: root.panelWidth
      height: parent.height
      appName: root.selectedRow ? root.selectedRow.label : ""
      genericName: root.selectedEntry ? root.selectedEntry.description : ""
      comment: root.selectedEntry ? root.selectedEntry.comment : ""
      categoriesText: root.selectedEntry ? root.selectedEntry.categoriesText : ""
      iconSource: root.selectedRow ? root.appSource.iconSource(root.selectedRow.appIcon) : ""
      pathsReady: root.appSource.pathsReady(root.selectedAppId)
      pinned: root.pinStore ? root.pinStore.isPinned(root.selectedAppId) : false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onOpenRequested: root.activate(root.selectedIndex)
      onPinToggleRequested: if (root.pinStore) root.pinStore.togglePin(root.selectedAppId)
      onOpenLocationRequested: {
        var locationId = root.selectedAppId
        root.dismissRequested(function() { root.appSource.openFileLocation(locationId) })
      }
      onCopyCommandRequested: {
        var copyId = root.selectedAppId
        root.dismissRequested(function() { root.appSource.copyLaunchCommand(copyId) })
      }
      onUninstallRequested: root.uninstallRequested()
    }
  }
}
