import QtQuick
import QtQuick.Shapes
import qs.Commons

// Face Howdy — polished face-recognition glyph.
// Kept as a separate reusable component so callers can control size/color.
// Source geometry: Material Design Icons — face-recognition (Apache 2.0).

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool scanning: false

  readonly property real viewBox: 24

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // Quiet halo, useful when the icon is used as a hero rather than a tiny glyph.
  Rectangle {
    anchors.centerIn: parent
    width: root.width * 0.72
    height: root.height * 0.72
    radius: width / 2
    color: Util.alpha(root.color, 0.045)
    visible: root.scanning
    opacity: scanPulse.opacity

    SequentialAnimation on opacity {
      id: scanPulse
      loops: Animation.Infinite
      running: root.scanning
      NumberAnimation { from: 0.35; to: 0.75; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.75; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  Item {
    anchors.centerIn: parent
    width: root.viewBox
    height: root.viewBox
    scale: Math.min(root.width, root.height) / root.viewBox

    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        strokeColor: "transparent"
        fillRule: ShapePath.WindingFill

        PathSvg {
          path: "M2 4V8H4V4H8V2H4C2.9 2 2 2.9 2 4M20 2H16V4H20V8H22V4C22 2.9 21.1 2 20 2M4 16H2V20C2 21.1 2.9 22 4 22H8V20H4V16M20 20H16V22H20C21.1 22 22 21.1 22 20V16H20V20M9 9C7.9 9 7 9.9 7 11S7.9 13 9 13 11 12.1 11 11 10.1 9 9 9M15 9C13.9 9 13 9.9 13 11S13.9 13 15 13 17 12.1 17 11 16.1 9 15 9M12 17.5C9.67 17.5 7.69 16.17 6.76 14.23L5 15C6.22 17.5 8.9 19.25 12 19.25S17.78 17.5 19 15L17.24 14.23C16.31 16.17 14.33 17.5 12 17.5Z"
        }
      }
    }

    // Optional scan line. It stays completely inert unless scanning=true.
    Rectangle {
      visible: root.scanning
      x: 4
      y: scanLineY
      width: 16
      height: 0.8
      radius: 0.4
      color: Util.alpha(root.color, 0.65)

      property real scanLineY: 4

      SequentialAnimation on scanLineY {
        loops: Animation.Infinite
        running: root.scanning
        NumberAnimation { from: 4; to: 19; duration: 1200; easing.type: Easing.InOutSine }
        NumberAnimation { from: 19; to: 4; duration: 1200; easing.type: Easing.InOutSine }
      }
    }
  }
}
