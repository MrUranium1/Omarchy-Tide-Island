pragma Singleton
import QtQuick

QtObject {
    readonly property string path: backend.userConfigPath
    readonly property string errorString: backend.errorString
    property var map: backend.userConfig

    function value(key, fallback) {
        const currentValue = map[key];
        return currentValue === undefined || currentValue === null ? fallback : currentValue;
    }

    function setValue(key, value) {
        map[key] = value;
    }

    function remove(key) {
        map[key] = undefined;
    }

    function save() {
        return backend.save(map);
    }
}
