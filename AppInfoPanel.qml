import QtQuick
import qs.Commons
import qs.Ui

// Side panel for the Apps/Web Apps submenus (Menu.qml, appBrowseMode):
// details + actions for whichever row is currently highlighted.
Item {
  id: panel

  property string appName: ""
  property string genericName: ""
  property string comment: ""
  property string categoriesText: ""
  property string iconSource: ""
  property bool pathsReady: false
  property bool pinned: false
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal openRequested()
  signal pinToggleRequested()
  signal openLocationRequested()
  signal copyCommandRequested()
  signal uninstallRequested()

  readonly property bool hasSelection: appName.length > 0

  // Panel height is dictated by the list next to it (row count), not by
  // this panel's own content — a longer comment/description can need more
  // room than that, so this scrolls instead of spilling past the card.
  Flickable {
    id: panelScroll
    anchors.fill: parent
    anchors.margins: Style.space(4)
    visible: panel.hasSelection
    clip: true
    contentWidth: width
    contentHeight: column.implicitHeight
    boundsBehavior: Flickable.StopAtBounds

    Column {
    id: column
    width: parent.width
    spacing: Style.space(10)

    Image {
      width: Style.space(64)
      height: Style.space(64)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: panel.iconSource
      asynchronous: true
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: panel.appName
      color: panel.foreground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.title
      font.weight: Font.Medium
      wrapMode: Text.Wrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: panel.genericName
      visible: text.length > 0
      color: panel.foreground
      opacity: 0.6
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: panel.comment
      visible: text.length > 0
      color: panel.foreground
      opacity: 0.75
      font.family: panel.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: panel.categoriesText
      visible: text.length > 0
      color: panel.foreground
      opacity: 0.5
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Rectangle {
      width: parent.width
      height: Style.spacing.hairline
      color: Util.alpha(panel.foreground, 0.2)
    }

    Button {
      width: parent.width
      leftAlign: true
      text: "Open"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      onClicked: panel.openRequested()
    }

    Button {
      width: parent.width
      leftAlign: true
      text: panel.pinned ? "Unpin from Home" : "Pin to Home"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      onClicked: panel.pinToggleRequested()
    }

    Button {
      width: parent.width
      leftAlign: true
      text: "Open File Location"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      enabled: panel.pathsReady
      opacity: enabled ? 1.0 : 0.45
      onClicked: panel.openLocationRequested()
    }

    Button {
      width: parent.width
      leftAlign: true
      text: "Copy Launch Command"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      onClicked: panel.copyCommandRequested()
    }

    Button {
      width: parent.width
      leftAlign: true
      text: "Uninstall"
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      onClicked: panel.uninstallRequested()
    }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !panel.hasSelection
    textFormat: Text.PlainText
    text: "Select an app"
    color: panel.foreground
    opacity: 0.5
    font.family: panel.fontFamily
    font.pixelSize: Style.font.body
  }
}
