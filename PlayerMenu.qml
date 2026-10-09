import QtQuick
import QtQuick.Controls

// Minimal popup. Do not declare a property named dim. Popup.dim is final
// and that declaration unloads the whole widget.
Popup {
  id: root

  required property Item anchorItem
  property var service: null
  property color foreground: "white"
  property string fontFamily: ""

  function toggle() {
    if (opened) close()
    else open()
  }

  width: 160
  height: 36

  Text {
    anchors.centerIn: parent
    text: "Open the panel"
    color: root.foreground
    font.pixelSize: 12
  }
}
