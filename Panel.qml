import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ninepointlabs.wow-reset"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var service: sharedService || localService

  function pushSettings() { if (service) service.settings = settings }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property int revision: service ? service.revision : 0
  readonly property string region: service ? service.region : "us"
  readonly property double nowMs: service ? service.nowMs : Date.now()
  readonly property var characters: service && revision >= 0 ? service.characters : []
  readonly property var affixes: service && revision >= 0 ? service.affixes : null
  readonly property bool blizzard: service ? service.blizzard : false
  readonly property bool refreshing: service ? service.refreshing : false
  readonly property string lastError: service ? service.lastError : ""
  readonly property string actionStatus: service ? service.actionStatus : ""
  readonly property string statusText: lastError !== "" ? lastError : actionStatus
  readonly property bool statusIsError: lastError !== ""

  property bool showCredentials: false

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function submitCharacter() {
    if (!service) return
    service.addCharacter(nameField.text, realmField.text)
  }

  function submitCredentials() {
    if (!service) return
    service.saveBlizzard(clientIdField.text, clientSecretField.text)
  }

  // Clear the form once a lookup or credential save succeeds.
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onActionStatusChanged() {
      if (!root.service) return
      var status = root.service.actionStatus
      if (status.indexOf("Added ") === 0) { nameField.text = ""; realmField.text = "" }
      if (status.indexOf("Battle.net connected") === 0) {
        clientIdField.text = ""
        clientSecretField.text = ""
        root.showCredentials = false
      }
    }
  }

  implicitWidth: 1
  implicitHeight: 1

  onOpenedChanged: {
    if (!opened) {
      clientSecretField.text = ""
      return
    }
    if (service && service.loaded) service.nowMs = Date.now()
  }

  Service {
    id: localService
    active: false
  }
  Timer {
    interval: 2500
    running: root.bar !== null && root.sharedService === null && !localService.active
    onTriggered: if (root.sharedService === null) localService.active = true
  }
  onSharedServiceChanged: if (sharedService !== null && localService.active) localService.active = false

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Body: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
  }

  component Detail: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: nameField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight + Style.space(24), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus || realmField.activeFocus || clientIdField.activeFocus || clientSecretField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: mainColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: mainColumn
      width: panelFlick.width
      spacing: Style.space(10)

      // ------------------------------------------------------- Header --
      Item {
        width: parent.width
        implicitHeight: Math.max(titleColumn.implicitHeight, refreshButton.implicitHeight)

        Column {
          id: titleColumn
          anchors.left: parent.left
          anchors.right: refreshButton.left
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "WEEKLY RESET"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: Model.countdownText(Model.nextResetMs(root.region, root.nowMs) - root.nowMs)
              + " · " + Model.regionLabel(root.region) + " resets " + Model.localResetText(root.region, root.nowMs)
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.statusText !== "" ? root.statusText : (root.refreshing ? "Refreshing…" : "")
            color: root.statusIsError ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
        }

        PanelActionButton {
          id: refreshButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰑐"
          tooltipText: "Refresh affixes and characters"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.refresh()
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ------------------------------------------------------ Affixes --
      Caption { text: "MYTHIC+ AFFIXES THIS WEEK" }

      Detail {
        visible: !root.affixes
        text: root.refreshing ? "Asking Raider.io…" : "Affixes not loaded yet."
      }

      Repeater {
        model: root.affixes ? root.affixes.items : []

        Column {
          required property var modelData
          width: mainColumn.width
          spacing: Style.space(1)

          Body { text: modelData.name }
          Detail { visible: modelData.description !== ""; text: modelData.description }
        }
      }

      PanelSeparator { foreground: root.foreground }

      // --------------------------------------------------- Characters --
      Caption {
        text: root.characters.length === 0 ? "CHARACTERS"
          : "CHARACTERS · " + root.characters.length
      }

      Detail {
        visible: root.characters.length === 0
        text: "Add a character to see this week's Mythic+ keys and raid progress. Nothing to sign up for — the data comes from Raider.io."
      }

      Repeater {
        model: root.characters

        Rectangle {
          id: card
          required property var modelData
          readonly property var info: root.service && root.revision >= 0 ? root.service.dataFor(modelData) : null
          readonly property var runs: info && !info.error ? Model.runsThisWeek(info, info.region, root.nowMs) : []
          readonly property var weekly: info && !info.error ? Model.weeklyLockouts(info, root.nowMs) : null

          width: mainColumn.width
          height: cardColumn.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: cardMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

          MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }

          Column {
            id: cardColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(2)

            Item {
              width: parent.width
              implicitHeight: Math.max(nameText.implicitHeight, removeLabel.implicitHeight)

              Text {
                id: nameText
                anchors.left: parent.left
                anchors.right: removeLabel.left
                anchors.rightMargin: Style.space(8)
                textFormat: Text.PlainText
                text: {
                  var bits = [card.modelData.name + " – " + card.modelData.realm]
                  if (card.modelData.region !== root.region) bits.push(card.modelData.region.toUpperCase())
                  if (card.info && card.info.spec) bits.push(card.info.spec + " " + card.info.className)
                  if (card.info && card.info.score > 0) bits.push(Math.round(card.info.score))
                  return bits.join(" · ")
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                id: removeLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Remove"
                color: removeMouse.containsMouse ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: removeMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.removeCharacter(card.modelData)
                }
              }
            }

            Detail {
              visible: !card.info
              text: root.refreshing ? "Loading…" : "Not loaded yet"
            }

            Detail {
              visible: !!(card.info && card.info.error)
              text: card.info && card.info.error ? card.info.error : ""
              color: Color.urgent
            }

            Detail {
              visible: !!(card.info && !card.info.error)
              text: "Mythic+: " + Model.dungeonSummary(card.runs)
            }

            // Blizzard lockouts when connected; season progression otherwise.
            Repeater {
              model: card.weekly ? card.weekly.raids : []

              Detail {
                required property var modelData
                text: {
                  var summary = Model.lockoutSummary(modelData)
                  return modelData.name + ": " + (summary !== "" ? "saved " + summary : "not saved this week")
                }
                color: Model.lockoutSummary(modelData) !== "" ? root.foreground : root.dim
              }
            }

            Detail {
              visible: !!card.weekly
              text: card.weekly
                ? "Raid vault: " + Model.vaultSlots(card.weekly.bossesThisWeek, Model.VAULT_RAID_STEPS) + "/3 · "
                  + card.weekly.bossesThisWeek + (card.weekly.bossesThisWeek === 1 ? " boss" : " bosses") + " this week"
                : ""
            }

            Detail {
              visible: !!(card.info && card.info.lockoutError)
              text: card.info && card.info.lockoutError ? "Lockouts: " + card.info.lockoutError : ""
            }

            Detail {
              visible: !!(card.info && !card.info.error && !card.weekly && card.info.progression && card.info.progression.length > 0)
              text: {
                if (!card.info || !card.info.progression) return ""
                var bits = []
                for (var i = 0; i < card.info.progression.length; i++)
                  bits.push(card.info.progression[i].name + " " + card.info.progression[i].summary)
                return "Season: " + bits.join(" · ")
              }
            }
          }
        }
      }

      // ----------------------------------------------- Add a character --
      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: nameField
          width: Math.round((parent.width - addButton.width - parent.spacing * 2) * 0.45)
          placeholderText: "Character"
          foreground: root.foreground
          accent: root.accent
          Keys.onReturnPressed: realmField.text !== "" ? root.submitCharacter() : realmField.forceActiveFocus()
          Keys.onEnterPressed: realmField.text !== "" ? root.submitCharacter() : realmField.forceActiveFocus()
          Keys.onEscapePressed: function(event) {
            if (nameField.text !== "") { nameField.text = ""; event.accepted = true }
            else root.close()
          }
        }

        TextField {
          id: realmField
          width: parent.width - nameField.width - addButton.width - parent.spacing * 2
          placeholderText: "Realm (" + Model.regionLabel(root.region) + ")"
          foreground: root.foreground
          accent: root.accent
          Keys.onReturnPressed: root.submitCharacter()
          Keys.onEnterPressed: root.submitCharacter()
          Keys.onEscapePressed: function(event) {
            if (realmField.text !== "") { realmField.text = ""; event.accepted = true }
            else root.close()
          }
        }

        Button {
          id: addButton
          anchors.verticalCenter: parent.verticalCenter
          text: root.service && root.service.looking ? "…" : "Add"
          bordered: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.submitCharacter()
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ------------------------------------ Optional Battle.net lockouts --
      Item {
        width: parent.width
        implicitHeight: Math.max(blizzCaption.implicitHeight, blizzAction.implicitHeight)

        Caption {
          id: blizzCaption
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.blizzard ? "RAID LOCKOUTS · BATTLE.NET CONNECTED" : "RAID LOCKOUTS (OPTIONAL)"
        }

        Text {
          id: blizzAction
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.blizzard ? "Disconnect" : (root.showCredentials ? "Hide" : "Set up")
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (!root.service) return
              if (root.blizzard) root.service.clearBlizzard()
              else root.showCredentials = !root.showCredentials
            }
          }
        }
      }

      Detail {
        visible: !root.blizzard && !root.showCredentials
        text: "Everything above works without an account. To see which raid bosses each character has killed since reset, connect a free Battle.net API client."
      }

      Column {
        visible: !root.blizzard && root.showCredentials
        width: parent.width
        spacing: Style.space(6)

        Detail {
          text: "1. Sign in at develop.battle.net → API Access → Create Client (any name; redirect URL can be http://localhost).\n2. Paste its Client ID and Client Secret here. They are stored only on this machine (0600) and used for public character data."
        }

        TextField {
          id: clientIdField
          width: parent.width
          placeholderText: "Client ID"
          foreground: root.foreground
          accent: root.accent
          Keys.onReturnPressed: clientSecretField.forceActiveFocus()
          Keys.onEnterPressed: clientSecretField.forceActiveFocus()
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: clientSecretField
            width: parent.width - saveButton.width - parent.spacing
            placeholderText: "Client Secret"
            password: true
            foreground: root.foreground
            accent: root.accent
            Keys.onReturnPressed: root.submitCredentials()
            Keys.onEnterPressed: root.submitCredentials()
          }

          Button {
            id: saveButton
            anchors.verticalCenter: parent.verticalCenter
            text: root.service && root.service.savingCredentials ? "Checking…" : "Connect"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.submitCredentials()
          }
        }
      }

      Detail {
        visible: root.blizzard
        text: "Kills are what Blizzard's armory reports; a character's data updates after they log out."
      }
    }
    }
    }
  }
}
