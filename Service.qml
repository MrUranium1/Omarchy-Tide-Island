// mehir.tide-island — service plugin
//
// Keeps Tide Island synchronized with the Omarchy bar. When the bar is hidden
// (the ~/.local/state/omarchy/toggles/bar-off flag is present) Tide Island
// owns the screen and the tide-island.service is (re)started; when the bar
// comes back it is stopped again, so the two never show at the same time.
// Coordination also nudges the OSD and notification clones that are patched to
// stand down while the flag is present (see scripts/ensure-suppression.sh).
// Everything runs through scripts/tide-sync.sh so the CLI and the service share
// one idempotent state machine, and behavior is configurable via
// ~/.config/omarchy/tide-island.json (defaults embedded below; mirrored in
// default/tide-island.json which install.sh seeds for you).

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: plugin

    // Injected by omarchy-shell (the first-party service loader).
    property var shell: null

    readonly property string home: Quickshell.env("HOME")
    // Injected by omarchy-shell when present (a plain, writable property so the
    // shell's service loader can assign its own value, as it does for others).
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    readonly property string configPath: home + "/.config/omarchy/tide-island.json"
    readonly property string syncScript:
        Qt.resolvedUrl("scripts/tide-sync.sh").toString().replace("file://", "")
    readonly property string setupScript:
        Qt.resolvedUrl("scripts/plugin-setup.sh").toString().replace("file://", "")
    readonly property string launchTerminal:
        (omarchyPath !== "" ? omarchyPath : "/usr/share/omarchy") + "/bin/omarchy-launch-terminal"
    readonly property string pluginDir:
        home + "/.config/omarchy/plugins/mehir.tide-island"
    // Self-contained teardown installed outside the plugin dir (install.sh), so
    // it survives the plugin being deleted.
    readonly property string teardownHelper:
        home + "/.local/lib/omarchy-tide-island/teardown.sh"

    // ---------------------------------------------------------------- config

    // Effective settings = shipped defaults (default/tide-island.json) overridden
// by the user file (~/.config/omarchy/tide-island.json). Both are parsed as
// JSON at runtime; tests/unit.sh keeps them in parity.
    readonly property string defaultsPath:
        Qt.resolvedUrl("default/tide-island.json").toString().replace("file://", "")

    property var defaults: null
    property var config: null
    property bool configOk: true
    property string configError: ""

    function getConfig(key) {
        var d = plugin.defaults || {}
        var c = plugin.config || {}
        return c[key] !== undefined ? c[key] : d[key]
    }

    function loadConfig(raw) {
        if (!raw || String(raw).trim() === "") {
            config = {}
            configOk = true
            configError = ""
            plugin.scheduleReconcile()
            return
        }
        try {
            config = JSON.parse(raw)
            configOk = true
            configError = ""
        } catch (err) {
            config = {}
            configOk = false
            configError = String(err)
        }
        plugin.scheduleReconcile()
    }

    FileView {
        id: configFile
        path: plugin.configPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            var raw = text()
            // Deferred so a synchronous onLoaded during construction cannot
            // dereference the root id before it is fully bound.
            Qt.callLater(function() { plugin.loadConfig(raw) })
        }
        onLoadFailed: Qt.callLater(function() { plugin.loadConfig("") })
        onFileChanged: reload()
    }

    // Shipped defaults, read from the same file tests/unit.sh lints against.
    Process {
        id: defaultsProc
        running: true
        command: ["bash", "-c", "cat \"$1\"", "--", plugin.defaultsPath]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    plugin.defaults = JSON.parse(text)
                } catch (err) {
                    console.warn("tide-island: shipped defaults unparseable: " + String(err))
                }
            }
        }
    }

    // ------------------------------------------------------- bar-off watching

    function flagPath() {
        var dir = plugin.getConfig("togglesDir")
        var file = plugin.getConfig("barOffFile")
        var expanded = String(dir).replace("~", plugin.home).replace("$HOME", plugin.home)
        return expanded + "/" + file
    }

    // Presence of the bar-off flag = Tide Island on. Watching the parent toggles
    // directory because FileView can't observe a file that doesn't exist yet.
    Process {
        id: barProbe
        running: true
        command: ["bash", "-c",
            "flag=$HOME/.local/state/omarchy/toggles/bar-off; " +
            "[[ -f \"$flag\" ]] && echo bar=hidden || echo bar=visible; " +
            "command -v tide-island >/dev/null 2>&1 && echo tide-installed=yes || echo tide-installed=no; " +
            "systemctl --user is-active tide-island.service 2>/dev/null || echo inactive; " +
            "command -v omarchy-tide-island-toggle >/dev/null 2>&1 && echo cli=yes || echo cli=no; " +
            "grep -rl --include=Osd.qml 'The bar-off marker' \"$HOME/.config/omarchy/plugins\" 2>/dev/null | head -1 | grep -q . && echo osd-suppressed=yes || echo osd-suppressed=no; " +
            "grep -rl --include=Service.qml 'popupsSuppressed' \"$HOME/.config/omarchy/plugins\" 2>/dev/null | head -1 | grep -q . && echo notifications-suppressed=yes || echo notifications-suppressed=no"]
        stdout: SplitParser { onRead: (line) => plugin.applyProbe(String(line).trim()) }
    }
    FileView {
        path: plugin.home + "/.local/state/omarchy/toggles"
        watchChanges: true
        printErrors: false
        onFileChanged: debounceProbe.restart()
    }
    Timer {
        id: debounceProbe
        interval: 80
        onTriggered: plugin.probeBar()
    }
    // The directory watch can go quiet after rapid flag changes, so re-probe
    // on a slow heartbeat as a safety net.
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: plugin.probeBar()
    }

    property bool barHidden: false
    property string tideActive: "inactive"
    property bool tideInstalled: false
    property bool cliInstalled: false
    property bool osdSuppression: false
    property bool notificationsSuppression: false

    function applyProbe(line) {
        if (line.indexOf("=") < 0) {
            if (line === "active" || line === "inactive" || line === "failed" ||
                line === "activating" || line === "deactivating") {
                plugin.tideActive = line
            }
            return
        }
        var sep = line.indexOf("=")
        var key = line.slice(0, sep).trim()
        var value = line.slice(sep + 1).trim()
        switch (key) {
            case "bar": plugin.barHidden = value === "hidden"; break
            case "tide-installed": plugin.tideInstalled = value === "yes"; break
            case "tide-active": plugin.tideActive = value; break
            case "cli": plugin.cliInstalled = value === "yes"; break
            case "osd-suppressed": plugin.osdSuppression = value === "yes"; break
            case "notifications-suppressed": plugin.notificationsSuppression = value === "yes"; break
        }
    }

    function probeBar() { barProbe.running = true }

    // ---------------------------------------------------------------- reconcile

    property bool needsSetup: false

    function setupNeeded() {
        return !plugin.tideInstalled || !plugin.osdSuppression ||
            !plugin.notificationsSuppression || !plugin.cliInstalled
    }

    onTideInstalledChanged: plugin.needsSetup = plugin.setupNeeded()
    onOsdSuppressionChanged: plugin.needsSetup = plugin.setupNeeded()
    onNotificationsSuppressionChanged: plugin.needsSetup = plugin.setupNeeded()
    onCliInstalledChanged: plugin.needsSetup = plugin.setupNeeded()

    // Auto-setup on first load: a freshly added plugin installs the bundled
    // runtime, CLI shims and OSD/notification stand-down once, silently, so
    // adding the plugin is enough. A marker file makes it a one-time action;
    // re-run manually any time with `omarchy-shell tide-island setup`.
    property bool autoSetupTried: false
    readonly property string autoSetupMarker:
        home + "/.local/state/omarchy/tide-island/auto-setup.done"

    function maybeAutoSetup() {
        if (plugin.autoSetupTried) return
        plugin.autoSetupTried = true
        if (setupScript === "" || !plugin.setupNeeded()) return
        markerProbe.running = true
    }

    Process {
        id: markerProbe
        running: false
        command: ["bash", "-c", "test -f \"$1\"", "--", plugin.autoSetupMarker]
        onExited: (code) => { if (code !== 0) autoSetupProc.running = true }
    }
    Process {
        id: autoSetupProc
        command: ["bash", plugin.setupScript, "--auto"]
        onExited: (code) => {
            console.log("tide-island: auto-setup finished (exit " + code + ")")
            markerWrite.running = true
            plugin.refreshStatus()
        }
    }
    Process {
        id: markerWrite
        running: false
        command: ["bash", "-c",
            "d=$(dirname \"$1\"); mkdir -p \"$d\"; touch \"$1\"", "--",
            plugin.autoSetupMarker]
    }
    Timer {
        id: autoSetupDelay
        interval: 1200
        onTriggered: plugin.maybeAutoSetup()
    }

    property bool barHiddenPending: false
    onBarHiddenChanged: if (plugin.barHidden !== plugin.barHiddenPending) {
        plugin.barHiddenPending = plugin.barHidden
        plugin.scheduleReconcile()
    }

    // Debounce so a burst of flag flips collapses into one systemctl call,
    // and so a config rewrite doesn't fight an in-flight reconcile.
    Timer {
        id: reconcileTimer
        interval: 150
        onTriggered: plugin.runReconcile()
    }

    function scheduleReconcile() { reconcileTimer.restart() }

    function runReconcile() {
        if (!plugin.configOk) return
        if (plugin.getConfig("coordinateWithBar") !== true) return
        syncProc.running = true
    }

    Process {
        id: syncProc
        command: ["bash", plugin.syncScript, "reconcile"]
        onExited: (code) => plugin.refreshStatus()
    }

    // Flip the bar-off flag, then let the normal probe + reconcile path take
    // over. Works whether or not the CLI shim is installed, because the shell
    // service is the authoritative actor.
    Process {
        id: flipProc
        running: false
        command: ["bash", "-c",
            "flag=$HOME/.local/state/omarchy/toggles/bar-off; " +
            "mkdir -p \"$HOME/.local/state/omarchy/toggles\"; " +
            "if [[ -f \"$flag\" ]]; then rm -f \"$flag\"; else touch \"$flag\"; fi"]
        onExited: (code) => {
            plugin.refreshStatus()
            plugin.probeBar()
            plugin.scheduleReconcile()
            plugin.nudgeDependents()
        }
    }

    // ----------------------------------------------------------- integrations

    // Best-effort nudges so the bar and the suppressed OSD/notifications never
    // strand after a rapid toggle. Silently ignored when the patches aren't
    // applied or the targets are first-party.
    function nudgeDependents() {
        Quickshell.exec(["bash", "-c",
            "omarchy-shell -q omarchy.bar syncHidden 2>/dev/null || true; " +
            "omarchy-shell -q osd syncSuppression 2>/dev/null || true; " +
            "omarchy-shell -q notifications syncSuppression 2>/dev/null || true"])
    }

    function runSetup() {
        if (setupScript === "") return "unavailable"
        Quickshell.execDetached([launchTerminal, setupScript])
        return "ok"
    }

    // ----------------------------------------------------------------- status

    function jsonStatus() {
        return JSON.stringify({
            plugin: "mehir.tide-island",
            barHidden: plugin.barHidden,
            tideInstalled: plugin.tideInstalled,
            tideActive: plugin.tideActive,
            cliInstalled: plugin.cliInstalled,
            osdSuppression: plugin.osdSuppression,
            notificationsSuppression: plugin.notificationsSuppression,
            coordinateWithBar: plugin.getConfig("coordinateWithBar"),
            startWithBarHidden: plugin.getConfig("startWithBarHidden"),
            stopWithBarShown: plugin.getConfig("stopWithBarShown"),
            suppressOsd: plugin.getConfig("suppressOsd"),
            suppressNotifications: plugin.getConfig("suppressNotifications"),
            serviceName: plugin.getConfig("serviceName"),
            needsSetup: plugin.needsSetup,
            configOk: plugin.configOk,
            configError: plugin.configError,
            configPath: plugin.configPath
        })
    }

    function jsonConfig() {
        return JSON.stringify({
            configOk: plugin.configOk,
            configError: plugin.configError,
            config: {
                coordinateWithBar: plugin.getConfig("coordinateWithBar"),
                startWithBarHidden: plugin.getConfig("startWithBarHidden"),
                stopWithBarShown: plugin.getConfig("stopWithBarShown"),
                suppressOsd: plugin.getConfig("suppressOsd"),
                suppressNotifications: plugin.getConfig("suppressNotifications"),
                serviceName: plugin.getConfig("serviceName"),
                togglesDir: plugin.getConfig("togglesDir"),
                barOffFile: plugin.getConfig("barOffFile")
            }
        })
    }

    function refreshStatus() { barProbe.running = true }

    // ------------------------------------------------------------------- IPC

    IpcHandler {
        target: "tide-island"

        function ping(): string { return "ok" }
        function toggle(): string {
            if (!plugin.configOk) return "misconfigured"
            flipProc.running = true
            return "ok"
        }
        function sync(): string {
            plugin.probeBar()
            plugin.scheduleReconcile()
            plugin.nudgeDependents()
            return "ok"
        }
        function refresh(): string {
            plugin.refreshStatus()
            plugin.scheduleReconcile()
            return "ok"
        }
        function status(): string { return plugin.jsonStatus() }
        function config(): string { return plugin.jsonConfig() }
        function setup(): string { return plugin.runSetup() }
    }

    Component.onCompleted: {
        configFile.reload()
        plugin.probeBar()
        plugin.scheduleReconcile()
        autoSetupDelay.start()
    }

    // If this plugin is *removed* (e.g. `omarchy plugin remove`, which deletes
    // the directory without running any hook) the shell destroys this service.
    // The directory is deleted just after that, so wait a moment and, only if
    // it really is gone, undo the OSD/notification stand-down and everything
    // else we installed. A hot-reload or a plain disable leaves the directory
    // in place, so the guard makes this a no-op then.
    Component.onDestruction: {
        Quickshell.execDetached([
            "bash", "-c",
            "sleep 3; bash \"$1\" --remove-clones --remove-runtime --purge-config --if-plugin-gone --final",
            "--", plugin.teardownHelper])
    }
}