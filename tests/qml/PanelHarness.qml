import Quickshell
import QtQuick
import qs.Ui
import qs.Commons

// Loads the real BarWidget.qml (and through it Panel.qml and Service.qml) the
// way the bar hosts a third-party widget: a qs.Ui PluginBarApi whose shell
// facade records updateEntryInline instead of writing shell.json. Then drives
// the chip's mouse buttons and the panel's settings, and prints one RESULT
// line of JSON for tests/panel.test.sh. Run only through that script.
ShellRoot {
  id: h

  readonly property string pluginDir: Quickshell.env("WOW_PLUGIN")
  property var persisted: []
  property var results: []

  property var w: widgetLoader.item
  property var button: null
  property var panel: null
  property var link: null
  property var caption: null
  property var regionGroup: null
  property var iconGroup: null
  property var countdownSwitch: null

  function check(name, cond, detail) {
    var next = h.results.slice()
    next.push({ name: name, ok: !!cond, detail: String(detail === undefined ? "" : detail) })
    h.results = next
  }

  function finish() {
    console.log("RESULT " + JSON.stringify(h.results))
    Qt.quit()
  }

  // Depth-first search of the object tree, through popup windows and loaders.
  function find(obj, pred, seen) {
    if (!obj) return null
    seen = seen || []
    if (seen.indexOf(obj) >= 0) return null
    seen.push(obj)
    if (pred(obj)) return obj
    var kids = []
    try { if (obj.children) for (var i = 0; i < obj.children.length; i++) kids.push(obj.children[i]) } catch (e) {}
    try { if (obj.data) for (var j = 0; j < obj.data.length; j++) kids.push(obj.data[j]) } catch (e) {}
    try { if (obj.contentItem) kids.push(obj.contentItem) } catch (e) {}
    try { if (obj.item) kids.push(obj.item) } catch (e) {}
    for (var k = 0; k < kids.length; k++) {
      var found = find(kids[k], pred, seen)
      if (found) return found
    }
    return null
  }

  function findGroup(root, value) {
    return find(root, function(o) {
      return typeof o.selectedOptionIndex === "function" && JSON.stringify(o.options).indexOf(value) >= 0
    })
  }

  function findChip(group, label) {
    return find(group, function(o) { return o !== group && o.text === label && o.clicked !== undefined })
  }

  function lastWrite() { return h.persisted[h.persisted.length - 1] || {} }

  PluginBarApi {
    id: hostBar
    pluginId: "ninepointlabs.wow-reset"
    moduleName: "ninepointlabs.wow-reset"
    shell: hostShell
    foreground: "#cacccc"
    barForeground: "#cacccc"
    background: "#101315"
    urgent: "#a55555"
    barSize: 26
    _moduleWidgets: function(id) { return widgetLoader.item ? [widgetLoader.item] : [] }
    _switchPanelFrom: function(owner, direction) { return false }
    _targetBelongsToWindow: function(target, window) { return false }
  }

  QtObject {
    id: hostShell
    function serviceFor(id) { return null }
    // Same semantics as shell.qml's updateEntryInline: the entry is replaced
    // whole, minus its id, and comes back to the widget as its settings.
    function updateEntryInline(id, entry) {
      if (String(id) !== "ninepointlabs.wow-reset") return false
      var next = {}
      for (var key in entry) if (key !== "id") next[key] = entry[key]
      var log = h.persisted.slice()
      log.push(JSON.parse(JSON.stringify(next)))
      h.persisted = log
      if (widgetLoader.item) widgetLoader.item.settings = next
      return true
    }
  }

  Loader {
    id: widgetLoader
    source: "file://" + h.pluginDir + "/BarWidget.qml"
    onLoaded: {
      item.bar = hostBar
      item.settings = { region: "US", icon: "Sword", showCountdown: true, keepMe: "x" }
    }
    onStatusChanged: if (status === Loader.Error) { h.check("BarWidget.qml loads", false); h.finish() }
  }

  // One step per tick so bindings, the panel loader and the service settle in
  // between. Clicks are checked in the same tick they happen: the panel is a
  // real overlay on the live compositor, and a click elsewhere on the desktop
  // dismisses it, so its open state is not trusted across ticks.
  readonly property var steps: [
    function() {
      h.button = h.find(h.w, function(o) { return typeof o.triggerPress === "function" })
      h.panel = h.find(h.w, function(o) { return typeof o.setRegion === "function" })
      h.check("chip button found", !!h.button)
      h.check("panel loaded", !!h.panel)
      h.check("starts on US", h.w.region === "us", h.w.region)

      h.button.triggerPress(Qt.RightButton)
      h.check("right-click leaves the panel closed", h.w.opened === false, h.w.opened)
      h.button.triggerPress(Qt.MiddleButton)
      h.check("middle-click leaves the panel closed", h.w.opened === false, h.w.opened)
      h.button.triggerPress(Qt.LeftButton)
      h.check("left-click opens the panel", h.w.opened === true, h.w.opened)
      h.button.triggerPress(Qt.LeftButton)
      h.check("left-click closes the panel", h.w.opened === false, h.w.opened)
      h.w.open()
    },
    function() {
      h.regionGroup = h.findGroup(h.panel, "EU")
      h.iconGroup = h.findGroup(h.panel, "horde")
      h.countdownSwitch = h.find(h.panel, function(o) { return o.toggled !== undefined && o.trackWidth !== undefined })
      h.link = h.find(h.panel, function(o) { return o.text === "Show" && o.font !== undefined })
      h.caption = h.find(h.panel, function(o) { return o.text !== undefined && String(o.text).indexOf("SETTINGS") === 0 })
      h.check("settings controls found", !!(h.regionGroup && h.iconGroup && h.countdownSwitch && h.link && h.caption))
      h.check("settings collapsed by default",
        !h.regionGroup.visible && !h.iconGroup.visible && !h.countdownSwitch.visible, h.regionGroup.visible)
      h.check("collapsed row shows the region", h.caption.text === "SETTINGS · US", h.caption.text)

      h.link.children[0].clicked(null)
      h.check("Show expands the settings",
        h.regionGroup.visible && h.iconGroup.visible && h.countdownSwitch.visible && h.link.text === "Hide", h.link.text)
      h.check("region picker shows US", h.regionGroup.value === "US", h.regionGroup.value)
      h.findChip(h.regionGroup, "EU").clicked()
    },
    function() {
      var entry = h.lastWrite()
      h.check("EU written once", h.persisted.length === 1 && entry.region === "EU", JSON.stringify(h.persisted))
      h.check("other keys kept", entry.icon === "Sword" && entry.showCountdown === true && entry.keepMe === "x", JSON.stringify(entry))
      h.check("widget switched to EU", h.w.region === "eu", h.w.region)
      h.check("service switched to EU", h.panel.service.region === "eu", h.panel.service.region)
      h.check("region picker shows EU", h.regionGroup.value === "EU", h.regionGroup.value)
      h.check("settings row shows EU", h.caption.text === "SETTINGS · EU", h.caption.text)
      h.check("tooltip says EU", h.button.tooltipText.indexOf("EU weekly reset") === 0, h.button.tooltipText)
      var realm = h.find(h.panel, function(o) { return o.placeholderText !== undefined && String(o.placeholderText).indexOf("Realm") === 0 })
      h.check("realm hint says EU", realm && realm.placeholderText === "Realm (EU)", realm && realm.placeholderText)

      h.panel.setRegion("EU")
      h.panel.setRegion("XX")
      h.panel.setRegion("")
      h.check("same or invalid region writes nothing", h.persisted.length === 1, h.persisted.length)
      h.panel.setRegion("TW")
    },
    function() {
      h.check("TW written", h.persisted.length === 2 && h.lastWrite().region === "TW", JSON.stringify(h.lastWrite()))
      h.check("widget switched to TW", h.w.region === "tw", h.w.region)
      h.check("settings row shows TW", h.caption.text === "SETTINGS · TW", h.caption.text)

      h.check("icon picker shows Sword", h.iconGroup.value === "sword", h.iconGroup.value)
      h.findChip(h.iconGroup, "Horde").clicked()
    },
    function() {
      var entry = h.lastWrite()
      h.check("Horde written once, other keys kept",
        h.persisted.length === 3 && entry.icon === "Horde" && entry.region === "TW" && entry.showCountdown === true && entry.keepMe === "x",
        JSON.stringify(entry))
      h.check("widget switched to Horde", h.w.icon === "horde", h.w.icon)
      h.check("service switched to Horde", h.panel.service.icon === "horde", h.panel.service.icon)
      h.check("icon picker shows Horde", h.iconGroup.value === "horde", h.iconGroup.value)

      h.panel.setIcon("horde")
      h.panel.setIcon("Pirate")
      h.panel.setIcon("")
      h.check("same or invalid icon writes nothing", h.persisted.length === 3, h.persisted.length)

      h.check("countdown on: switch and chip label", h.countdownSwitch.checked && h.w.labelText !== "", h.w.labelText)
      h.countdownSwitch.toggled()
    },
    function() {
      var entry = h.lastWrite()
      h.check("countdown off written, other keys kept",
        h.persisted.length === 4 && entry.showCountdown === false && entry.icon === "Horde" && entry.region === "TW",
        JSON.stringify(entry))
      h.check("chip label hidden", h.w.labelText === "", JSON.stringify(h.w.labelText))
      h.check("switch off", h.countdownSwitch.checked === false, h.countdownSwitch.checked)
      h.countdownSwitch.toggled()
    },
    function() {
      h.check("countdown back on",
        h.persisted.length === 5 && h.lastWrite().showCountdown === true && h.w.labelText !== "" && h.countdownSwitch.checked,
        JSON.stringify(h.lastWrite()))

      h.link.children[0].clicked(null)
      h.check("Hide collapses the settings",
        !h.regionGroup.visible && !h.iconGroup.visible && !h.countdownSwitch.visible && h.link.text === "Show", h.link.text)
      h.w.close()
      h.finish()
    }
  ]

  property int step: 0
  Timer {
    interval: 300
    repeat: true
    running: h.w !== null
    onTriggered: {
      if (h.step >= h.steps.length) return
      try {
        h.steps[h.step++]()
      } catch (e) {
        h.check("step " + h.step + " ran", false, e)
        h.finish()
      }
    }
  }
}
