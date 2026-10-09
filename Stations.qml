import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Radio stations as the daemon reports them, listed above the library. Hidden while
// the list is empty, which is also the answer a daemon without the stations op
// gives, so the panel is unchanged on an unpatched cliamp. Rows are reached with the
// pointer; the keyboard cursor stays on the library and the output sheet.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var stations: service ? service.stations : []

  visible: root.stations.length > 0
  spacing: Style.space(8)

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  PanelSectionHeader {
    text: "STATIONS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // Stations are few, but a long name must never hide the rest of the panel, so the
  // list scrolls inside its own bounds the way the library does.
  ListView {
    id: stationList
    width: parent.width
    height: Math.min(contentHeight, Style.space(160))
    clip: true
    spacing: Style.space(2)
    model: root.stations
    keyNavigationEnabled: false
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: CursorSurface {
      id: stationRow
      required property var modelData
      required property int index

      width: stationList.width
      foreground: root.foreground
      implicitHeight: stationLabel.implicitHeight + Style.spacing.rowPaddingX

      readonly property bool isActive: root.service && index === root.service.activeStationIndex

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.service.playStation(String(modelData.id || ""))
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          id: stationLabel
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(modelData.name || modelData.id)
          color: stationRow.isActive ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: String(modelData.provider || "").toUpperCase()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          visible: text.length > 0
        }

        Text {
          textFormat: Text.PlainText
          text: stationRow.isActive ? "✓" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}