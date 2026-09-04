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
  property var watched: []
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

  // Persist the watched folders into this widget's inline shell.json entry.
  // Same round-trip the first-party panels use, so the bar's widget settings
  // UI and this panel stay one source of truth instead of two.
  function persistDirs(dirs) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.watchDirs = dirs.join(", ")
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function addDir(raw) {
    var dir = String(raw || "").trim().replace(/\/+$/, "")
    if (dir === "") return
    var dirs = dirArgs()
    if (dirs.indexOf(dir) !== -1) return
    dirs.push(dir)
    persistDirs(dirs)
  }

  function removeDir(dir) {
    var dirs = dirArgs()
    var at = dirs.indexOf(String(dir))
    if (at === -1) return
    dirs.splice(at, 1)
    persistDirs(dirs)
  }

  function dirArgs() {
    var parts = watchDirs.split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var dir = parts[i].trim()
      if (dir !== "") out.push(dir)
    }
    return out
  }

  function refresh() {
    if (scan.running) return
    scanning = true
    var dirs = dirArgs()
    if (dirs.length === 0) {
      pending = []
      watched = []
      scanned = 0
      scanning = false
      return
    }
    scan.command = ["bash", scriptPath, String(maxDepth)].concat(dirs)
    scan.running = true
  }

  // lazygit's -p opens a specific repository, so each row gets its own window
  // rather than stealing focus from a lazygit already open on another repo.
  // execArgv over bar.run: the path reaches bash as a positional parameter, so
  // a folder named with a space or a $(...) stays a literal path.
  function openRepo(repo) {
    if (!repo) return
    Util.execArgv(["omarchy-launch-tui", "lazygit", "-p", String(repo.path)])
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

  onWatchDirsChanged: refresh()
  Component.onCompleted: refresh()

  Process {
    id: scan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.pending = result.pending || []
          root.watched = result.watched || []
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
    function watch(dir: string): string { root.addDir(dir); return root.watchDirs }
    function unwatch(dir: string): string { root.removeDir(dir); return root.watchDirs }
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
      // Keys.BeforeItem means this catcher sees keys even when the add field
      // has focus, so every letter typed into it would drive the cursor
      // instead. Stand down while the field is being edited.
      blocked: addField.activeFocus
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
              text: "PENDING TO SYNC"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.unsynced && root.lastError === ""
              width: parent.width
              text: root.watched.length === 0
                ? "No folders watched yet. Add one below."
                : "Everything is committed and pushed."
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

          PanelSeparator { foreground: root.foreground }

          Column {
            id: folderSection
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "WATCHED FOLDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.watched
                FolderRow {
                  required property var modelData
                  width: folderSection.width
                  folder: modelData
                }
              }
            }

            // Typing a path is the whole editor: no config file, no picker
            // process. The folder's own row reports back whether it exists.
            TextField {
              id: addField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Add a folder, e.g. ~/work"
              onAccepted: {
                root.addDir(text)
                text = ""
              }
              // Escape leaves the field rather than closing the panel, so a
              // half-typed path can be abandoned without losing the popup.
              Keys.onEscapePressed: {
                text = ""
                keyCatcher.forceActiveFocus()
              }

              // The key catcher holds focus for the whole panel, and a press on
              // the field alone does not take it back, so the field stays deaf
              // to typing. Claim focus on press and let the event fall through
              // so the caret still lands where the click did.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onPressed: function(mouse) {
                  addField.forceActiveFocus()
                  mouse.accepted = false
                }
              }
            }
          }
        }
      }
    }
  }

  component FolderRow: Item {
    id: folderRow
    property var folder: null
    readonly property string folderPath: folder ? String(folder.path) : ""
    readonly property string folderState: folder ? String(folder.state) : "ok"
    readonly property string meta: {
      if (folderState === "missing") return "does not exist"
      if (folderState === "empty") return "no git repos"
      var repos = folder ? Number(folder.repos) : 0
      var pending = folder ? Number(folder.pending) : 0
      var count = repos + (repos === 1 ? " repo" : " repos")
      return pending > 0 ? count + " · " + pending + " pending" : count + " · all synced"
    }

    implicitHeight: Math.max(folderLabels.implicitHeight, removeButton.implicitHeight)
      + Style.space(4)

    Column {
      id: folderLabels
      anchors.left: parent.left
      anchors.right: removeButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: folderRow.folderPath
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: folderRow.meta
        color: folderRow.folderState === "missing" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      id: removeButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\uf00d"
      tooltipText: "Stop watching this folder"
      foreground: root.foreground
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      onClicked: root.removeDir(folderRow.folderPath)
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
