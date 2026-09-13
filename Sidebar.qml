import QtQuick
import qs.Commons
import qs.Ui
import "MenuData.js" as MenuData

// Home-only persistent nav: Home / Web Apps / Steam / one destination per
// installed app category / Recent / Settings. The static entries are fixed
// regardless of JSONC content (see MenuData.homeDestinations()) so it never
// needs to know about user-added root entries; the category destinations are
// dynamic — driven by `categories`, which Menu.qml computes from what's
// actually installed. Mouse-clickable always; keyboard access is Tab
// (toggle focus into/out of the sidebar, driven by Menu.qml's keyCatcher) +
// Up/Down + Enter, mirroring the rest of the menu's keyboard model rather
// than inventing a separate one.
Item {
  id: root

  property string activeDestination: "root"
  property bool focused: false
  property int focusedIndex: 0
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: 0
  property var categories: []

  readonly property var destinations: MenuData.homeDestinations(root.categories)

  readonly property int rowHeight: Style.space(40)
  readonly property int rowSpacing: Style.space(4)

  signal navigate(string id)

  // Per-category destinations make this list open-ended (a heavily-
  // categorized app collection can run well past what fits in the card),
  // so this scrolls instead of assuming everything always fits like the
  // original fixed 6-entry version could.
  onFocusedIndexChanged: root.revealFocused()
  onFocusedChanged: if (root.focused) root.revealFocused()

  function revealFocused() {
    if (!root.focused) return
    var y = root.focusedIndex * (root.rowHeight + root.rowSpacing)
    var bottom = y + root.rowHeight
    if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height
    if (y < flick.contentY) flick.contentY = y
  }

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    contentWidth: width
    contentHeight: column.implicitHeight

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: root.rowSpacing

    Repeater {
      model: root.destinations

      delegate: BorderSurface {
        id: rowSurface
        required property int index
        required property var modelData

        readonly property bool isActive: rowSurface.modelData.id === root.activeDestination
        readonly property bool isKeyboardHighlight: root.focused && rowSurface.index === root.focusedIndex
        readonly property bool hot: mouseArea.containsMouse || rowSurface.isKeyboardHighlight

        width: parent.width
        height: root.rowHeight
        radius: root.cornerRadius
        color: rowSurface.isActive ? Style.selectedFillFor(root.foreground, Color.accent)
          : rowSurface.hot ? Style.hoverFillFor(root.foreground, Color.accent)
          : "transparent"
        borderSpec: rowSurface.isKeyboardHighlight ? Border.controlSpec("hover-cursor", root.foreground, Color.accent) : Border.none()

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: rowSurface.modelData.icon
            color: rowSurface.isActive ? Color.accent : root.foreground
            opacity: rowSurface.isActive ? 1 : 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            width: Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
          }

          // Per-category labels (e.g. "AudioVideo", "Development") can run
          // longer than the original fixed 6-word set — elide rather than
          // overflow the Sidebar's width.
          Text {
            textFormat: Text.PlainText
            width: parent.width - Style.space(30)
            text: rowSurface.modelData.label
            color: rowSurface.isActive ? Color.accent : root.foreground
            opacity: rowSurface.isActive ? 1 : 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: rowSurface.isActive ? Font.Medium : Font.Normal
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: mouseArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.navigate(rowSurface.modelData.id)
        }
      }
    }
  }
  }
}
