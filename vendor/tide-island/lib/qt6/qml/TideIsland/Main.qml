import QtQuick
import QtQuick.Controls
import TideIsland 1.0

ApplicationWindow {
    id: window
    visible: true
    width: 1000
    height: 600
    title: "Tide Island Config Application"
    color: Theme.totalBgColor
    palette.window: Theme.totalBgColor
    palette.windowText: Theme.textColor
    palette.base: Theme.inputBgColor
    palette.alternateBase: Theme.componentBgColor
    palette.text: Theme.textColor
    palette.button: Theme.mutedButtonColor
    palette.buttonText: Theme.mutedButtonTextColor
    palette.highlight: Theme.selectedColor
    palette.highlightedText: Theme.buttonTextColor
    palette.placeholderText: Theme.subtleTextColor

    property int currentPage: 1

    Behavior on color {
        ColorAnimation { duration: Theme.animationDuration }
    }

    function pageForIndex(index) {
        switch (index) {
        case 1:
            return generalPage
        case 2:
            return wallpaperPage
        case 3:
            return fontPage
        case 4:
            return shortcutPage
        case 5:
            return interactionPage
        default:
            return null
        }
    }

    function selectPage(index) {
        if (index === currentPage) {
            return
        }

        const nextPage = pageForIndex(index)
        if (!nextPage) {
            return
        }

        const previousPage = pageForIndex(currentPage)
        currentPage = index

        if (previousPage) {
            previousPage.hidePage()
        }

        if (nextPage) {
            nextPage.showPage()
        }
    }

    Rectangle{// main split line
        id:mainSplitLine
        height: parent.height - 60
        width:2
        color: Theme.splitLineColor
        x: 180
        y: 30

        DragHandler {
            target: parent
            xAxis.enabled: true
            yAxis.enabled: false
            xAxis.minimum: 50
            xAxis.maximum: 250
        }

        MouseArea{
            anchors.fill:parent
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.SizeHorCursor
        }
    }

    Item{
        id: outline
        width: mainSplitLine.x
        height:window.height
        
        Text{
            id: title
            anchors.horizontalCenter: parent.horizontalCenter
            y: 80
            color: Theme.textColor
            text: tideIslandText.width > mainSplitLine.x ? "T" : "Tide Island"
            font.pixelSize: 23
            font.family: Theme.titleFontFamily

            TextMetrics {
                id: tideIslandText
                font: islandButton.font
                text: "Tide Island"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                hoverEnabled: true
                anchors.fill: parent
                onEntered: title.color = Theme.selectedColor
                onExited: title.color = Theme.textColor
                onClicked: Qt.openUrlExternally("https://github.com/enhaoswen/Tide-island")
            }
        }

        Text{
            id: islandButton
            anchors.horizontalCenter: parent.horizontalCenter
            y: 210
            color: currentPage === 1 ? Theme.selectedColor : Theme.textColor
            text: islandButtonText.width > mainSplitLine.x ? "G" : "General"
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            TextMetrics {
                id: islandButtonText
                font: islandButton.font
                text: "General"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                anchors.fill:parent

                onClicked: {
                    selectPage(1)
                }
            }
        }

        Text{
            id: wallpaperButton
            anchors.horizontalCenter: parent.horizontalCenter
            y: 265
            color: currentPage === 2 ? Theme.selectedColor : Theme.textColor
            text: wallpaperButtonText.width > mainSplitLine.x ? "W" : "Wallpaper"
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            TextMetrics {
                id: wallpaperButtonText
                font: wallpaperButton.font
                text: "Wallpaper"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                anchors.fill:parent

                onClicked: {
                    selectPage(2)
                }
            }
        }

        Text{
            id: fontButton
            anchors.horizontalCenter: parent.horizontalCenter
            y: 320
            color: currentPage === 3 ? Theme.selectedColor : Theme.textColor
            text: fontButtonText.width > mainSplitLine.x ? "F" : "Font"
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            TextMetrics {
                id: fontButtonText
                font: fontButton.font
                text: "Font"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                anchors.fill:parent

                onClicked: {
                    selectPage(3)
                }
            }
        }

        Text{
            id: shortcutButton
            anchors.horizontalCenter: parent.horizontalCenter
            y: 375
            color: currentPage === 4 ? Theme.selectedColor : Theme.textColor
            text: shortcutButtonText.width > mainSplitLine.x ? "S" : "Shortcut"
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            TextMetrics {
                id: shortcutButtonText
                font: shortcutButton.font
                text: "Shortcut"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                anchors.fill:parent

                onClicked: {
                    selectPage(4)
                }
            }
        }

        Text{
            id: interactionButton
            anchors.horizontalCenter: parent.horizontalCenter
            y: 430
            color: currentPage === 5 ? Theme.selectedColor : Theme.textColor
            text: interactionButtonText.width > mainSplitLine.x ? "I" : "Interaction"
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            TextMetrics {
                id: interactionButtonText
                font:interactionButton.font
                text: "Interaction"
            }

            Behavior on color {ColorAnimation{ duration:Theme.animationDuration}}

            MouseArea{
                anchors.fill:parent

                onClicked: {
                    selectPage(5)
                }
            }
        }

        Text {
            id: appearanceButton

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 42
            text: Theme.darkMode ? "Dark" : "Light"
            color: Theme.textColor
            font.family: Theme.titleFontFamily
            font.pixelSize: 23

            Behavior on color {
                ColorAnimation { duration: Theme.animationDuration }
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: appearanceButton.color = Theme.selectedColor
                onExited: appearanceButton.color = Theme.textColor
                onClicked: backend.setColorScheme(Theme.darkMode ? "light" : "dark")
            }
        }

    }



    Item{
        id: page
        anchors.left: mainSplitLine.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        General{
            id: generalPage           
            anchors.fill:parent
            visible: true
            opacity: 1
        }

        WallpaperSettings {
            id: wallpaperPage
            anchors.fill: parent
            visible: false
            opacity: 0
        }

        FontSettings {
            id: fontPage
            anchors.fill: parent
            visible: false
            opacity: 0
        }

        Shortcut {
            id: shortcutPage
            anchors.fill: parent
            visible: false
            opacity: 0
        }

        Interaction {
            id: interactionPage
            anchors.fill: parent
            visible: false
            opacity: 0
        }

    }

    Rectangle {
        id: configErrorBanner

        readonly property bool hasError: ConfigStore.errorString.length > 0

        z: 20
        visible: hasError
        opacity: hasError ? 1 : 0
        anchors.left: mainSplitLine.right
        anchors.leftMargin: 24
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
        height: Math.max(48, errorText.implicitHeight + 20)
        radius: 8
        color: Theme.errorBgColor
        border.width: 1
        border.color: Theme.errorBorderColor

        Behavior on opacity { NumberAnimation { duration: Theme.animationDuration } }

        Text {
            id: errorText

            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: rewriteButton.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: "Config file error: " + ConfigStore.errorString
            color: Theme.errorTextColor
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: Theme.textFontFamily
            font.pixelSize: 13
        }

        Rectangle {
            id: rewriteButton

            width: 112
            height: 32
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            radius: 6
            color: rewriteMouse.pressed ? Theme.buttonPressedColor
                                        : rewriteMouse.containsMouse ? Theme.buttonHoverColor
                                                                    : Theme.buttonColor

            Behavior on color { ColorAnimation { duration: Theme.animationDuration } }

            Text {
                anchors.centerIn: parent
                text: "Rewrite"
                color: Theme.buttonTextColor
                font.family: Theme.textFontFamily
                font.pixelSize: 13
            }

            MouseArea {
                id: rewriteMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ConfigStore.save()
            }
        }
    }
}
