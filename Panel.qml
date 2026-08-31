import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "qs-yadm"
  ipcTarget: "qs-yadm"
  manageIpc: false

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string backendPath: homeDir + "/.config/omarchy/plugins/qs-yadm/backend.py"
  property var files: []
  property var selectedIds: []
  property var pendingIds: []
  property var commitQueue: []
  property var activeCommitIds: []
  property var diffData: ({})
  property bool diffView: false
  property bool loading: false
  property bool syncing: false
  property string errorText: ""
  property string branch: ""
  property int ahead: 0
  property int behind: 0
  property int added: 0
  property int deleted: 0
  property real lastSyncAt: 0
  property int fileIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var visibleFiles: {
    var result = []
    for (var i = 0; i < files.length; i++)
      if (pendingIds.indexOf(files[i].id) === -1) result.push(files[i])
    return result
  }
  readonly property int changedCount: visibleFiles.length

  function parse(text) {
    try { return JSON.parse(String(text || "{}")) }
    catch (e) { return { ok: false, error: "Invalid qs-yadm backend response" } }
  }

  function applyStatus(data) {
    if (!data || data.ok !== true) {
      errorText = String(data && data.error ? data.error : "Could not read yadm status")
      return
    }
    files = data.files || []
    branch = String(data.branch || "")
    ahead = Number(data.ahead || 0)
    behind = Number(data.behind || 0)
    added = Number(data.added || 0)
    deleted = Number(data.deleted || 0)
    errorText = String(data.error || "")
    lastSyncAt = Number(data.lastSyncAt || 0)
    var kept = []
    for (var i = 0; i < selectedIds.length; i++)
      for (var j = 0; j < files.length; j++)
        if (files[j].id === selectedIds[i] && kept.indexOf(selectedIds[i]) === -1) kept.push(selectedIds[i])
    selectedIds = kept
    if (fileIndex >= visibleFiles.length) fileIndex = Math.max(0, visibleFiles.length - 1)
  }

  function refresh() {
    if (statusProcess.running) return
    loading = true
    statusProcess.command = ["python3", backendPath, "status"]
    statusProcess.running = true
  }

  function sync() {
    if (syncProcess.running) return
    syncing = true
    syncProcess.command = ["python3", backendPath, "sync"]
    syncProcess.running = true
  }

  function containsSelected(id) { return selectedIds.indexOf(id) !== -1 }

  function toggleSelected(id) {
    var next = selectedIds.slice()
    var index = next.indexOf(id)
    if (index === -1) next.push(id)
    else next.splice(index, 1)
    selectedIds = next
  }

  function enqueueCommit(ids) {
    if (!ids || ids.length === 0) return
    var unique = []
    for (var i = 0; i < ids.length; i++)
      if (unique.indexOf(ids[i]) === -1 && pendingIds.indexOf(ids[i]) === -1) unique.push(ids[i])
    if (unique.length === 0) return
    pendingIds = pendingIds.concat(unique)
    var queue = commitQueue.slice()
    queue.push(unique)
    commitQueue = queue
    selectedIds = selectedIds.filter(function(id) { return unique.indexOf(id) === -1 })
    startNextCommit()
  }

  function startNextCommit() {
    if (commitProcess.running || commitQueue.length === 0) return
    var queue = commitQueue.slice()
    activeCommitIds = queue.shift()
    commitQueue = queue
    var command = ["python3", backendPath, "commit"]
    for (var i = 0; i < activeCommitIds.length; i++) command.push(activeCommitIds[i])
    commitProcess.command = command
    commitProcess.running = true
  }

  function finishCommit() {
    var completed = activeCommitIds.slice()
    pendingIds = pendingIds.filter(function(id) { return completed.indexOf(id) === -1 })
    activeCommitIds = []
    refresh()
    Qt.callLater(startNextCommit)
  }

  function showDiff(id) {
    if (diffProcess.running) return
    diffData = ({})
    diffProcess.command = ["python3", backendPath, "diff", id]
    diffProcess.running = true
  }

  function activateCurrent() {
    if (diffView) return
    if (selectedIds.length > 0) {
      enqueueCommit(selectedIds.slice())
      return
    }
    if (visibleFiles.length > 0) enqueueCommit([visibleFiles[Math.max(0, Math.min(fileIndex, visibleFiles.length - 1))].id])
  }

  function toggleCurrentSelection() {
    if (diffView || visibleFiles.length === 0) return
    var index = Math.max(0, Math.min(fileIndex, visibleFiles.length - 1))
    toggleSelected(visibleFiles[index].id)
  }

  function open() {
    refresh()
    controller.show()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  IpcHandler {
    target: "qs-yadm"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function sync(): string { root.sync(); return "ok" }
    function status(): string { return root.errorText !== "" ? root.errorText : (root.changedCount + " changed") }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.errorText !== "" ? ("Yadm — " + root.errorText)
      : root.changedCount > 0 ? ("Yadm — " + root.changedCount + (root.changedCount === 1 ? " changed file" : " changed files"))
      : "Yadm — clean"
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.ceil(barRow.implicitWidth + Style.space(12))
    fixedHeight: root.vertical ? Math.ceil(barRow.implicitHeight + Style.space(8)) : -1

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        text: "Y"
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        font.bold: true
        renderType: Text.NativeRendering
      }
      Text {
        visible: root.changedCount > 0
        text: String(root.changedCount)
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }
      Text {
        visible: root.errorText !== ""
        text: "!"
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.sync()
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
    contentWidth: panel.fittedContentWidth(Style.space(root.diffView ? 640 : 400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.diffView) root.diffView = false
          else root.close()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Down || event.text === "j") {
          if (!root.diffView) {
            root.cursorActive = true
            root.fileIndex = Math.max(0, Math.min(root.visibleFiles.length - 1, root.fileIndex + 1))
          }
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up || event.text === "k") {
          if (!root.diffView) {
            root.cursorActive = true
            root.fileIndex = Math.max(0, Math.min(root.visibleFiles.length - 1, root.fileIndex - 1))
          }
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Right || event.text === "l") {
          if (!root.diffView && root.visibleFiles.length > 0) {
            root.cursorActive = true
            root.showDiff(root.visibleFiles[Math.max(0, Math.min(root.fileIndex, root.visibleFiles.length - 1))].id)
          }
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Left || event.text === "h") {
          if (root.diffView) root.diffView = false
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateCurrent()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Space) {
          root.toggleCurrentSelection()
          event.accepted = true
          return
        }
        if (event.text === "r" || event.text === "R") {
          root.sync()
          event.accepted = true
          return
        }
        if ((event.text === "d" || event.text === "D") && !root.diffView && root.visibleFiles.length > 0) {
          root.showDiff(root.visibleFiles[Math.max(0, Math.min(root.fileIndex, root.visibleFiles.length - 1))].id)
          event.accepted = true
          return
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.diffView ? String(root.diffData.file ? root.diffData.file.display : "Diff") : "Yadm"
            meta: root.syncing ? "PULLING OR PUSHING…" : root.loading ? "READING DOTFILES…"
              : root.errorText !== "" ? "ACTION REQUIRED"
              : root.changedCount === 0 ? "WORKTREE CLEAN"
              : (root.branch.toUpperCase() + " · " + root.changedCount + " CHANGED")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.errorText !== "" ? "Y!" : "Y"
                color: root.errorText !== "" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }
            }
          }

          RowLayout {
            visible: !root.diffView
            width: parent.width
            spacing: Style.space(12)
            Text { text: "+" + root.added; color: "#6aa56a"; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Text { text: "−" + root.deleted; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Text { text: root.ahead > 0 ? (root.ahead + " ahead") : "Synced"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body; Layout.fillWidth: true }
            PanelActionButton {
              iconText: "󰑓"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.syncing
              onClicked: root.sync()
            }
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { visible: !root.diffView; foreground: root.foreground }

          Column {
            visible: !root.diffView
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.selectedIds.length > 0 ? (root.selectedIds.length + " SELECTED · ENTER TO COMMIT") : "CHANGED FILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.changedCount === 0
              width: parent.width
              text: root.pendingIds.length > 0 ? "Committing in the background…" : "Everything is committed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleFiles
              delegate: CursorSurface {
                id: fileRow
                required property var modelData
                required property int index
                width: parent.width
                foreground: root.foreground
                hasCursor: root.cursorActive && root.fileIndex === index
                implicitHeight: rowLayout.implicitHeight + Style.space(16)

                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.fileIndex = fileRow.index }
                  onClicked: function(mouse) {
                    root.fileIndex = fileRow.index
                    if (mouse.button === Qt.RightButton) root.showDiff(fileRow.modelData.id)
                    else if (mouse.modifiers & Qt.ControlModifier) root.toggleSelected(fileRow.modelData.id)
                    else root.enqueueCommit([fileRow.modelData.id])
                  }
                }

                RowLayout {
                  id: rowLayout
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Item {
                    Layout.preferredWidth: checkbox.implicitWidth + Style.space(4)
                    Layout.preferredHeight: checkbox.implicitHeight + Style.space(4)

                    Text {
                      id: checkbox
                      anchors.centerIn: parent
                      text: root.containsSelected(fileRow.modelData.id) ? "☑" : "□"
                      color: root.containsSelected(fileRow.modelData.id) ? Color.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      anchors.fill: parent
                      acceptedButtons: Qt.LeftButton
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: { root.cursorActive = true; root.fileIndex = fileRow.index }
                      onClicked: root.toggleSelected(fileRow.modelData.id)
                    }
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)
                    Text {
                      Layout.fillWidth: true
                      text: String(fileRow.modelData.display)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideMiddle
                    }
                    Text {
                      Layout.fillWidth: true
                      text: String(fileRow.modelData.status) + "  +" + fileRow.modelData.added + "  −" + fileRow.modelData.deleted
                        + (fileRow.modelData.binary ? "  binary" : "")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Text {
                    text: "↵"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                }
              }
            }
          }

          Column {
            visible: root.diffView
            width: parent.width
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              PanelActionButton {
                iconText: "󰁍"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.diffView = false
              }
              Text {
                text: root.diffData.file ? ("+" + root.diffData.file.added + "  −" + root.diffData.file.deleted) : "Loading…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.fillWidth: true
              }
            }
            Repeater {
              model: root.diffData.lines || []
              delegate: Rectangle {
                required property var modelData
                width: parent.width
                implicitHeight: diffLine.implicitHeight + Style.space(2)
                color: modelData.kind === "add" ? Qt.rgba(0.2, 0.7, 0.35, 0.14)
                  : modelData.kind === "delete" ? Qt.rgba(0.9, 0.25, 0.25, 0.14)
                  : modelData.kind === "hunk" ? Qt.rgba(0.3, 0.5, 0.9, 0.14) : "transparent"
                Text {
                  id: diffLine
                  width: parent.width
                  text: String(parent.modelData.text)
                  color: parent.modelData.kind === "add" ? "#6aa56a"
                    : parent.modelData.kind === "delete" ? root.urgent
                    : parent.modelData.kind === "hunk" ? Color.accent : root.foreground
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                }
              }
            }
            Text {
              visible: root.diffData.truncated === true
              width: parent.width
              text: "Diff truncated after 5,000 lines or 1 MB."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.sync()
  }

  Process {
    id: statusProcess
    command: []
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      root.applyStatus(root.parse(statusOutput.text))
    }
  }
  Process {
    id: syncProcess
    command: []
    stdout: StdioCollector { id: syncOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.syncing = false
      var data = root.parse(syncOutput.text)
      if (data.ok !== true) root.errorText = String(data.error || "Yadm pull failed")
      root.refresh()
    }
  }
  Process {
    id: commitProcess
    command: []
    stdout: StdioCollector { id: commitOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var data = root.parse(commitOutput.text)
      if (data.ok !== true) root.errorText = String(data.error || "Yadm commit failed")
      root.finishCommit()
    }
  }
  Process {
    id: diffProcess
    command: []
    stdout: StdioCollector { id: diffOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var data = root.parse(diffOutput.text)
      if (data.ok === true) { root.diffData = data; root.diffView = true; flick.contentY = 0 }
      else root.errorText = String(data.error || "Could not load diff")
    }
  }
}
