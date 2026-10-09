import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The right-press menu on the bar entry. A plain popup in the bar's own window,
// dropped under the icon. Every row closes it on activation, and focus loss closes
// it too, so the menu and the panel never act on the same press.
Popup {
  id: root

  required property Item anchorItem
  property var service: null

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)

  function toggle() { opened ? close() : open() }

  // The popup places itself in the bar window, so the icon's global position is what
  // it anchors against.
  readonly property point anchorPos: anchorItem
    ? anchorItem.mapToGlobal(0, anchorItem.height) : Qt.point(0, 0)

  width: Style.space(220)
  x: Qt.clamp(anchorPos.x + anchorItem.width / 2 - width / 2, Style.space(4),
              (anchorItem.window ? anchorItem.window.width : 480) - width - Style.space(4))
  y: anchorPos.y + Style.space(4)

  padding: Style.space(4)
  focus: true
  closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnSystemModalClose
  // Focus loss closes the menu the way an outside press does.
  onFocusChanged: if (opened && !focus) close()

  background: BorderSurface {
    color: Color.popups.background
    borderSpec: Border.localOrSurfaceSpec("popups", "border", root.foreground, Color.popups.border,
                                          Math.max(1, Style.space(2)))
    radius: Style.cornerRadius
  }

  Column {
    id: rows
    spacing: Style.space(2)

    Repeater {
      model: root.entries

      Item {
        id: row
        required property var modelData
        width: rows.width
        implicitHeight: rowText.implicitHeight + Style.spacing.rowPaddingX
        opacity: modelData.enabled ? 1.0 : 0.4

        BorderSurface {
          anchors.fill: parent
          visible: rowArea.hovered && modelData.enabled
          color: Style.hoverFillFor(root.foreground, Color.accent)
          radius: Style.cornerRadius
        }

        MouseArea {
          id: rowArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: modelData.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          enabled: modelData.enabled
          onClicked: {
            modelData.action()
            root.close()
          }
        }

        Text {
          id: rowText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          textFormat: Text.PlainText
          text: modelData.label
          color: modelData.enabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  // Top to bottom, the entries the brief asks for. Row state reads the service at
  // open time, so a daemon that quits mid-menu re-enables the right rows on the next
  // open.
  readonly property var entries: [
    { label: service && service.showPlaying ? "Pause" : "Play",
      enabled: !!(service && service.running),
      action: function() { if (service) service.playPause() } },
    { label: "Stop",
      enabled: !!(service && service.running),
      action: function() { if (service) service.stop() } },
    { label: "Restart daemon",
      enabled: !!(service),
      action: function() { if (service) service.restartDaemon() } },
    { label: "Quit daemon",
      enabled: !!(service && service.running),
      action: function() { if (service) service.quitDaemon() } },
    { label: "Open TUI",
      enabled: !!(service && !service.running),
      action: function() { if (service) service.openTui() } }
  ]
}