import QtQuick
import qs.Commons
import qs.Ui

// The row list — every plain submenu, search results, and dmenu-select
// mode all render through this one component (they already shared the
// exact same interaction model). Root's tile grid and dmenu-input mode
// have their own dedicated views instead (RootTileView, InputPromptView).
Item {
  id: root

  property alias model: resultList.model
  property bool cursorActive: false
  property int selectedIndex: -1
  property string filterText: ""
  property bool dmenuActive: false

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
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  // function(icon) -> url, only ever called for row.isApp rows (Apps/Web
  // Apps, via AppBrowserView) — left as a no-op default everywhere else.
  property var appIconSource: function() { return "" }

  signal hoverSelect(int index, var item, var mouse)
  signal activate(int index)

  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Contain alone parks the cursor row flush with the viewport edge, hiding
  // the neighbor entirely and losing the fold affordance. Keep the next
  // hidden row peeking past the cursor in the direction of travel.
  function revealCursor() {
    if (resultList.count === 0) return
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)

    var item = resultList.itemAtIndex(root.selectedIndex)
    if (!item) return

    var reach = root.rowPeek + root.rowSpacing
    if (root.selectedIndex < resultList.count - 1) {
      var maxY = Math.max(resultList.originY, resultList.originY + resultList.contentHeight - resultList.height)
      var overhang = item.y + item.height + reach - (resultList.contentY + resultList.height)
      if (overhang > 0) resultList.contentY = Math.min(resultList.contentY + overhang, maxY)
    }
    if (root.selectedIndex > 0) {
      var underhang = resultList.contentY - (item.y - reach)
      if (underhang > 0) resultList.contentY = Math.max(resultList.contentY - underhang, resultList.originY)
    }
  }

  ListView {
    id: resultList
    anchors.fill: parent
    clip: true
    spacing: root.rowSpacing
    boundsBehavior: Flickable.StopAtBounds

    section.property: "section"
    section.criteria: ViewSection.FullString
    // The same `section` field serves two mutually-exclusive views: a
    // search's "drilldown" divider (a plain hairline), and — only ever set
    // when the other is not — an Apps category header (e.g. "Steam") as a
    // text label. Never both in the same displayModel at once.
    section.delegate: Item {
      id: sectionDelegate
      required property string section
      readonly property bool isDrilldown: section === "drilldown"
      readonly property bool isCategory: section.length > 0 && !isDrilldown

      width: ListView.view.width
      height: isDrilldown ? root.dividerHeight : (isCategory ? root.categoryHeaderHeight : 0)
      visible: isDrilldown || isCategory

      Rectangle {
        visible: sectionDelegate.isDrilldown
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        height: Style.spacing.hairline
        color: Util.alpha(root.foreground, 0.2)
      }

      Text {
        visible: sectionDelegate.isCategory
        textFormat: Text.PlainText
        text: sectionDelegate.section
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.Medium
        anchors.left: parent.left
        anchors.leftMargin: root.rowReservedBorderLeft + Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    delegate: BorderSurface {
      id: row
      required property int index
      required property string itemId
      required property string kind
      required property string icon
      required property string iconFont
      required property string appIcon
      required property string appId
      required property string label
      required property string target
      required property string detail
      required property string path
      required property string action
      required property int childCount

      readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
      readonly property bool isApp: row.kind === "app"
      readonly property bool hasIcon: row.icon.length > 0 || row.isApp

      width: ListView.view.width
      height: root.rowHeightForDetail(row.detail)
      radius: root.cornerRadius
      color: row.hasCursor ? root.selectedBackground : "transparent"
      borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

      Text {
        id: iconText
        textFormat: Text.PlainText
        visible: row.hasIcon && !row.isApp
        text: row.icon
        color: row.hasCursor ? root.selectedText : root.foreground
        font.family: row.iconFont.length > 0 ? row.iconFont : root.fontFamily
        font.pixelSize: Style.font.iconLarge
        width: Style.space(36)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        anchors.left: parent.left
        anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
        y: contentColumn.y + (contentColumn.height - height) / 2
      }

      Image {
        id: appIconImage
        visible: row.isApp
        width: Style.font.iconLarge
        height: Style.font.iconLarge
        fillMode: Image.PreserveAspectFit
        // Decode at physical pixels — a logical-size decode leaves PNG
        // icons upscaled and blurry on HiDPI displays.
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: row.isApp ? root.appIconSource(row.appIcon) : ""
        asynchronous: true
        anchors.left: parent.left
        anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
        y: contentColumn.y + (contentColumn.height - height) / 2
      }

      Column {
        id: contentColumn
        anchors.left: row.hasIcon ? iconText.right : parent.left
        anchors.leftMargin: row.hasIcon ? Style.space(6) : root.rowReservedBorderLeft + Style.space(18)
        anchors.right: trail.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          id: labelText
          textFormat: Text.PlainText
          width: parent.width
          text: row.label
          color: row.hasCursor ? root.selectedText : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Medium
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.detail
          visible: (root.filterText || row.kind === "dmenu") && row.detail.length > 0
          color: root.foreground
          opacity: 0.52
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      Row {
        id: trail
        width: Style.space(14)
        anchors.right: parent.right
        anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
        y: contentColumn.y + (contentColumn.height - height) / 2
        spacing: 0

        Text {
          textFormat: Text.PlainText
          text: row.kind === "menu" || row.kind === "link" ? "›" : ""
          color: row.hasCursor ? root.selectedText : root.foreground
          opacity: row.kind === "menu" || row.kind === "link" ? 0.36 : 0
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Normal
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hoverSelect(row.index, row, { x: mouseArea.mouseX, y: mouseArea.mouseY })
        onPositionChanged: function(mouse) { root.hoverSelect(row.index, row, mouse) }
        onClicked: root.activate(row.index)
      }
    }
  }

  // Scroll scrims. The clipped row already marks the fold at rest; these
  // keep both edges honest once the list has been scrolled, when content
  // hides above the card top as well as below. Strength tracks the
  // distance still hidden past each edge rather than animating on a clock,
  // so a programmatic jump — wrapping from the last row to the first —
  // lands with the fade already applied.
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Math.min(Style.space(28), parent.height / 2)
    visible: opacity > 0
    opacity: resultList.contentHeight > resultList.height
      ? Math.max(0, Math.min(1, (resultList.contentY - resultList.originY) / height))
      : 0
    gradient: Gradient {
      GradientStop { position: 0; color: root.background }
      GradientStop { position: 1; color: Util.alpha(root.background, 0) }
    }
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.min(Style.space(28), parent.height / 2)
    visible: opacity > 0
    opacity: resultList.contentHeight > resultList.height
      ? Math.max(0, Math.min(1, (resultList.originY + resultList.contentHeight - resultList.height - resultList.contentY) / height))
      : 0
    gradient: Gradient {
      GradientStop { position: 0; color: Util.alpha(root.background, 0) }
      GradientStop { position: 1; color: root.background }
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(8)
    visible: resultList.count === 0

    Text {
      text: "󰈉"
      color: root.selectedText
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
      horizontalAlignment: Text.AlignHCenter
      width: Style.space(320)
    }

    Text {
      textFormat: Text.PlainText
      text: root.filterText ? "No matches for “" + root.filterText + "”" : "Nothing here yet"
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      horizontalAlignment: Text.AlignHCenter
      width: Style.space(320)
    }
  }
}
