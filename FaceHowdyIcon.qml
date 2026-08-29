import QtQuick
import QtQuick.Shapes
import qs.Commons

// Face-recognition icon drawn natively from the MDI SVG path so it inherits
// the caller's color and scales crisply at any size — same pattern as ProtonIcon.qml.
//
// Source: Material Design Icons — face-recognition (24x24 viewBox, Apache 2.0).
// https://github.com/Templarian/MaterialDesign-SVG/blob/master/svg/face-recognition.svg
//
// Usage:
//   FaceHowdyIcon { iconSize: Style.space(32); color: root.accent }

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property real viewBox: 24

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

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

        // MDI face-recognition — Apache 2.0
        // Corner brackets + facial feature dots: face framed by scan brackets
        // with eye-dots and a mouth arc — universally readable as "face scan"
        PathSvg {
          path: "M2 4V8H4V4H8V2H4C2.9 2 2 2.9 2 4M20 2H16V4H20V8H22V4C22 2.9 21.1 2 20 2M4 16H2V20C2 21.1 2.9 22 4 22H8V20H4V16M20 20H16V22H20C21.1 22 22 21.1 22 20V16H20V20M9 9C7.9 9 7 9.9 7 11S7.9 13 9 13 11 12.1 11 11 10.1 9 9 9M15 9C13.9 9 13 9.9 13 11S13.9 13 15 13 17 12.1 17 11 16.1 9 15 9M12 17.5C9.67 17.5 7.69 16.17 6.76 14.23L5 15C6.22 17.5 8.9 19.25 12 19.25S17.78 17.5 19 15L17.24 14.23C16.31 16.17 14.33 17.5 12 17.5Z"
        }
      }
    }
  }
}
