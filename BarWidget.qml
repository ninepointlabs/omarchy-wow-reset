import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "ninepointlabs.wow-reset"

  readonly property var service: panelLoader.item ? panelLoader.item.service : null
  readonly property string region: Model.validRegion(setting("region", "US")) || "us"
  readonly property bool showCountdown: setting("showCountdown", true) === true
  readonly property string icon: Model.validIcon(setting("icon", "Sword"))
  // Sword until the chosen emblem has been downloaded (or if it cannot be).
  readonly property string emblemPath: icon !== "sword" && service && service.emblemPaths
    ? (service.emblemPaths[icon] || "") : ""

  // The countdown is pure math, so the chip works before the service loads.
  property double nowMs: Date.now()
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  readonly property double msLeft: Model.nextResetMs(region, nowMs) - nowMs
  readonly property string labelText: showCountdown ? Model.countdownText(msLeft) : ""
  // Last six hours before reset: accent colour, so the chip nags a little.
  readonly property bool soon: msLeft < 6 * 3600000

  readonly property color chipColor: {
    if (!bar) return Color.foreground
    return soon ? Color.accent : bar.barForeground
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function anyOpened() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened === true) return true
    return false
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property real openPanelIndicatorWidth: button.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "ninepointlabs.wow-reset"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function isOpen(): string { return root.anyOpened() ? "true" : "false" }
    function refresh(): void { if (root.service) root.service.refresh() }
    function countdown(): string { return Model.countdownText(root.msLeft) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.round(chipRow.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: root.labelText !== "" && !root.vertical ? 7 : 6
    tooltipText: Model.regionLabel(root.region) + " weekly reset in " + Model.countdownText(root.msLeft)
      + " · " + Model.localResetText(root.region, root.nowMs)

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.service) root.service.refresh() }
      else root.togglePanel()
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      FactionIcon {
        visible: root.emblemPath !== ""
        anchors.verticalCenter: parent.verticalCenter
        path: root.emblemPath
        iconSize: Style.bar.iconCanvas + Style.space(2)
        color: root.chipColor
      }

      OpticalGlyph {
        visible: root.emblemPath === ""
        width: Style.bar.iconCanvas + Style.space(2)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        text: "󰓥"
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: root.chipColor
      }

      Text {
        visible: !root.vertical && root.labelText !== ""
        textFormat: Text.PlainText
        text: root.labelText
        color: root.chipColor
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
