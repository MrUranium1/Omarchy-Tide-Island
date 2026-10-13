import QtQuick
import QtQuick.Controls
import TideIsland 1.0

Rectangle {
    id: root

    property int revision: 0

    color: Theme.cardBgColor
    radius: 16
    border.width: 1
    border.color: Theme.splitLineColor
    implicitHeight: weatherColumn.implicitHeight + 36

    function boolValue(key, fallback) {
        return ConfigStore.value(key, fallback) === true || ConfigStore.value(key, fallback) === "true";
    }

    function textValue(key, fallback) {
        return String(ConfigStore.value(key, fallback));
    }

    function intValue(key, fallback) {
        const val = parseInt(ConfigStore.value(key, fallback), 10);
        return isNaN(val) ? fallback : val;
    }

    Column {
        id: weatherColumn

        anchors.top: parent.top
        anchors.topMargin: 18
        anchors.left: parent.left
        anchors.leftMargin: 18
        anchors.right: parent.right
        anchors.rightMargin: 18
        spacing: 16

        // 1. Enable Weather Toggle
        Item {
            width: parent.width
            height: 49

            Column {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    text: "Enable Weather"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 18
                    color: Theme.textColor
                }

                Text {
                    text: "Display real-time weather and 3-day forecast in Island and Control Center"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 14
                    color: Theme.subtleTextColor
                }
            }

            StyledSwitch {
                id: weatherSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.boolValue("weatherEnabled", true)
                onToggled: function(val) {
                    checked = val;
                    ConfigStore.setValue("weatherEnabled", val);
                    ConfigStore.save();
                    root.revision += 1;
                }
            }
        }

        SplitLine { width: parent.width }

        // 2. Weather Location
        Item {
            width: parent.width
            height: 49

            Column {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    text: "Location"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 18
                    color: Theme.textColor
                }

                Text {
                    text: "City or region name. Leave empty for automatic IP-based location"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 14
                    color: Theme.subtleTextColor
                }
            }

            ConfigTextField {
                id: locationField
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 240
                height: 36
                placeholderText: "Auto-detect (IP location)"
                text: root.textValue("weatherLocation", "")

                onAccepted: commit()
                onEditingFinished: commit()

                function commit() {
                    ConfigStore.setValue("weatherLocation", text.trim());
                    ConfigStore.save();
                    root.revision += 1;
                }
            }
        }

        SplitLine { width: parent.width }

        // 3. Units: Metric vs Imperial
        Item {
            id: unitsRow
            width: parent.width
            height: 49

            property string selectedUnits: root.textValue("weatherUnits", "metric") === "imperial" ? "imperial" : "metric"

            Column {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    text: "Temperature Units"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 18
                    color: Theme.textColor
                }

                Text {
                    text: "Choose Celsius (°C, km/h) or Fahrenheit (°F, mph)"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 14
                    color: Theme.subtleTextColor
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Repeater {
                    model: [
                        { "label": "Metric (°C)", "value": "metric" },
                        { "label": "Imperial (°F)", "value": "imperial" }
                    ]

                    Rectangle {
                        id: unitBtn
                        readonly property bool selected: unitsRow.selectedUnits === modelData.value

                        width: 106
                        height: 36
                        radius: 7
                        color: selected ? Theme.cardBgColor
                                        : unitMouse.pressed ? Theme.controlPressedColor
                                                            : Theme.componentBgColor
                        border.width: 1
                        border.color: Theme.inputBorderColor

                        Behavior on color { ColorAnimation { duration: Theme.animationDuration } }
                        Behavior on border.color { ColorAnimation { duration: Theme.animationDuration } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: unitBtn.selected ? Theme.textColor : Theme.secondaryTextColor
                            font.family: Theme.textFontFamily
                            font.pixelSize: 13
                            font.weight: unitBtn.selected ? Font.DemiBold : Font.Normal
                        }

                        MouseArea {
                            id: unitMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                unitsRow.selectedUnits = modelData.value;
                                ConfigStore.setValue("weatherUnits", modelData.value);
                                ConfigStore.save();
                                root.revision += 1;
                            }
                        }
                    }
                }
            }
        }

        SplitLine { width: parent.width }

        // 4. Refresh Interval
        Item {
            id: refreshRow
            width: parent.width
            height: 49

            property int selectedInterval: root.intValue("weatherRefreshInterval", 1800000)

            Column {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    text: "Refresh Interval"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 18
                    color: Theme.textColor
                }

                Text {
                    text: "How often to check for weather updates from wttr.in"
                    font.family: Theme.textFontFamily
                    font.pixelSize: 14
                    color: Theme.subtleTextColor
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Repeater {
                    model: [
                        { "label": "15 min", "value": 900000 },
                        { "label": "30 min", "value": 1800000 },
                        { "label": "1 hour", "value": 3600000 },
                        { "label": "2 hours", "value": 7200000 }
                    ]

                    Rectangle {
                        id: intervalBtn
                        readonly property bool selected: refreshRow.selectedInterval === modelData.value

                        width: 72
                        height: 36
                        radius: 7
                        color: selected ? Theme.cardBgColor
                                        : intervalMouse.pressed ? Theme.controlPressedColor
                                                                : Theme.componentBgColor
                        border.width: 1
                        border.color: Theme.inputBorderColor

                        Behavior on color { ColorAnimation { duration: Theme.animationDuration } }
                        Behavior on border.color { ColorAnimation { duration: Theme.animationDuration } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: intervalBtn.selected ? Theme.textColor : Theme.secondaryTextColor
                            font.family: Theme.textFontFamily
                            font.pixelSize: 13
                            font.weight: intervalBtn.selected ? Font.DemiBold : Font.Normal
                        }

                        MouseArea {
                            id: intervalMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                refreshRow.selectedInterval = modelData.value;
                                ConfigStore.setValue("weatherRefreshInterval", modelData.value);
                                ConfigStore.save();
                                root.revision += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    component SplitLine: Rectangle {
        height: 1
        color: Theme.splitLineColor
    }

    component StyledSwitch: Item {
        id: control

        signal toggled(bool checked)

        property bool checked: false

        width: 48
        height: 26

        Rectangle {
            id: track

            anchors.verticalCenter: parent.verticalCenter
            anchors.horizontalCenter: parent.horizontalCenter
            width: 40
            height: 24
            radius: 12
            color: control.checked ? Theme.accentColor : Theme.componentBgColor
            border.width: 1
            border.color: control.checked ? Theme.accentColor : Theme.inputBorderColor

            Behavior on color {
                ColorAnimation { duration: 180; easing.type: Easing.InOutQuad }
            }
        }

        Rectangle {
            id: knob

            width: 18
            height: 18
            radius: 9
            x: control.checked ? 22 : 6
            y: 3
            color: Theme.cardBgColor
            border.width: 0

            Behavior on x {
                NumberAnimation { duration: 180; easing.type: Easing.InOutQuad }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: control.toggled(!control.checked)
        }
    }
}
