import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "com.github.linuxgameruk.omatiel"
  ipcTarget: "com.github.linuxgameruk.omatiel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // Widget settings live on the BarWidget instance (injected by the shell);
  // this panel is loaded eagerly by the host's Loader, so resolve through it.
  readonly property var settings: hostWidget && hostWidget.settings ? hostWidget.settings : ({})

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color success: "#4ade80"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusText: {
    if (llama.busy) return llama.actionLabel
    if (!llama.hasService) return "No service"
    if (llama.running) return "Running"
    return "Stopped"
  }
  readonly property color statusColor: {
    if (llama.busy) return foreground
    if (!llama.hasService) return urgent
    if (llama.running) return success
    return dim
  }
  readonly property string toggleHint: {
    if (!llama.hasService) return ""
    return llama.running ? "Turn Tiel-Coder off" : "Turn Tiel-Coder on"
  }
  property string focusSection: "header"
  property bool cursorActive: false

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    llama.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  Service {
    id: llama
    settings: root.settings
  }
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function startService(): string { llama.startService(); return "ok" }
    function stopService(): string { llama.stopService(); return "ok" }
    function refresh(): string { llama.refresh(); return "ok" }
    function status(): string { return llama.statusJson() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
      }
      onActivateRequested: {
        if (root.cursorActive && root.focusSection === "header") llama.toggleService()
      }
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "s" || t === "S") llama.startService()
        else if (t === "x" || t === "X") llama.stopService()
        else if (t === "r" || t === "R") llama.refresh()
      }
    }

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

        // ── Hero ────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            // Nerd Font chip glyph — literal PUA character
            text: "󰍛"
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            textFormat: Text.PlainText
            opacity: llama.hasService ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          RowLayout {
            id: heroActions
            spacing: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            ToggleSwitch {
              id: powerSwitch
              visible: llama.hasService
              checked: llama.running
              busy: llama.busy
              hasCursor: root.cursorActive && root.focusSection === "header"
              foreground: root.foreground
              Layout.alignment: Qt.AlignVCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
              onToggled: llama.toggleService()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.fontFamily
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "OmaTiel"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.statusText.toUpperCase()
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }
        }

        // ── Error / state hint ─────────────────────────────────────
        Text {
          visible: llama.lastError !== "" || llama.actionableState() !== ""
          width: parent.width
          text: llama.sanitize(llama.lastError !== "" ? llama.lastError : llama.actionableState())
          color: llama.lastError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }

        // ── Service details ─────────────────────────────────────────
        Column {
          visible: llama.hasService
          width: parent.width
          spacing: Style.spacing.labelGap

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: "Status" }
            InfoValue {
              text: llama.running ? "Running" : "Stopped"
              color: root.statusColor
            }

            InfoLabel { visible: llama.running && llama.vramTotal !== ""; text: "VRAM" }
            InfoValue {
              visible: llama.running && llama.vramTotal !== ""
              text: llama.vramUsed !== "" ? llama.vramUsed + " / " + llama.vramTotal : "—"
            }

            InfoLabel {
              visible: llama.running && llama.servedModel !== ""
              text: "Model"
            }
            InfoValue {
              visible: llama.running && llama.servedModel !== ""
              text: llama.sanitize(llama.servedModel)
            }

            InfoLabel {
              visible: llama.running && llama.servedCtx > 0
              text: "Context"
            }
            InfoValue {
              visible: llama.running && llama.servedCtx > 0
              text: llama.servedCtx.toLocaleString("en-GB")
            }

            InfoLabel { text: "Unit" }
            InfoValue { text: llama.sanitize(llama.unitName + ".service") }

            InfoLabel { text: "Port" }
            InfoValue { text: String(llama.port) }
          }
        }

        // ── Tuning footnote ─────────────────────────────────────────
        PanelSeparator {
          visible: llama.running
          foreground: root.foreground
        }

        Text {
          visible: llama.running
          width: parent.width
          text: "Tuned posture: 262k ctx · MTP draft on · experts parked in RAM (ncmoe 36). Config lives in tiel-coder.service — edit there, not here."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ── Inline components matching Omarchy panel style ──────────────────

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }
}
