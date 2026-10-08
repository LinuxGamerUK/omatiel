import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var settings: ({})

  // ── State ─────────────────────────────────────────────────────────
  property bool hasService: false      // <unitName>.service user unit exists
  property bool running: false
  property bool busy: false
  property string actionLabel: ""
  property string lastError: ""

  // ── API probe ─────────────────────────────────────────────────────
  property string servedModel: ""      // basename of what the server serves
  property int servedCtx: -1           // n_ctx the server enforces

  // ── GPU info (NVIDIA only; silently absent elsewhere) ─────────────
  property bool gpuUsable: false
  property string vramUsed: ""         // e.g. "8.4 G"
  property string vramTotal: ""        // e.g. "12 G"
  property string activeSince: ""

  // ── Process deadlines (timeout primary + QML watchdog backup) ─────
  readonly property int processTimeoutSec: 8
  readonly property int actionTimeoutSec: 12
  readonly property int watchdogMs: 12000

  // ── Output caps at the OS pipe level ──────────────────────────────
  readonly property int capCheck: 256
  readonly property int capApi: 2048
  readonly property int capGpu: 128
  readonly property int capAction: 1024

  // ── Colors (icon states; explicit so they don't shift per theme) ──
  readonly property color runGreen: "#4ade80"
  readonly property color offRed: "#f87171"
  readonly property color unsetDim: "#6b7280"

  // ── Settings ──────────────────────────────────────────────────────
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)
  readonly property string unitName: String(setting("unitName", "tiel-coder") || "tiel-coder").trim()
  readonly property int port: intSetting("port", 8080, 1024, 65535)
  readonly property bool unitNameSafe: /^[A-Za-z0-9_.@-]+$/.test(unitName)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  function _actionError(output, verb) {
    var s = String(output || "").trim()
    if (/request dismissed|dismissed by user|cancelled|canceled/i.test(s)) {
      return (verb === "start" ? "Start" : "Stop") + " cancelled."
    }
    if (/failed|error/i.test(s)) {
      return "Failed to " + verb + " " + unitName + ".service:\n" + truncate(s, 240) +
             "\nDetails: journalctl --user -u " + unitName + " -n 20"
    }
    return "Failed to " + verb + " " + unitName + ".service" + (s !== "" ? ": " + truncate(s, 160) : "")
  }

  // ── Process lifecycle helpers ─────────────────────────────────────
  function launch(process, watchdog) {
    if (!process.running) {
      process.running = true
      watchdog.restart()
    }
  }

  function reap(process, watchdog) {
    watchdog.stop()
    if (process.running) process.running = false
  }

  function refresh() {
    if (!unitNameSafe) return
    launch(checkProcess, checkWatchdog)
  }

  function startService() {
    if (busy || !hasService) {
      if (!hasService) lastError = actionableState()
      return
    }
    busy = true
    actionLabel = "Starting " + unitName + "…"
    lastError = ""
    startProcess.running = true
    startActionWatchdog.restart()
  }

  function stopService() {
    if (busy || !hasService) return
    busy = true
    actionLabel = "Stopping " + unitName + "…"
    lastError = ""
    stopProcess.running = true
    stopActionWatchdog.restart()
  }

  function toggleService() {
    if (!hasService) {
      lastError = actionableState()
      refresh()
      return
    }
    if (running) stopService()
    else startService()
  }

  function actionableState() {
    if (!hasService) {
      return "No \"" + unitName + ".service\" user unit found.\n" +
        "Install it per Reference/Local_LLM.md (§Live config)."
    }
    return ""
  }

  // Debug channel (bounded): runtime state over IPC.
  function statusJson() {
    return JSON.stringify({
      hasService: hasService,
      running: running,
      unitName: unitName,
      servedModel: servedModel,
      servedCtx: servedCtx,
      vramUsed: vramUsed,
      vramTotal: vramTotal
    })
  }

  // ── Output buffers (each capped) ──────────────────────────────────

  property string _checkBuffer: ""
  property string _apiBuffer: ""
  property string _gpuBuffer: ""
  property string _startBuffer: ""
  property string _stopBuffer: ""

  function bufferedAppend(buffer, line, cap) {
    var s = String(line || "")
    if (buffer.length + s.length + 1 <= cap) return buffer + s + "\n"
    return buffer
  }

  // One probe covers existence + active state in a single fork:
  //   UNIT:<0|1> ACTIVE:<0|1>
  function _parseCheck() {
    var output = truncate(_checkBuffer.trim(), 256)
    _checkBuffer = ""
    var unitToken = /UNIT:([01])/.exec(output)
    var activeToken = /ACTIVE:([01])/.exec(output)
    var wasRunning = running
    hasService = unitToken ? unitToken[1] === "1" : false
    running = activeToken ? activeToken[1] === "1" : false
    if (running) {
      launch(apiProcess, apiWatchdog)
      launch(gpuProcess, gpuWatchdog)
    } else if (wasRunning) {
      servedModel = ""
      servedCtx = -1
    }
  }

  function _parseApi() {
    var raw = truncate(_apiBuffer.trim(), 2048)
    _apiBuffer = ""
    if (raw === "" || raw.charAt(0) !== "{") { servedModel = ""; servedCtx = -1; return }
    try {
      var obj = JSON.parse(raw)
      var data = Array.isArray(obj && obj.data) ? obj.data : []
      var m = data.length > 0 ? data[0] : null
      var id = m && typeof m.id === "string" ? m.id : ""
      var base = id.split("/").pop() || id
      servedModel = truncate(base, 160)
      var ctx = m && m.meta && m.meta.n_ctx
      servedCtx = Number.isFinite(ctx) && ctx > 0 ? ctx : -1
    } catch (e) {
      servedModel = ""
      servedCtx = -1
    }
  }

  function _parseGpu() {
    var raw = truncate(_gpuBuffer.trim(), 128)
    _gpuBuffer = ""
    if (raw === "") { gpuUsable = false; vramUsed = ""; vramTotal = ""; return }
    var parts = raw.split(",").map(function(x) { return parseInt(String(x).trim(), 10) })
    var usedMiB = isFinite(parts[0]) ? parts[0] : -1
    var totalMiB = isFinite(parts[1]) ? parts[1] : -1
    if (usedMiB < 0) { gpuUsable = false; vramUsed = ""; vramTotal = ""; return }
    gpuUsable = true
    vramUsed = (usedMiB / 1024).toFixed(1) + " G"
    vramTotal = totalMiB > 0 ? (totalMiB / 1024).toFixed(0) + " G" : ""
  }

  // ── Processes ──────────────────────────────────────────────────────
  //
  // Every command: `timeout -k 2 N` (process-group killer) wrapping
  // `bash -c "set -o pipefail; … | head -c CAP"` (OS-pipe-level output
  // cap). Output parsed only when exitCode === 0 (124/137/141 discarded).
  // The unit name travels via environment or is a pre-validated
  // [A-Za-z0-9_.@-] string; never raw user text inside quotes.

  Process {
    id: checkProcess
    running: false
    environment: ({ "PLUGIN_UNIT": root.unitName })
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; u=\"$PLUGIN_UNIT\"; " +
              "ue=$(systemctl --user list-unit-files \"$u.service\" --no-legend 2>/dev/null | head -c 64); " +
              "a=$(systemctl --user is-active \"$u.service\" 2>/dev/null); " +
              "echo \"UNIT:$([ -n \"$ue\" ] && echo 1 || echo 0)ACTIVE:$([ \"$a\" = active ] && echo 1 || echo 0)\" | head -c " + root.capCheck]
    stdout: SplitParser { onRead: function(line) { root._checkBuffer = root.bufferedAppend(root._checkBuffer, line, root.capCheck) } }
    onExited: function(exitCode) {
      checkWatchdog.stop()
      if (exitCode === 0) _parseCheck()
      else { _checkBuffer = ""; hasService = false; running = false }
    }
  }

  Process {
    id: apiProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; curl -s --connect-timeout 2 --max-time 6 http://127.0.0.1:" + root.port + "/v1/models 2>/dev/null | head -c " + root.capApi]
    stdout: SplitParser { onRead: function(line) { root._apiBuffer = root.bufferedAppend(root._apiBuffer, line, root.capApi) } }
    onExited: function(exitCode) {
      apiWatchdog.stop()
      if (exitCode === 0) _parseApi()
      else { _apiBuffer = ""; servedModel = ""; servedCtx = -1 }
    }
  }

  Process {
    id: gpuProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | head -c " + root.capGpu]
    stdout: SplitParser { onRead: function(line) { root._gpuBuffer = root.bufferedAppend(root._gpuBuffer, line, root.capGpu) } }
    onExited: function(exitCode) {
      gpuWatchdog.stop()
      if (exitCode === 0 && _gpuBuffer.trim() !== "") _parseGpu()
      else { gpuUsable = false; vramUsed = ""; vramTotal = "" }
    }
  }

  Process {
    id: startProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.actionTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl --user start \"$PLUGIN_UNIT.service\" 2>&1 | head -c " + root.capAction]
    environment: ({ "PLUGIN_UNIT": root.unitName })
    stdout: SplitParser { onRead: function(line) { root._startBuffer = root.bufferedAppend(root._startBuffer, line, root.capAction) } }
    onExited: function(exitCode) {
      startActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0 && _startBuffer.trim() !== "") lastError = _actionError(_startBuffer, "start")
      else lastError = ""
      _startBuffer = ""
      refresh()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.actionTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl --user stop \"$PLUGIN_UNIT.service\" 2>&1 | head -c " + root.capAction]
    environment: ({ "PLUGIN_UNIT": root.unitName })
    stdout: SplitParser { onRead: function(line) { root._stopBuffer = root.bufferedAppend(root._stopBuffer, line, root.capAction) } }
    onExited: function(exitCode) {
      stopActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0 && _stopBuffer.trim() !== "") lastError = _actionError(_stopBuffer, "stop")
      else lastError = ""
      _stopBuffer = ""
      refresh()
    }
  }

  // ── Watchdog timers (backup killers) ──────────────────────────────

  Timer {
    id: checkWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.checkProcess, checkWatchdog)
  }

  Timer {
    id: apiWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.apiProcess, apiWatchdog)
  }

  Timer {
    id: gpuWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.gpuProcess, gpuWatchdog)
  }

  Timer {
    id: startActionWatchdog
    interval: 18000
    repeat: false
    onTriggered: if (root.startProcess.running) root.startProcess.running = false
  }

  Timer {
    id: stopActionWatchdog
    interval: 18000
    repeat: false
    onTriggered: if (root.stopProcess.running) root.stopProcess.running = false
  }

  // ── Refresh timer ─────────────────────────────────────────────────

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    if (!unitNameSafe) {
      lastError = "unitName has invalid characters: " + unitName
      hasService = false
    } else {
      refresh()
    }
  }
}
