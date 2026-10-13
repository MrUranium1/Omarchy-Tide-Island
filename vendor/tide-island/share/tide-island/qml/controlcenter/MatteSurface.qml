import QtQuick
import IslandBackend

Item {
    id: root

    property real radius: 20
    property bool hovered: false
    property bool pressed: false
    readonly property real innerRadius: Math.max(0, radius - 1)

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.pressed ? "#24262c" : (root.hovered ? "#30333a" : "#25282e")
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: root.innerRadius
        color: root.pressed ? "#101116" : (root.hovered ? "#1f2127" : "#17191e")
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: root.innerRadius
        color: StyleTokens.transparent
        border.width: 1
        border.color: root.hovered ? "#3d4149" : "#2b2e35"
    }
}
