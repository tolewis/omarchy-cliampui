import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Radio stations as the daemon reports them, listed above the library. The section
// hides while the daemon has not answered a stations read, which is also the answer
// a daemon without the stations op gives, so the panel is unchanged on an unpatched
// cliamp. The one exception is an answered-but-empty registry, which says where the
// rows come from instead of leaving a hole in the panel. Rows are reached with the
// pointer; the keyboard cursor stays on the library and the output sheet.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string filterText: ""

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool catalogMode: !!(service && service.catalogMode)
  readonly property var stations: service ? service.stations : []
  readonly property var catalog: service && service.providerCatalog ? service.providerCatalog : []
  readonly property var rows: catalogMode ? catalog : stations
  readonly property var filtered: Model.filterStations(rows, filterText)

  // An answered-but-empty registry is the only case that opens the section with no
  // rows. stationsLoaded would be the right flag; until it exists, the service
  // running is the closest honest stand-in.
  readonly property bool stationsAnswered: service
    ? (service.stationsLoaded !== undefined ? service.stationsLoaded : service.running)
    : false

  // The row the daemon is actually playing, looked up in the unfiltered list so the
  // active match is the same whether or not the filter is hiding rows.
  readonly property var activeStation: (service && service.activeStationIndex >= 0
      && service.activeStationIndex < stations.length)
    ? stations[service.activeStationIndex] : null

  visible: root.stations.length > 0 || root.stationsAnswered
  spacing: Style.space(8)

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  PanelSectionHeader {
    // The count is the filtered count, which is the full count while the filter is
    // empty, so one binding covers both.
    text: (root.catalogMode ? String(root.service.activeProviderKey).toUpperCase() : "STATIONS") + " (" + root.filtered.length + ")"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // The station being played, named the way the hero names a track, so the active
  // row stays findable while the list scrolls.
  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    visible: root.catalogMode && root.rows.length === 0
    text: {
      var err = root.service ? String(root.service.catalogError || "") : ""
      if (err.indexOf("rate-limited") >= 0)
        return "Spotify is rate-limited on the shared app. A personal client id fixes this. Retrying."
      if (err.length > 0) return err
      return "Loading playlists..."
    }
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    id: nowPlayingLine
    width: parent.width
    textFormat: Text.PlainText
    text: root.activeStation
      ? root.service.title + " — " + String(root.activeStation.name || root.activeStation.id || "")
      : ""
    visible: text.length > 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // The filter runs client-side on name and artist, so it answers on a daemon that
  // cannot search. The field keeps the library's focus idiom, and a registry with
  // no rows has nothing to filter.
  TextField {
    id: filterField
    width: parent.width
    placeholderText: root.catalogMode ? "Search Spotify" : "Filter stations"
    foreground: root.foreground
    font.family: root.fontFamily
    visible: root.rows.length > 0 || root.catalogMode

    Keys.onEscapePressed: filterField.clear()
    onTextChanged: filterDebounce.restart()
  }

  Timer {
    id: filterDebounce
    interval: 260
    repeat: false
    onTriggered: {
      root.filterText = filterField.text
      if (root.catalogMode && root.service) root.service.searchCatalog(filterField.text)
    }
  }

  // Stations are few, but a long name must never hide the rest of the panel, so the
  // list scrolls inside its own bounds the way the library does.
  ListView {
    id: stationList
    width: parent.width
    // Full height, so the panel scroller reaches every playlist and the
    // footer. A nested scroller here ate the wheel and never moved.
    height: contentHeight
    clip: false
    spacing: Style.space(2)
    model: root.filtered
    keyNavigationEnabled: false
    boundsBehavior: Flickable.StopAtBounds
    interactive: false
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOff }

    delegate: CursorSurface {
      id: stationRow
      required property var modelData
      required property int index

      width: stationList.width
      foreground: root.foreground
      implicitHeight: stationLabel.implicitHeight + Style.spacing.rowPaddingX

      // Matched by id against the unfiltered list, because after a filter the
      // delegate's index is a position in the filtered list, not in stations.
      readonly property bool isActive: root.activeStation !== null
        && String(modelData.id || "") === String(root.activeStation.id || "")

      MouseArea {
        z: 2
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          if (!root.catalogMode) { root.service.playStation(String(modelData.id || "")); return }
          var playId = String(modelData.id || "")
          if (modelData.uri && String(modelData.uri).indexOf("spotify:album:") === 0)
            playId = String(modelData.uri).substring("spotify:album:".length)
          root.service.playCatalogItem(playId)
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
          id: stationLabel
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(modelData.name || modelData.id)
          color: stationRow.isActive ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: stationRow.isActive
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

  // One answered-but-empty registry: say where the rows come from instead of
  // leaving the section a blank hole.
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Play something once and stations appear here."
    horizontalAlignment: Text.AlignHCenter
    visible: root.stations.length === 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}