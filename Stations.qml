import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A short browser. The panel is about 500 px tall, so this section never grows
// with the full library. Playlists, favorites, and history each load one page.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string filterText: ""

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool catalogMode: !!(service && service.catalogMode)
  readonly property string tab: service ? String(service.browseTab || "playlists") : "playlists"
  readonly property var stations: service ? service.stations : []
  readonly property var sourceRows: {
    if (!catalogMode) return stations
    if (tab === "favorites") return service.favoriteRows || []
    if (tab === "history") return service.historyRows || []
    return service.providerCatalog || []
  }
  readonly property var filtered: Model.filterStations(sourceRows, filterText)
  readonly property int shownTotal: {
    if (!service || !catalogMode) return filtered.length
    if (tab === "favorites") return service.favoriteTotal || filtered.length
    if (tab === "playlists" || tab === "search") return service.playlistTotal || filtered.length
    return filtered.length
  }
  readonly property bool canMore: catalogMode && filtered.length > 0 && filtered.length < shownTotal
    && (tab === "playlists" || tab === "favorites")

  readonly property bool stationsAnswered: service
    ? (service.stationsLoaded !== undefined ? service.stationsLoaded : service.running)
    : false

  visible: catalogMode || stations.length > 0 || stationsAnswered
  spacing: Style.space(6)

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  PanelSectionHeader {
    text: root.catalogMode
      ? (root.tab === "search" ? "SEARCH" : root.tab.toUpperCase())
      : "STATIONS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Row {
    width: parent.width
    spacing: Style.space(12)
    visible: root.catalogMode

    Repeater {
      model: [
        { key: "playlists", label: "Playlists" },
        { key: "favorites", label: "Favorites" },
        { key: "history", label: "History" }
      ]
      delegate: Text {
        required property var modelData
        text: modelData.label
        color: root.tab === modelData.key ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.underline: root.tab === modelData.key
        font.bold: root.tab === modelData.key

        MouseArea {
          anchors.fill: parent
          preventStealing: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openTab(modelData.key)
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    visible: root.catalogMode && root.filtered.length === 0 && String(statusText).length > 0
    text: statusText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption

    readonly property string statusText: {
      var err = root.service ? String(root.service.catalogError || "") : ""
      if (err.length > 0) return err
      if (root.sourceRows.length > 0) return "Nothing matched."
      if (root.service && root.service.browseBusy) return "Loading..."
      if (root.tab === "favorites") return "No favorites yet."
      if (root.tab === "history") return "No history yet."
      if (root.tab === "search") return "Nothing matched."
      return ""
    }
  }

  TextField {
    id: filterField
    width: parent.width
    placeholderText: root.catalogMode ? "Filter, or Enter to search" : "Filter stations"
    foreground: root.foreground
    font.family: root.fontFamily
    visible: root.catalogMode || root.stations.length > 0

    Keys.onEscapePressed: {
      filterField.clear()
      if (root.catalogMode && root.service) root.service.refreshCatalog()
    }
    Keys.onReturnPressed: root.submitSearch()
    Keys.onEnterPressed: root.submitSearch()
    onTextChanged: filterDebounce.restart()
  }

  Timer {
    id: filterDebounce
    interval: 180
    repeat: false
    onTriggered: root.filterText = filterField.text
  }

  // Five rows. The rest of the page stays inside this box, so the panel
  // footer is not pushed off a 500 px window.
  ListView {
    id: rowList
    width: parent.width
    height: Math.min(contentHeight, Style.space(132))
    clip: true
    spacing: Style.space(2)
    model: root.filtered
    keyNavigationEnabled: false
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; interactive: false }

    delegate: CursorSurface {
      id: row
      required property var modelData
      required property int index

      width: rowList.width
      foreground: root.foreground
      implicitHeight: label.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        z: 2
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activate(modelData)
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)

        Text {
          id: label
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(modelData.name || modelData.id || "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: String(modelData.artist || "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.maximumWidth: Style.space(120)
          visible: text.length > 0 && modelData.kind !== "playlist"
        }
      }
    }
  }

  Text {
    visible: root.canMore
    text: "More"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: true

    MouseArea {
      anchors.fill: parent
      preventStealing: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!root.service) return
        if (root.tab === "favorites") root.service.loadMoreFavorites()
        else root.service.loadMorePlaylists()
      }
    }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.catalogMode
      ? (root.shownTotal > root.filtered.length ? String(root.filtered.length) + " of " + root.shownTotal : "")
      : ""
    visible: text.length > 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  function openTab(key) {
    if (!service) return
    filterText = ""
    filterField.clear()
    if (key === "favorites") service.loadFavorites()
    else if (key === "history") service.loadHistory()
    else service.refreshCatalog()
  }

  function submitSearch() {
    if (!catalogMode || !service) return
    var q = String(filterField.text || "")
    if (q.length === 0) { service.refreshCatalog(); return }
    service.searchCatalog(q)
  }

  function activate(item) {
    if (!service || !item) return
    if (!catalogMode) { service.playStation(String(item.id || "")); return }
    if (tab === "history") { service.playHistory(String(item.uri || item.id || "")); return }
    if (item.uri && String(item.uri).length > 0) {
      service.playResult(item)
      return
    }
    var playId = String(item.id || "")
    if (item.uri && String(item.uri).indexOf("spotify:album:") === 0)
      playId = String(item.uri).substring("spotify:album:".length)
    service.playCatalogItem(playId)
  }
}
