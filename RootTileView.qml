import QtQuick
import qs.Commons
import qs.Ui

// Root-menu tile grid (Start-menu style) — only ever loaded while browsing
// the top level with no search and outside dmenu mode (see Menu.qml's
// Loader). Column/width math (how many columns actually fit, how tall the
// grid needs to be) is decided by Menu.qml before this loads, since the
// card's own size depends on it — this component just renders the grid
// it's told to.
GridView {
  id: grid

  property int tileSizePx: 0
  property int cellSize: 0
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: 0
  property var selectedBorderSpec: null
  property bool cursorActive: false
  property int selectedIndex: -1
  // function(index) -> color
  property var colorFor: function() { return "transparent" }

  signal hoverSelect(int index, var item, var mouse)
  signal activate(int index)

  cellWidth: cellSize
  cellHeight: cellSize
  interactive: false
  clip: false

  delegate: Item {
    id: tile
    required property int index
    required property string itemId
    required property string icon
    required property string iconFont
    required property string label

    readonly property bool hasCursor: grid.cursorActive && tile.index === grid.selectedIndex
    readonly property color tileColor: grid.colorFor(tile.index)

    width: grid.cellSize
    height: grid.cellSize

    BorderSurface {
      anchors.centerIn: parent
      width: grid.tileSizePx
      height: grid.tileSizePx
      radius: Math.max(grid.cornerRadius, Style.space(14))
      color: tile.tileColor
      borderSpec: tile.hasCursor ? grid.selectedBorderSpec : Border.none()

      Column {
        anchors.centerIn: parent
        width: grid.tileSizePx - Style.space(12)
        spacing: Style.space(6)

        // Icon glyph, with a dark offset duplicate behind it as a manual
        // drop shadow — keeps it readable against every theme-derived tile
        // color without an extra graphics-effect module dependency.
        Item {
          width: parent.width
          height: iconGlyph.implicitHeight

          Text {
            anchors.fill: parent
            anchors.topMargin: Style.space(1)
            anchors.leftMargin: Style.space(1)
            textFormat: Text.PlainText
            text: tile.icon
            color: Qt.rgba(0, 0, 0, 0.45)
            font.family: tile.iconFont.length > 0 ? tile.iconFont : grid.fontFamily
            font.pixelSize: Style.font.displayLarge
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            id: iconGlyph
            anchors.fill: parent
            textFormat: Text.PlainText
            text: tile.icon
            color: "#ffffff"
            font.family: tile.iconFont.length > 0 ? tile.iconFont : grid.fontFamily
            font.pixelSize: Style.font.displayLarge
            horizontalAlignment: Text.AlignHCenter
          }
        }

        Item {
          width: parent.width
          height: labelGlyph.implicitHeight

          Text {
            anchors.fill: parent
            anchors.topMargin: Style.space(1)
            anchors.leftMargin: Style.space(1)
            textFormat: Text.PlainText
            text: tile.label
            color: Qt.rgba(0, 0, 0, 0.45)
            font.family: grid.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            id: labelGlyph
            anchors.fill: parent
            textFormat: Text.PlainText
            text: tile.label
            color: "#ffffff"
            font.family: grid.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: grid.hoverSelect(tile.index, tile, { x: mouseX, y: mouseY })
      onPositionChanged: function(mouse) { grid.hoverSelect(tile.index, tile, mouse) }
        onClicked: grid.activate(tile.index)
    }
  }
}
