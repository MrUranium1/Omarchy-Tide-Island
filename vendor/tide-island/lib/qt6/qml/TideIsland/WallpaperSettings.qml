import TideIsland 1.0
import QtQuick.Controls
import QtQuick

PagePanel {
    id: root

    Flickable {
        id: scroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: content.height
        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        interactive: false

        WheelHandler {
            target: null
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

            onWheel: function(event) {
                const rawDelta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 64
                const maxY = Math.max(0, scroller.contentHeight - scroller.height)
                scroller.contentY = Math.max(0, Math.min(maxY, scroller.contentY - rawDelta))
                event.accepted = true
            }
        }

        Item {
            id: content
            width: scroller.width
            height: wallpaperPanel.y + wallpaperPanel.height + 40

            Text {
                id: title
                font.family: Theme.titleFontFamily
                text: "Wallpaper"
                color: Theme.textColor
                font.pixelSize: 30
                x: 60
                y: 50
            }

            Wallpaper {
                id: wallpaperPanel
                anchors.top: title.bottom
                anchors.topMargin: 40
                anchors.left: parent.left
                anchors.leftMargin: 30
                anchors.right: parent.right
                anchors.rightMargin: 40
                height: implicitHeight
            }
        }
    }
}
