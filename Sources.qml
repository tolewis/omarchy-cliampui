import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What can be played, one provider at a time: cliamp radio channels, Radio Browser
// stations, saved playlists, podcasts and Spotify, as cliamp's provider.list reports
// them. A chip picks the provider to browse, the field filters the list and searches
// the provider, and a click loads the row. The playing row is marked, and [ and ] step
// to the row above or below it, which is how channels change without the pointer.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // PanelKeyCatcher runs before every item, so the panel must stand down while this
  // field has the keyboard, or typing "n" in a search would also skip the track.
  readonly property bool searchFocused: filterField.activeFocus

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var providers: service ? service.providers : []
  readonly property string providerKey: service ? service.browseProviderKey : ""
  readonly property var rows: service ? service.visibleSourceRows : []
  readonly property int activeIndex: service ? service.activeSourceIndex : -1
  readonly property var activeRow: activeIndex >= 0 && activeIndex < rows.length ? rows[activeIndex] : null

  // The keyboard cursor inside this list, used while the field has focus.
  property int cursorIndex: -1

  readonly property string providerName: {
    var p = service ? service.browseProvider : null
    return p ? String(p.name || p.key) : ""
  }

  visible: providers.length > 0
  spacing: Style.space(8)

  onRowsChanged: {
    if (cursorIndex >= rows.length) cursorIndex = rows.length > 0 ? 0 : -1
    Qt.callLater(showActive)
  }
  onActiveIndexChanged: Qt.callLater(showActive)

  // The playing row is scrolled into view, unless the keyboard cursor is in the list.
  function showActive() {
    if (cursorIndex >= 0 || activeIndex < 0 || activeIndex >= rows.length) return
    sourceList.positionViewAtIndex(activeIndex, ListView.Contain)
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var from = cursorIndex >= 0 ? cursorIndex : (activeIndex >= 0 ? activeIndex : -1)
    cursorIndex = from < 0 ? (delta > 0 ? 0 : rows.length - 1) : (from + delta + rows.length) % rows.length
    sourceList.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    service.playSource(rows[cursorIndex])
  }

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(sourcesHeader.implicitHeight, countLabel.implicitHeight)

    PanelSectionHeader {
      id: sourcesHeader
      text: "SOURCES"
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: countLabel
      textFormat: Text.PlainText
      text: {
        if (!root.service) return ""
        if (root.service.sourceBusy || root.service.searchBusy) return "LOADING"
        return root.rows.length > 0 ? String(root.rows.length) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // One chip per configured provider. Picking one browses it, and nothing plays until
  // a row is clicked.
  Flow {
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.providers

      CursorSurface {
        id: chip
        required property var modelData
        readonly property bool selected: String(modelData.key) === root.providerKey

        foreground: root.foreground
        current: selected
        implicitWidth: chipLabel.implicitWidth + Style.space(16)
        implicitHeight: chipLabel.implicitHeight + Style.space(8)

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.service) root.service.selectProvider(String(chip.modelData.key))
        }

        Text {
          id: chipLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(chip.modelData.name || chip.modelData.key)
          color: chip.selected ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: chip.selected
        }
      }
    }
  }

  // The row that is playing, named so it stays findable while the list scrolls.
  Text {
    width: parent.width
    textFormat: Text.PlainText
    elide: Text.ElideRight
    text: root.activeRow ? "Playing " + String(root.activeRow.name || "") + "   [ ] to change" : ""
    visible: text.length > 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  TextField {
    id: filterField
    width: parent.width
    placeholderText: root.service && root.service.browseSearchable
      ? "Filter or search " + root.providerName
      : "Filter " + root.providerName
    foreground: root.foreground
    font.family: root.fontFamily

    // The catcher stands down while this has focus, so the list keys live here.
    Keys.onEscapePressed: {
      if (text.length > 0) { clear(); return }
      root.cursorIndex = -1
      root.focus = true
    }
    Keys.onUpPressed: root.moveCursor(-1)
    Keys.onDownPressed: root.moveCursor(1)
    Keys.onReturnPressed: root.activateCursor()
    Keys.onEnterPressed: root.activateCursor()

    onTextChanged: {
      // The listed rows narrow at once. The provider search waits for a pause in typing.
      if (root.service) root.service.sourceQuery = text
      root.cursorIndex = text.length > 0 ? 0 : -1
      filterDebounce.restart()
    }
  }

  Timer {
    id: filterDebounce
    interval: 300
    repeat: false
    onTriggered: if (root.service) root.service.searchSources(filterField.text)
  }

  // An error from the last click or read, or why the list is empty.
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: {
      if (!root.service) return ""
      if (root.service.sourceError.length > 0) return root.service.sourceError
      if (root.rows.length > 0) return ""
      if (root.service.sourceBusy || root.service.searchBusy) return "Loading " + root.providerName + "..."
      if (filterField.text.length > 0) return "Nothing matched."
      return root.providerName + " has nothing to list."
    }
    visible: text.length > 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      visible: !!(root.service && root.service.sourceError.length > 0)
      // A click clears the message and reads the list again.
      onClicked: { root.service.sourceError = ""; root.service.refreshSource(root.providerKey) }
    }
  }

  // The list scrolls inside its own bounds, so a long Spotify library never pushes the
  // transport off screen.
  ListView {
    id: sourceList
    width: parent.width
    height: Math.min(contentHeight, Style.space(200))
    clip: true
    spacing: Style.space(2)
    model: root.rows
    keyNavigationEnabled: false
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: CursorSurface {
      id: sourceRow
      required property var modelData
      required property int index

      readonly property bool isActive: index === root.activeIndex
      readonly property bool isLoading: !!(root.service && root.service.loadingKey === Model.rowKey(modelData))

      width: sourceList.width
      foreground: root.foreground
      hasCursor: index === root.cursorIndex
      current: isActive
      implicitHeight: sourceLabel.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.cursorIndex = sourceRow.index
          root.service.playSource(sourceRow.modelData)
        }
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          id: sourceLabel
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(sourceRow.modelData.name || sourceRow.modelData.id)
          color: sourceRow.isActive ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: sourceRow.isActive
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: sourceRow.isLoading ? "LOADING" : Model.rowDetail(sourceRow.modelData)
          Layout.maximumWidth: sourceList.width * 0.4
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.2
          visible: text.length > 0
        }

        Text {
          textFormat: Text.PlainText
          text: sourceRow.isActive ? "✓" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          visible: text.length > 0
        }
      }
    }
  }

  // Rows cliamp lists but can never play, counted rather than shown.
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: root.service ? Model.hiddenNote(root.providerKey, root.service.sourceHidden) : ""
    visible: text.length > 0 && filterField.text.length === 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
