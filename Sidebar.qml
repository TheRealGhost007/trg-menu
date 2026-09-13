import QtQuick
import qs.Commons
import qs.Ui
import "MenuData.js" as MenuData

// Home-only persistent nav: Home / Apps / Web Apps / Recent / Settings.
// Fixed regardless of JSONC content (see MenuData.homeDestinations()) so it
// never needs to know about user-added root entries. Mouse-clickable always;
// keyboard access is Tab (toggle focus into/out of the sidebar, driven by
// Menu.qml's keyCatcher) + Up/Down + Enter, mirroring the rest of the menu's
// keyboard model rather than inventing a separate one.
Item {
  id: root

  property string activeDestination: "root"
  property bool focused: false
  property int focusedIndex: 0
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: 0

  readonly property var destinations: MenuData.homeDestinations()

  signal navigate(string id)

  Column {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(4)

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
        height: Style.space(40)
        radius: root.cornerRadius
        color: rowSurface.isActive ? Style.selectedFillFor(root.foreground, Color.accent)
          : rowSurface.hot ? Style.hoverFillFor(root.foreground, Color.accent)
          : "transparent"
        borderSpec: rowSurface.isKeyboardHighlight ? Border.controlSpec("hover-cursor", root.foreground, Color.accent) : Border.none()

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
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

          Text {
            textFormat: Text.PlainText
            text: rowSurface.modelData.label
            color: rowSurface.isActive ? Color.accent : root.foreground
            opacity: rowSurface.isActive ? 1 : 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: rowSurface.isActive ? Font.Medium : Font.Normal
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
