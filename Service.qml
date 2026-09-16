import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One instance per shell: characters on disk, this week's affixes, and the
// per-character weekly data from Raider.io (plus Blizzard lockouts when the
// optional client credentials are set). Widgets and the panel all read this.
//
// Process boundary: the only program this service starts is python3 from a
// fixed absolute path (Model.PYTHON_CANDIDATES), always with the session
// environment cleared. Every job runs bin/wow-reset-ops under bin/bounded-run
// (output caps, deadline, race-free process-group termination). There is no
// shell and no PATH lookup; if no trusted python3 exists, nothing runs.
Item {
  id: root

  property var shell: null
  property var settings: ({})
  property bool active: true

  readonly property string pluginDir: {
    var text = String(Qt.resolvedUrl("."))
    if (text.indexOf("file://") === 0) text = decodeURIComponent(text.substring(7))
    if (text.length > 1 && text.charAt(text.length - 1) === "/") text = text.substring(0, text.length - 1)
    return text
  }
  readonly property var processEnvironment: Model.processEnvironment()

  property string python: ""
  property bool toolsReady: false
  property string toolsError: ""
  property int _pythonCandidate: 0
  property bool _probeStarted: false
  property bool _probeSettled: true

  readonly property string region: Model.validRegion(setting("region", "US")) || "us"
  readonly property string icon: Model.validIcon(setting("icon", "Sword"))
  // faction -> absolute path of the cached emblem mask.
  property var emblemPaths: ({})

  property var characters: []
  property var characterData: ({})
  property var affixes: null
  property bool blizzard: false
  property bool loaded: false
  property bool pendingSave: false
  property bool refreshing: false
  property bool looking: false
  property bool savingCredentials: false
  property string lastError: ""
  property string actionStatus: ""
  property int revision: 0
  property double refreshedAtMs: 0
  property double nowMs: Date.now()

  readonly property double nextResetAt: Model.nextResetMs(region, nowMs)
  readonly property bool busy: refreshing || looking || savingCredentials || opsJob.running

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function dataFor(character) {
    return characterData[Model.characterKey(character)] || null
  }

  // ------------------------------------------------------ Trusted python --

  function resolvePython() {
    if (toolsReady || !_probeSettled) return
    _pythonCandidate = 0
    startPythonProbe()
  }

  function startPythonProbe() {
    var candidates = Model.PYTHON_CANDIDATES
    if (_pythonCandidate >= candidates.length) {
      toolsError = "Python 3 was not found in " + candidates.join(", ")
        + " — WoW Reset will not run anything from your PATH"
      lastError = toolsError
      return
    }
    _probeStarted = false
    _probeSettled = false
    pythonProbe.command = Model.pythonProbeCommand(candidates[_pythonCandidate])
    pythonProbe.running = true
  }

  Process {
    id: pythonProbe
    running: false
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    workingDirectory: "/"
    onStarted: root._probeStarted = true
    onExited: function(exitCode) {
      if (root._probeSettled) return
      root._probeSettled = true
      if (!root._probeStarted || exitCode !== 0) { root._pythonCandidate++; root.startPythonProbe(); return }
      root.python = Model.trustedPython(Model.PYTHON_CANDIDATES[root._pythonCandidate])
      root.toolsError = ""
      root.toolsReady = root.python !== ""
      if (root.toolsReady) root.loadConfig()
    }
    onRunningChanged: {
      if (running || root._probeSettled || root._probeStarted) return
      root._probeSettled = true
      root._pythonCandidate++
      root.startPythonProbe()
    }
  }

  // --------------------------------------------------------------- Config --

  function loadConfig() {
    if (loaded || loadJob.running) return
    if (!toolsReady) { resolvePython(); return }
    if (!loadJob.start(Model.helperCommand(python, pluginDir, "load"), JSON.stringify({ op: "load" })))
      lastError = "Could not start the WoW Reset helper"
  }

  HelperJob {
    id: loadJob
    jobEnvironment: root.processEnvironment
    onJobFinished: function(exitCode, stdoutText, stderrText) {
      var failure = Model.jobFailure(exitCode, "The settings helper")
      var parsed = Model.parseOps(stdoutText)
      if (failure !== "" || !parsed.ok || !parsed.config) {
        // Not marked loaded: nothing is saved over settings we could not
        // read safely. Refresh (or reopening) tries again.
        root.lastError = Model.conciseError(failure || parsed.error, "Could not read your characters")
        return
      }
      root.characters = parsed.config.characters
      root.blizzard = parsed.blizzard
      root.lastError = parsed.error || ""
      root.loaded = true
      root.revision += 1
      if (root.pendingSave) { root.pendingSave = false; root.persist() }
      root.refresh()
      root.ensureEmblem()
    }
  }

  function persist() {
    if (!loaded) return
    if (saveJob.running) { pendingSave = true; return }
    var payload = JSON.stringify({ op: "save", config: { version: 1, characters: characters } })
    if (!saveJob.start(Model.helperCommand(python, pluginDir, "save"), payload))
      lastError = "Could not save your characters"
  }

  HelperJob {
    id: saveJob
    jobEnvironment: root.processEnvironment
    onJobFinished: function(exitCode, stdoutText, stderrText) {
      var failure = Model.jobFailure(exitCode, "The settings helper")
      var parsed = Model.parseOps(stdoutText)
      if (failure !== "" || exitCode !== 0 || !parsed.ok)
        root.lastError = Model.conciseError(failure || parsed.error, "Could not save your characters")
      if (root.pendingSave) { root.pendingSave = false; root.persist() }
    }
  }

  Component.onCompleted: if (active) loadConfig()
  onActiveChanged: if (active && !loaded) loadConfig()
  onIconChanged: ensureEmblem()

  function ensureEmblem() {
    if (!loaded || icon === "sword" || emblemPaths[icon]) return
    runOps({ op: "emblem", faction: icon }, "emblem")
  }

  onRegionChanged: {
    affixes = null
    if (loaded) runOps({ op: "affixes", region: region }, "affixes")
  }

  // -------------------------------------------------------------- Actions --

  function refresh() {
    if (!loaded) { loadConfig(); return }
    lastError = ""
    runOps({ op: "affixes", region: region }, "affixes")
    if (characters.length > 0) runOps({ op: "characters", characters: characters }, "characters")
  }

  function addCharacter(name, realm) {
    var cleanName = Model.validName(name)
    var cleanRealm = Model.validRealm(realm)
    if (cleanName === "") { lastError = "Enter the character name (letters only)"; return }
    if (cleanRealm === "") { lastError = "Enter the realm name"; return }
    var candidate = { region: region, name: cleanName, realm: cleanRealm }
    if (Model.alreadyOnList(characters, candidate)) {
      actionStatus = cleanName + " is already on the list"
      statusTimer.restart()
      return
    }
    if (characters.length >= Model.MAX_CHARACTERS) { lastError = "Twelve characters is the limit"; return }
    lastError = ""
    runOps({ op: "lookup", region: region, name: cleanName, realm: cleanRealm }, "lookup")
  }

  function removeCharacter(character) {
    characters = Model.withoutCharacter(characters, character)
    var data = {}
    for (var key in characterData) if (key !== Model.characterKey(character)) data[key] = characterData[key]
    characterData = data
    revision += 1
    persist()
  }

  function saveBlizzard(clientId, clientSecret) {
    lastError = ""
    runOps({ op: "set_blizzard", clientId: String(clientId || ""), clientSecret: String(clientSecret || "") }, "set_blizzard")
  }

  function clearBlizzard() {
    runOps({ op: "clear_blizzard" }, "clear_blizzard")
  }

  // --------------------------------------------------------------- Queue --

  property var _queue: []
  property string _kind: ""

  function runOps(payload, kind) {
    if (!toolsReady) {
      lastError = toolsError !== "" ? toolsError : "Still looking for Python 3"
      resolvePython()
      return
    }
    // One queued job per kind: a newer request replaces an older one.
    var queue = []
    for (var i = 0; i < _queue.length; i++) if (_queue[i].kind !== kind) queue.push(_queue[i])
    queue.push({ payload: payload, kind: kind })
    _queue = queue
    startNext()
  }

  function startNext() {
    if (opsJob.running || _queue.length === 0) return
    var next = _queue[0]
    _queue = _queue.slice(1)
    _kind = next.kind
    refreshing = next.kind === "characters" || next.kind === "affixes"
    looking = next.kind === "lookup"
    savingCredentials = next.kind === "set_blizzard"
    // Names, realms and credentials go over stdin, never argv.
    if (!opsJob.start(Model.helperCommand(python, pluginDir, next.kind), JSON.stringify(next.payload))) {
      _kind = ""
      refreshing = looking = savingCredentials = false
      lastError = "Could not start the WoW Reset helper"
    }
  }

  HelperJob {
    id: opsJob
    jobEnvironment: root.processEnvironment
    onJobFinished: function(exitCode, stdoutText, stderrText) {
      root.finishOps(exitCode, stdoutText)
      Qt.callLater(root.startNext)
    }
  }

  function finishOps(exitCode, stdoutText) {
    var kind = _kind
    _kind = ""
    refreshing = looking = savingCredentials = false
    var who = kind === "set_blizzard" || kind === "clear_blizzard" ? "Battle.net"
      : (kind === "emblem" ? "warcraft.wiki.gg" : "Raider.io")
    var failure = Model.jobFailure(exitCode, who)
    if (failure !== "") { lastError = failure; return }
    var parsed = Model.parseOps(stdoutText)
    if (exitCode !== 0 || !parsed.ok) {
      lastError = Model.conciseError(parsed.error, "Could not reach " + who)
      return
    }
    if (parsed.error) lastError = parsed.error

    if (kind === "emblem" && parsed.emblem) {
      var paths = {}
      for (var f in emblemPaths) paths[f] = emblemPaths[f]
      paths[parsed.emblem.faction] = parsed.emblem.path
      emblemPaths = paths
    } else if (kind === "affixes" && parsed.affixes) {
      affixes = parsed.affixes
    } else if (kind === "lookup" && parsed.character) {
      var character = parsed.character
      if (!Model.alreadyOnList(characters, character) && characters.length < Model.MAX_CHARACTERS) {
        var next = characters.slice()
        next.push(character)
        characters = next
        persist()
        actionStatus = "Added " + character.name + " – " + character.realm
        statusTimer.restart()
        runOps({ op: "characters", characters: characters }, "characters")
      }
    } else if (kind === "characters") {
      var data = {}
      for (var i = 0; i < parsed.characters.length; i++) data[Model.characterKey(parsed.characters[i])] = parsed.characters[i]
      characterData = data
      refreshedAtMs = Date.now()
    } else if (kind === "set_blizzard") {
      blizzard = parsed.blizzard
      actionStatus = "Battle.net connected — fetching lockouts"
      statusTimer.restart()
      if (characters.length > 0) runOps({ op: "characters", characters: characters }, "characters")
    } else if (kind === "clear_blizzard") {
      blizzard = parsed.blizzard
      actionStatus = "Battle.net credentials removed"
      statusTimer.restart()
      if (characters.length > 0) runOps({ op: "characters", characters: characters }, "characters")
    }
    revision += 1
  }

  Timer {
    id: statusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // Clock, and a refresh a few minutes after each reset so the new week's
  // affixes and a clean lockout show up without waiting for the hourly pass.
  property double _refreshAfter: 0

  Timer {
    interval: 30000
    repeat: true
    running: root.active
    onTriggered: {
      var before = root.nextResetAt
      root.nowMs = Date.now()
      if (root.nextResetAt !== before) root._refreshAfter = before + 5 * 60000
      if (root._refreshAfter > 0 && root.nowMs >= root._refreshAfter) {
        root._refreshAfter = 0
        root.refresh()
      }
    }
  }

  Timer {
    interval: 60 * 60 * 1000
    repeat: true
    running: root.active
    onTriggered: root.refresh()
  }
}
