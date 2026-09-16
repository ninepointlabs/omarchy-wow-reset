// Adapted from ninepointlabs' Fastmail plugin (MailIcon.qml). The emblem is a
// white alpha mask the helper cached in ~/.local/state/omarchy-wow-reset, so it
// takes the bar colour like any glyph.
import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: root

  property string path: ""
  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  Image {
    id: sourceImage
    anchors.fill: parent
    source: root.path !== "" ? "file://" + root.path : ""
    sourceSize.height: Math.round(root.iconSize * Screen.devicePixelRatio)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    cache: false
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: sourceImage
    source: sourceImage
    colorization: 1.0
    colorizationColor: root.color
  }
}
