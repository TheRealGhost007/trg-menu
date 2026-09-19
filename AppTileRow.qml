import QtQuick
import qs.Commons
import qs.Ui

// One Home section: an optional title, then a wrapping grid of tiles. Used
// for Pinned, Recent, and the "More" section alike — a row whose kind is
// "app" renders as an icon-image tile (like Apps/Web Apps rows elsewhere),
// everything else as a colored-glyph tile for plain menu entries — so one component serves all three Home sections instead of
// duplicating the wrapping-grid position math three times.
//
// `rows` is a plain JS array snapshot (not a live model binding): each
// section only needs its own slice of Menu.qml's shared displayModel, and a
// Repeater bound to the *whole* shared model here would instantiate a full
// extra copy of every row per section just to hide the ones outside its
// slice. Menu.qml/HomeView already recompute JS snapshots on layoutSerial
// (the same idiom Menu.qml's own rowListHeight() uses), so this stays cheap
// and correct without inventing a second reactivity mechanism.
Item {
  id: root

  property string title: ""
  property var rows: []
  property int startIndex: 0
  property int columns: 4
  property int cellSize: 0
  property int tileSizePx: 0
  property color foreground: Color.menu.text
  property color appTileSurface: Color.menu.background
  property string fontFamily: Style.font.menuFamily
  property int cornerRadius: 0
  property var selectedBorderSpec: null
  property bool cursorActive: false
  property int selectedIndex: -1
  // function(globalIndex) -> color, only used for non-app (glyph) tiles
  property var colorFor: function() { return "transparent" }
  // function(appIcon) -> url, only used for app tiles
  property var appIconSource: function() { return "" }

  signal hoverSelect(int index, var item, var mouse)
  signal activate(int index)

  readonly property int rowCount: Math.max(1, Math.ceil(Math.max(1, root.rows.length) / Math.max(1, root.columns)))
  readonly property real titleHeight: titleText.visible ? titleText.implicitHeight + Style.space(8) : 0
  visible: root.rows.length > 0
  width: root.columns * root.cellSize
  height: root.visible ? titleHeight + rowCount * cellSize : 0

  Text {
    id: titleText
    visible: root.title.length > 0
    textFormat: Text.PlainText
    text: root.title
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.Medium
  }

  Item {
    id: grid
    anchors.top: titleText.visible ? titleText.bottom : parent.top
    anchors.topMargin: titleText.visible ? Style.space(8) : 0
    width: parent.width
    height: root.rowCount * root.cellSize

    Repeater {
      model: root.rows

      delegate: Item {
        id: tile
        required property int index
        required property var modelData

        readonly property int globalIndex: root.startIndex + tile.index
        readonly property bool isApp: tile.modelData.kind === "app"
        // Web apps are ordinary app rows under the "webapps" parent (see
        // AppSource.buildRows()), so the id prefix is the whole test.
        readonly property bool isWebapp: tile.isApp && String(tile.modelData.itemId || "").indexOf("webapps.") === 0
        readonly property bool hasCursor: root.cursorActive && tile.globalIndex === root.selectedIndex
        readonly property color tileColor: root.colorFor(tile.globalIndex)

        x: (tile.index % root.columns) * root.cellSize
        y: Math.floor(tile.index / root.columns) * root.cellSize
        width: root.cellSize
        height: root.cellSize

        BorderSurface {
          anchors.centerIn: parent
          width: root.tileSizePx
          height: root.tileSizePx
          radius: Math.max(root.cornerRadius, Style.space(14))
          color: tile.isApp ? root.appTileSurface : tile.tileColor
          borderSpec: tile.hasCursor ? root.selectedBorderSpec : Border.none()

          Column {
            anchors.centerIn: parent
            width: root.tileSizePx - Style.space(12)
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: root.tileSizePx * 0.42

              // Glyph tile icon, with a dark offset duplicate as a manual
              // drop shadow — keeps the white glyph
              // readable against every theme-derived tile color.
              Text {
                visible: !tile.isApp
                anchors.fill: parent
                anchors.topMargin: Style.space(1)
                anchors.leftMargin: Style.space(1)
                textFormat: Text.PlainText
                text: tile.modelData.icon || ""
                color: Qt.rgba(0, 0, 0, 0.45)
                font.family: (tile.modelData.iconFont && tile.modelData.iconFont.length > 0) ? tile.modelData.iconFont : root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }

              Text {
                visible: !tile.isApp
                anchors.fill: parent
                textFormat: Text.PlainText
                text: tile.modelData.icon || ""
                color: "#ffffff"
                font.family: (tile.modelData.iconFont && tile.modelData.iconFont.length > 0) ? tile.modelData.iconFont : root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }

              Image {
                id: appIconImage
                visible: tile.isApp
                anchors.centerIn: parent
                width: parent.height
                height: parent.height
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: tile.isApp ? root.appIconSource(tile.modelData.appIcon) : ""
                asynchronous: true
              }

              // Web-app marker. Home mixes native and web apps in one grid,
              // and the same service is often installed as both (Discord the
              // app next to Discord the web app) with the same name and
              // near-identical icons — without this the two tiles can't be
              // told apart. A disc in the tile's own surface color punches
              // the badge out of the icon rather than floating on top of it.
              Rectangle {
                visible: tile.isWebapp
                width: Style.space(18)
                height: width
                radius: width / 2
                color: root.appTileSurface
                anchors.right: appIconImage.right
                anchors.bottom: appIconImage.bottom
                anchors.rightMargin: -Style.space(6)
                anchors.bottomMargin: -Style.space(4)

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "󰖟"
                  color: root.foreground
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: tile.modelData.label || ""
              color: tile.isApp ? root.foreground : "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Medium
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.hoverSelect(tile.globalIndex, tile, { x: mouseX, y: mouseY })
          onPositionChanged: function(mouse) { root.hoverSelect(tile.globalIndex, tile, mouse) }
          onClicked: root.activate(tile.globalIndex)
        }
      }
    }
  }
}
