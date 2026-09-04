import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: a git glyph that turns urgent when any watched repository has
// uncommitted changes or unpushed commits, plus a popup listing them.
//
// All the work happens in core/git-status.sh, which prints one JSON object.
// This file only schedules it and draws the result.
Panel {
  id: root

  ipcTarget: moduleName
  manageIpc: false  // this file declares its own IpcHandler, with refresh/status

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: localPathFromUrl(Qt.resolvedUrl("core/git-status.sh"))
  readonly property string watchDirs: String(setting("watchDirs", "~/code"))
  readonly property int maxDepth: Number(setting("maxDepth", 4))
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 60)))

  property var pending: []
  property var notes: []
  property int scanned: 0
  property bool scanning: false
  property string lastError: ""

  readonly property bool unsynced: pending.length > 0
  readonly property color barIconColor: unsynced ? urgent : barForeground
  readonly property string summary: {
    if (lastError !== "") return "scan failed"
    if (scanned === 0) return "nothing scanned"
    if (!unsynced) return scanned + (scanned === 1 ? " repo synced" : " repos synced")
    return pending.length + (pending.length === 1 ? " repo pending" : " repos pending")
  }

  // Cursor state. Mouse hover and keyboard navigation drive the same index so
  // only one row is ever highlighted (the CursorSurface contract).
  property bool cursorActive: false
  property int rowIndex: 0

  function localPathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  function dirArgs() {
    var parts = watchDirs.split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var dir = parts[i].trim()
      if (dir !== "") out.push(dir)
    }
    return out.length > 0 ? out : ["~/code"]
  }

  function refresh() {
    if (scan.running) return
    scanning = true
    scan.command = ["bash", scriptPath, String(maxDepth)].concat(dirArgs())
    scan.running = true
  }

  // lazygit's -p opens a specific repository, so each row gets its own window
  // rather than stealing focus from a lazygit already open on another repo.
  function openRepo(repo) {
    if (!repo || !bar) return
    bar.run("omarchy-launch-tui lazygit -p " + bar.shellQuote(String(repo.path)))
    close()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || pending.length === 0) return
    rowIndex = Math.max(0, Math.min(pending.length - 1, rowIndex + dy))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh()

  Process {
    id: scan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.pending = result.pending || []
          root.notes = result.notes || []
          root.scanned = Number(result.scanned || 0)
          root.lastError = ""
        } catch (error) {
          root.lastError = "could not read the scan output"
        }
        if (root.rowIndex >= root.pending.length) root.rowIndex = Math.max(0, root.pending.length - 1)
      }
    }
    onExited: function(exitCode) {
      root.scanning = false
      if (exitCode !== 0 && root.lastError === "") root.lastError = "scan exited with code " + exitCode
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    // Guarded the way the Ui/Panel base guards its own: moduleName is injected
    // by the host, so an unguarded handler can register an empty target.
    enabled: root.ipcTarget !== ""
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.summary }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.barIconColor
    tooltipText: root.summary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive && root.pending.length > 0) root.openRepo(root.pending[root.rowIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Git"
            meta: root.scanning ? "Scanning" : root.summary
            detail: root.unsynced ? String(root.pending.length) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.unsynced ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.scanning
                onClicked: root.refresh()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: root.unsynced ? "PENDING TO SYNC" : "WATCHING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.unsynced && root.lastError === ""
              width: parent.width
              text: "Everything is committed and pushed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: repoColumn
              visible: root.unsynced
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.pending
                RepoRow {
                  required property var modelData
                  required property int index
                  width: repoColumn.width
                  repo: modelData
                  row: index
                }
              }
            }
          }

          Column {
            visible: root.notes.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            Repeater {
              model: root.notes
              Text {
                required property var modelData
                textFormat: Text.PlainText
                width: parent.width
                text: String(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }

  component RepoRow: CursorSurface {
    id: repoRow
    property var repo: null
    property int row: 0

    hasCursor: root.cursorActive && root.rowIndex === row
    foreground: root.foreground
    implicitHeight: repoContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.rowIndex = repoRow.row
      }
      onClicked: root.openRepo(repoRow.repo)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: repoContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: repoRow.repo ? String(repoRow.repo.name) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: repoRow.repo ? String(repoRow.repo.dir) + " · " + String(repoRow.repo.issues) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
