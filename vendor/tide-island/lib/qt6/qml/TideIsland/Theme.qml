pragma Singleton
import QtQuick

QtObject {
    // Dark values follow the current Claude web palette: bg-100/bg-200/bg-000,
    // gray-20/gray-200/gray-350, and the clay brand token.
    readonly property bool darkMode: backend.colorScheme === "dark"

    readonly property color totalBgColor: darkMode ? "#20201f" : "#faf9f5"
    readonly property color componentBgColor: darkMode ? "#181817" : "#f0efe9"
    readonly property color cardBgColor: darkMode ? "#2c2c2a" : "#ffffff"
    readonly property color cardBorderColor: darkMode ? "#474744" : "#e8e6dd"
    readonly property color tableHeaderBgColor: darkMode ? "#181817" : "#f0efe9"
    readonly property color tableFooterBgColor: darkMode ? "#20201f" : "#faf9f5"

    readonly property color inputBgColor: darkMode ? "#20201f" : "#faf9f5"
    readonly property color inputHoverBgColor: darkMode ? "#282827" : "#faf9f5"
    readonly property color inputBorderColor: darkMode ? "#3d3d3b" : "#e8e6dd"
    readonly property color inputHoverBorderColor: darkMode ? "#5a5a57" : "#e8e6dd"
    readonly property color focusBorderColor: darkMode ? "#d97757" : "#cc785c"
    readonly property color focusRingColor: darkMode ? "#59382f" : "#f3e7df"

    readonly property color textColor: darkMode ? "#f9f9f7" : "#1f1e1b"
    readonly property color secondaryTextColor: darkMode ? "#c3c2b7" : "#6b6a63"
    readonly property color subtleTextColor: darkMode ? "#97958d" : "#6b6a63"
    readonly property color splitLineColor: darkMode ? "#3d3d3b" : "#e8e6dd"

    readonly property color buttonColor: darkMode ? "#d97757" : "#cc785c"
    readonly property color buttonHoverColor: darkMode ? "#c6613f" : "#b4634a"
    readonly property color buttonPressedColor: darkMode ? "#ad5235" : "#a85740"
    readonly property color buttonTextColor: darkMode ? "#141413" : "#ffffff"
    readonly property color mutedButtonColor: darkMode ? "#2c2c2a" : "#ffffff"
    readonly property color mutedButtonHoverColor: darkMode ? "#383835" : "#f0efe9"
    readonly property color mutedButtonTextColor: darkMode ? "#f9f9f7" : "#1f1e1b"
    readonly property color controlHoverColor: darkMode ? "#383835" : "#f0efe9"
    readonly property color controlPressedColor: darkMode ? "#454543" : "#e8e6dd"

    readonly property color accentColor: darkMode ? "#d97757" : "#cc785c"
    readonly property color accentDarkColor: darkMode ? "#c6613f" : "#b4634a"
    readonly property color accentSoftColor: darkMode ? "#483831" : "#f3e7df"
    readonly property color selectedColor: darkMode ? "#d97757" : "#cc785c"
    readonly property color overlayColor: darkMode ? "#a3000000" : "#661f1e1b"

    readonly property color errorBgColor: darkMode ? "#3c0e0e" : "#fff1ed"
    readonly property color errorBorderColor: darkMode ? "#641919" : "#f2b8a2"
    readonly property color errorTextColor: darkMode ? "#f4abab" : "#8f2f16"

    readonly property int animationDuration: 160

    readonly property string textFontFamily: textFont.status === FontLoader.Ready ? textFont.name : "Inter"
    readonly property string titleFontFamily: titleFont.status === FontLoader.Ready ? titleFont.name : "Serif"
    readonly property string interFontFamily: textFontFamily
    readonly property string loraFontFamily: titleFontFamily
    readonly property string fontFamily: textFontFamily

    readonly property FontLoader textFont: FontLoader {
        source: "qrc:/RES/InterVariable.ttf"
    }

    readonly property FontLoader titleFont: FontLoader {
        source: "qrc:/RES/Lora-Regular.ttf"
    }
}
