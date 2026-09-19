import QtQuick
import qs.Commons
import qs.Ui

// One AppInfoPanel action: the kit's Button, plus a dimmed keyboard-shortcut
// hint at the right edge. Button has no trailing-text slot of its own, and
// the hint is the only place these shortcuts are advertised in the UI (the
// panel's buttons are mouse-only; Menu.qml's handleAppShortcut() is the
// keyboard path to the same actions).
//
// `enabled` is Item's own: it propagates to the Button inside, so a disabled
// action stops taking clicks without any extra wiring.
Item {
  id: root

  property string text: ""
  property string hint: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal clicked()

  implicitHeight: button.implicitHeight
  height: implicitHeight
  opacity: enabled ? 1.0 : 0.45

  Button {
    id: button
    anchors.left: parent.left
    anchors.right: parent.right
    leftAlign: true
    text: root.text
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.clicked()
  }

  Text {
    visible: root.hint.length > 0
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.controlPaddingX
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.hint
    color: root.foreground
    opacity: 0.4
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
