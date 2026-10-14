import QtCore
import QtQuick
import Quickshell.Io
import Quickshell.Widgets
import IslandBackend

FocusScope {
    id: root

    signal closeRequested
    signal wallpaperApplied(string filePath)
    signal wallpaperApplySucceeded(string filePath)

    property bool showCondition: false
    property string iconFontFamily: ""
    property string textFontFamily: ""
    property string startMode: "wallpapers"
    readonly property var userConfig: UserConfig

    property bool pywalEnabled: userConfig.wallpaperPywalEnabled
    property bool customCommandEnabled: userConfig.wallpaperCustomCommandEnabled === true
    property string customCommand: userConfig.wallpaperCustomCommand === undefined || userConfig.wallpaperCustomCommand === null ? "" : String(userConfig.wallpaperCustomCommand)
    property int transitionFps: boundedInt(userConfig.wallpaperTransitionFps, 60, 1, 240)
    property int transitionStep: boundedInt(userConfig.wallpaperTransitionStep, 5, 1, 255)
    property real transitionDuration: boundedReal(userConfig.wallpaperTransitionDuration, 3.0, 0, 120)
    property int transitionAngle: boundedInt(userConfig.wallpaperTransitionAngle, 45, 0, 360)
    property string transitionPosition: nonEmptyString(userConfig.wallpaperTransitionPosition, "center")
    property string transitionBezier: nonEmptyString(userConfig.wallpaperTransitionBezier, ".54,0,.34,.99")
    property string transitionWave: nonEmptyString(userConfig.wallpaperTransitionWave, "20,20")
    property bool transitionInvertY: userConfig.wallpaperTransitionInvertY
    property string wallpaperDir: userConfig.wallpaperLibraryPath
    property string targetWallpaperPath: userConfig.wallpaperPath
    property int thumbnailWidth: 640
    property int thumbnailHeight: 360
    property int thumbnailQuality: 80

    // ── Omarchy integration (added by the omarchy-tide-island plugin) ────────
    // When Omarchy is present the picker lists the current theme's backgrounds
    // and applies them through Omarchy, so both interfaces stay in sync. It
    // also exposes a Themes tab that switches Omarchy themes. Absent Omarchy,
    // everything falls back to the original library-path behaviour.
    property bool omarchyMode: false
    property string mode: "wallpapers"
    property string omarchyThemeSlug: ""
    property string omarchyThemeName: ""
    property string omarchyCurrentBackground: ""
    property var omarchyBackgroundDirs: []
    property bool stateProbed: false
    property bool themesLoaded: false
    property bool themesLoading: false
    property string latestAppliedTheme: ""

    readonly property string bridgeScript: {
        const candidate = Qt.resolvedUrl("../../scripts/omarchy-bridge.sh").toString();
        return candidate.startsWith("file://") ? decodeURIComponent(candidate.substring(7)) : candidate;
    }

    property bool wallpapersLoaded: false
    property string activeWallpaper: ""
    property string latestAppliedWallpaper: ""
    property bool acceptingScanResults: false
    property bool closeAfterApply: false
    property bool releasingResources: false
    property var wallpaperIndexByPath: ({})

    property string searchQuery: ""
    property var filteredIndexByPath: ({})

    ListModel {
        id: filteredWallpapers
    }

    ListModel {
        id: allThemes
    }

    ListModel {
        id: filteredThemes
    }

    function matchesSearch(fileName) {
        if (root.searchQuery === "")
            return true;
        return fileName.toLowerCase().indexOf(root.searchQuery.toLowerCase()) >= 0;
    }

    function rebuildFilteredWallpapers() {
        filteredWallpapers.clear();
        filteredIndexByPath = ({});
        for (let i = 0; i < allWallpapers.count; i++) {
            const item = allWallpapers.get(i);
            if (matchesSearch(item.fileName)) {
                filteredIndexByPath[item.filePath] = filteredWallpapers.count;
                filteredWallpapers.append(item);
            }
        }
        syncCurrentIndex();
    }

    function syncFilteredEntry(filePath) {
        const sourceIndex = wallpaperIndexByPath[filePath];
        if (sourceIndex === undefined)
            return;
        const item = allWallpapers.get(sourceIndex);
        const matches = matchesSearch(item.fileName);
        const existingIndex = filteredIndexByPath[filePath];

        if (matches) {
            if (existingIndex === undefined) {
                filteredIndexByPath[filePath] = filteredWallpapers.count;
                filteredWallpapers.append(item);
            } else {
                filteredWallpapers.set(existingIndex, item);
            }
        } else if (existingIndex !== undefined) {
            filteredWallpapers.remove(existingIndex);
            delete filteredIndexByPath[filePath];
            for (const path in filteredIndexByPath) {
                if (filteredIndexByPath[path] > existingIndex)
                    filteredIndexByPath[path]--;
            }
        }
    }

    function themeIndexBySlug(slug) {
        for (let i = 0; i < allThemes.count; i++) {
            if (allThemes.get(i).slug === slug)
                return i;
        }
        return -1;
    }

    function rebuildFilteredThemes() {
        filteredThemes.clear();
        for (let i = 0; i < allThemes.count; i++) {
            const item = allThemes.get(i);
            if (matchesSearch(item.themeName))
                filteredThemes.append(item);
        }
        syncCurrentThemeIndex();
    }

    function upsertTheme(record) {
        if (!record || !record.slug)
            return;
        const slug = String(record.slug);
        const modelItem = {
            slug: slug,
            themeName: String(record.name || slug),
            thirdParty: record.thirdParty === true,
            previewSource: record.previewPath ? toFileUrl(String(record.previewPath)) : ""
        };
        const index = themeIndexBySlug(slug);
        if (index === -1)
            allThemes.append(modelItem);
        else
            allThemes.set(index, modelItem);
    }

    function effectiveThemeSlug() {
        return latestAppliedTheme !== "" ? latestAppliedTheme : omarchyThemeSlug;
    }

    function syncCurrentThemeIndex() {
        const slug = effectiveThemeSlug();
        if (slug === "")
            return;
        for (let i = 0; i < filteredThemes.count; i++) {
            if (filteredThemes.get(i).slug === slug) {
                themesView.currentIndex = i;
                return;
            }
        }
    }

    onSearchQueryChanged: {
        rebuildFilteredWallpapers();
        rebuildFilteredThemes();
    }
    property var pendingThumbnails: []
    property var pendingThumbnailKeys: ({})
    property bool thumbnailInFlight: false
    property string inFlightThumbnailSourcePath: ""
    property string inFlightThumbnailCachePath: ""

    readonly property string effectiveActiveWallpaper: latestAppliedWallpaper !== "" ? latestAppliedWallpaper : activeWallpaper
    readonly property string cacheRoot: localPath(StandardPaths.writableLocation(StandardPaths.GenericCacheLocation))
        + "/quickshell/dynamic_island/wallpaper-picker"

    // Directories the wallpaper scan reads. Under Omarchy these are the current
    // theme's background directories (user extras first); otherwise the single
    // configured library path, preserving the original behaviour.
    readonly property var scanDirs: {
        if (root.omarchyMode && root.omarchyBackgroundDirs && root.omarchyBackgroundDirs.length > 0)
            return root.omarchyBackgroundDirs;
        return root.wallpaperDir !== "" ? [root.wallpaperDir] : [];
    }
    readonly property var scanCommand: {
        const base = ["python3", "-c", root.scanScript, root.cacheRoot,
            String(root.thumbnailWidth), String(root.thumbnailHeight),
            String(root.thumbnailQuality)];
        return base.concat(root.scanDirs);
    }
    readonly property string scanScript: "import hashlib,json,os,sys\n"
        + "cache_dir=sys.argv[1]\n"
        + "tw,th,quality=sys.argv[2],sys.argv[3],sys.argv[4]\n"
        + "dirs=[os.path.expanduser(d) for d in sys.argv[5:] if d]\n"
        + "exts={'.jpg','.jpeg','.png','.webp','.gif','.avif','.tiff','.bmp'}\n"
        + "index_path=os.path.join(cache_dir,'wallpapers.json')\n"
        + "os.makedirs(cache_dir,exist_ok=True)\n"
        + "def thumb_path(path,st):\n"
        + "    key='{}|{}|{}|{}x{}|q{}'.format(path,st.st_mtime_ns,st.st_size,tw,th,quality)\n"
        + "    return os.path.join(cache_dir,'wallpaper-'+hashlib.sha1(key.encode('utf-8','surrogateescape')).hexdigest()[:24]+'.jpg')\n"
        + "def record(path):\n"
        + "    path=os.path.realpath(path)\n"
        + "    st=os.stat(path)\n"
        + "    cache_path=thumb_path(path,st)\n"
        + "    return {'filePath':path,'fileName':os.path.basename(path),'cachePath':cache_path,'cacheAvailable':os.path.isfile(cache_path),'mtime':st.st_mtime_ns,'size':st.st_size}\n"
        + "def emit(phase,records):\n"
        + "    for rec in records:\n"
        + "        rec=dict(rec)\n"
        + "        rec['phase']=phase\n"
        + "        print(json.dumps(rec,separators=(',',':')),flush=True)\n"
        + "def valid_path(path):\n"
        + "    return os.path.splitext(path)[1].lower() in exts and os.path.isfile(path)\n"
        + "cached=[]\n"
        + "try:\n"
        + "    with open(index_path,'r',encoding='utf-8') as f:\n"
        + "        for item in json.load(f):\n"
        + "            path=item.get('filePath','')\n"
        + "            if valid_path(path):\n"
        + "                cached.append(record(path))\n"
        + "except Exception:\n"
        + "    pass\n"
        + "emit('index',cached)\n"
        + "fresh=[]\n"
        + "seen=set()\n"
        + "for wallpaper_dir in dirs:\n"
        + "    if os.path.isdir(wallpaper_dir):\n"
        + "        for entry in sorted(os.scandir(wallpaper_dir),key=lambda e:e.name.lower()):\n"
        + "            if entry.is_file() and os.path.splitext(entry.name)[1].lower() in exts:\n"
        + "                try:\n"
        + "                    real=os.path.realpath(entry.path)\n"
        + "                    if real in seen:\n"
        + "                        continue\n"
        + "                    seen.add(real)\n"
        + "                    fresh.append(record(real))\n"
        + "                except OSError:\n"
        + "                    pass\n"
        + "emit('scan',fresh)\n"
        + "try:\n"
        + "    tmp=index_path+'.tmp'\n"
        + "    with open(tmp,'w',encoding='utf-8') as f:\n"
        + "        json.dump(fresh,f,separators=(',',':'))\n"
        + "    os.replace(tmp,index_path)\n"
        + "except Exception:\n"
        + "    pass\n"
    readonly property string applyScript: "import os,shutil,subprocess,sys\n"
        + "source,target,transition,step,duration,fps,angle,pos,bezier,wave,invert_y,pywal_enabled=sys.argv[1:13]\n"
        + "if not source:\n"
        + "    sys.exit(2)\n"
        + "applied=source\n"
        + "if target:\n"
        + "    target=os.path.expanduser(target)\n"
        + "    if os.path.realpath(source) != os.path.realpath(target):\n"
        + "        os.makedirs(os.path.dirname(target) or '.',exist_ok=True)\n"
        + "        shutil.copy2(source,target)\n"
        + "    applied=target\n"
        + "cmd=['awww','img',applied,'--transition-type',transition,'--transition-step',step,'--transition-duration',duration,'--transition-fps',fps,'--transition-angle',angle,'--transition-pos',pos,'--transition-bezier',bezier,'--transition-wave',wave]\n"
        + "if invert_y == 'true':\n"
        + "    cmd.append('--invert-y')\n"
        + "result=subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
        + "if result.returncode == 0 and pywal_enabled == 'true':\n"
        + "    if not shutil.which('wal'):\n"
        + "        print(\"Pywal is enabled, but the 'wal' command was not found in PATH.\",file=sys.stderr)\n"
        + "        sys.exit(127)\n"
        + "    result=subprocess.run(['wal','-n','-q','-i',source])\n"
        + "sys.exit(result.returncode)\n"

    readonly property var transitionTypes: ["none", "simple", "fade", "left", "right", "top", "bottom", "wipe", "wave", "grow", "center", "any", "outer", "random"]
    readonly property string configuredTransitionType: validTransitionType(userConfig.wallpaperTransitionType)

    focus: showCondition
    activeFocusOnTab: true
    anchors.fill: parent
    opacity: showCondition ? 1 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: showCondition ? 240 : 120
            easing.type: Easing.InOutQuad
        }
    }

    onShowConditionChanged: {
        if (showCondition) {
            root.mode = root.startMode;
            root.probeOmarchy();
            root.grabKeyboardFocus();
        } else {
            releaseResources();
        }
    }

    Component.onDestruction: releaseResources()

    function startScan() {
        releasingResources = false;
        acceptingScanResults = true;
        wallpapersLoaded = false;
        wallpaperIndexByPath = ({});
        pendingThumbnails = [];
        pendingThumbnailKeys = ({});
        thumbnailInFlight = false;
        inFlightThumbnailSourcePath = "";
        inFlightThumbnailCachePath = "";
        allWallpapers.clear();
        filteredWallpapers.clear();
        filteredIndexByPath = ({});
        if (scanProcess.running)
            scanProcess.running = false;
        scanProcess.running = true;
    }

    function releaseResources() {
        if (releasingResources)
            return;
        releasingResources = true;
        acceptingScanResults = false;
        closeAfterApply = false;
        if (scanProcess.running)
            scanProcess.running = false;
        if (applyProcess.running)
            applyProcess.running = false;
        if (customApplyProcess.running)
            customApplyProcess.running = false;
        if (omarchyBackgroundApplyProcess.running)
            omarchyBackgroundApplyProcess.running = false;
        if (themesProcess.running)
            themesProcess.running = false;
        if (themeApplyProcess.running)
            themeApplyProcess.running = false;
        themesLoading = false;
        pendingThumbnails = [];
        pendingThumbnailKeys = ({});
        thumbnailInFlight = false;
        inFlightThumbnailSourcePath = "";
        inFlightThumbnailCachePath = "";
        wallpapersLoaded = false;
        wallpaperIndexByPath = ({});
        allWallpapers.clear();
        filteredWallpapers.clear();
        filteredIndexByPath = ({});
        releasingResources = false;
    }

    function localPath(value) {
        if (value === undefined || value === null)
            return "";
        if (value.toLocalFile)
            return value.toLocalFile();

        const text = String(value);
        return text.startsWith("file://") ? text.substring(7) : text;
    }

    function toFileUrl(localFile) {
        return localFile === "" ? "" : ("file://" + encodeURI(localFile));
    }

    function thumbnailUrl(cachePath, revision) {
        return cachePath === "" ? "" : (toFileUrl(cachePath) + "?v=" + revision);
    }

    function displayPath(path) {
        return path === "" ? "wallpaperLibraryPath" : path;
    }

    function boundedInt(value, fallback, minimumValue, maximumValue) {
        const number = Number(value);
        if (!isFinite(number))
            return fallback;
        return Math.max(minimumValue, Math.min(maximumValue, Math.round(number)));
    }

    function boundedReal(value, fallback, minimumValue, maximumValue) {
        const number = Number(value);
        if (!isFinite(number))
            return fallback;
        return Math.max(minimumValue, Math.min(maximumValue, number));
    }

    function nonEmptyString(value, fallback) {
        const text = String(value === undefined || value === null ? "" : value).trim();
        return text.length > 0 ? text : fallback;
    }

    function validTransitionType(value) {
        const text = nonEmptyString(value, "center");
        return transitionTypes.indexOf(text) >= 0 ? text : "center";
    }

    // ── Omarchy probing and theme list (plugin addition) ─────────────────────
    function probeOmarchy() {
        stateProbed = false;
        if (omarchyStateProcess.running)
            omarchyStateProcess.running = false;
        omarchyStateProcess.running = true;
    }

    function applyOmarchyState(text) {
        stateProbed = true;
        let parsed = null;
        try {
            parsed = JSON.parse(String(text).trim());
        } catch (error) {
            parsed = null;
        }
        const previousSlug = omarchyThemeSlug;
        omarchyMode = !!(parsed && parsed.omarchy);
        omarchyThemeSlug = parsed && parsed.currentSlug ? String(parsed.currentSlug) : "";
        omarchyThemeName = parsed && parsed.currentName ? String(parsed.currentName) : "";
        omarchyCurrentBackground = parsed && parsed.currentBackground ? String(parsed.currentBackground) : "";
        omarchyBackgroundDirs = parsed && Array.isArray(parsed.backgroundDirs) ? parsed.backgroundDirs : [];
        // A theme change (made here or elsewhere) means the background set moved.
        if (omarchyThemeSlug !== previousSlug) {
            wallpapersLoaded = false;
            latestAppliedTheme = "";
        }
        if (root.mode === "themes")
            ensureThemesLoaded();
        else if (!wallpapersLoaded)
            startScan();
        else
            syncCurrentIndex();
    }

    function switchMode(nextMode) {
        if (nextMode === root.mode)
            return;
        root.mode = nextMode;
        if (nextMode === "themes") {
            ensureThemesLoaded();
        } else {
            if (!wallpapersLoaded)
                startScan();
            else
                syncCurrentIndex();
        }
    }

    function ensureThemesLoaded() {
        if (themesLoaded || themesLoading)
            return;
        themesLoading = true;
        if (themesProcess.running)
            themesProcess.running = false;
        themesProcess.running = true;
    }

    function finishThemes() {
        themesLoading = false;
        themesLoaded = true;
        syncCurrentThemeIndex();
    }

    function resetThemes() {
        allThemes.clear();
        filteredThemes.clear();
        themesLoaded = false;
    }

    function applyTheme(slug) {
        if (slug === "")
            return;
        latestAppliedTheme = slug;
        if (themeApplyProcess.running)
            themeApplyProcess.running = false;
        themeApplyProcess.themeName = slug;
        themeApplyProcess.running = true;
    }

    function handleThemeApplied(slug, ok) {
        if (ok) {
            omarchyThemeSlug = slug;
            wallpapersLoaded = false;
            resetThemes();
            probeOmarchy();
        } else {
            latestAppliedTheme = "";
        }
    }

    function isActiveWallpaper(filePath) {
        if (root.omarchyMode)
            return filePath === root.omarchyCurrentBackground;
        return filePath === root.effectiveActiveWallpaper;
    }

    function activeView() {
        return root.mode === "themes" ? themesView : pathView;
    }

    function enqueueThumbnail(sourcePath, cachePath) {
        if (!root.showCondition || sourcePath === "" || cachePath === "")
            return;
        if (cachePath === inFlightThumbnailCachePath)
            return;
        if (pendingThumbnailKeys[cachePath])
            return;
        pendingThumbnailKeys[cachePath] = true;
        pendingThumbnails.push({
            sourcePath: sourcePath,
            cachePath: cachePath
        });
        startNextThumbnail();
    }

    function startNextThumbnail() {
        if (!root.showCondition || thumbnailInFlight || pendingThumbnails.length === 0)
            return;

        const next = pendingThumbnails.shift();
        inFlightThumbnailSourcePath = next.sourcePath;
        inFlightThumbnailCachePath = next.cachePath;
        delete pendingThumbnailKeys[next.cachePath];
        thumbnailInFlight = true;
        SystemServices.generateWallpaperThumbnail(
            next.sourcePath,
            next.cachePath,
            root.cacheRoot,
            root.thumbnailWidth,
            root.thumbnailHeight,
            root.thumbnailQuality
        );
    }

    function upsertWallpaper(record) {
        if (!record || !record.filePath)
            return;

        // In Omarchy mode the cached index belongs to whatever theme was active
        // during the previous scan, so ignore it and wait for the fresh scan.
        if (root.omarchyMode && record.phase === "index")
            return;

        const filePath = String(record.filePath);
        const cachePath = String(record.cachePath || "");
        const cacheRevision = Number(record.mtime || 0);
        const cacheAvailable = !!record.cacheAvailable;
        const existingIndex = wallpaperIndexByPath[filePath];
        const modelItem = {
            filePath: filePath,
            fileName: String(record.fileName || filePath),
            cachePath: cachePath,
            thumbnailSource: cacheAvailable ? thumbnailUrl(cachePath, cacheRevision) : "",
            thumbnailReady: cacheAvailable,
            thumbnailRequested: cacheAvailable,
            cacheRevision: cacheRevision
        };

        if (existingIndex === undefined) {
            wallpaperIndexByPath[filePath] = allWallpapers.count;
            allWallpapers.append(modelItem);
        } else {
            allWallpapers.set(existingIndex, modelItem);
        }

        if (!cacheAvailable)
            enqueueThumbnail(filePath, cachePath);

        syncFilteredEntry(filePath);
    }

    function syncCurrentIndex() {
        const active = root.omarchyMode ? root.omarchyCurrentBackground : root.effectiveActiveWallpaper;
        if (active === "")
            return;
        for (let i = 0; i < filteredWallpapers.count; i++) {
            if (filteredWallpapers.get(i).filePath === active) {
                pathView.currentIndex = i;
                return;
            }
        }
    }

    function grabKeyboardFocus() {
        root.focus = true;
        root.forceActiveFocus();
    }

    function focusSearch() {
        searchBar.expanded = true;
        searchInput.forceActiveFocus();
    }

    function moveNext() {
        const view = root.activeView();
        if (view)
            view.incrementCurrentIndex();
    }

    function movePrevious() {
        const view = root.activeView();
        if (view)
            view.decrementCurrentIndex();
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Escape:
            root.closeRequested();
            event.accepted = true;
            break;
        case Qt.Key_Slash:
            root.focusSearch();
            event.accepted = true;
            break;
        case Qt.Key_Right:
        case Qt.Key_L:
        case Qt.Key_Tab:
            root.moveNext();
            event.accepted = true;
            break;
        case Qt.Key_Left:
        case Qt.Key_H:
        case Qt.Key_Backtab:
            root.movePrevious();
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (root.mode === "themes") {
                if (filteredThemes.count > 0)
                    root.applyTheme(filteredThemes.get(themesView.currentIndex).slug);
            } else if (filteredWallpapers.count > 0) {
                root.applyWallpaper(filteredWallpapers.get(pathView.currentIndex).filePath);
            }
            event.accepted = true;
            break;
        }
    }

    ListModel {
        id: allWallpapers
    }

    function applyWallpaper(filePath) {
        const targetPath = root.targetWallpaperPath;
        const commandText = root.customCommand.trim();
        const useCustomCommand = root.customCommandEnabled && commandText.length > 0;
        if (filePath === "")
            return;
        latestAppliedWallpaper = filePath;
        wallpaperApplied(filePath);
        closeAfterApply = true;
        if (applyProcess.running)
            applyProcess.running = false;
        if (customApplyProcess.running)
            customApplyProcess.running = false;
        if (omarchyBackgroundApplyProcess.running)
            omarchyBackgroundApplyProcess.running = false;

        // Under Omarchy the wallpaper is applied through Omarchy so the shell's
        // background plugin and the `current/background` symlink stay in step.
        if (root.omarchyMode) {
            omarchyBackgroundApplyProcess.backgroundPath = filePath;
            omarchyBackgroundApplyProcess.running = true;
            return;
        }
        if (useCustomCommand) {
            customApplyProcess.wallpaperPath = filePath;
            customApplyProcess.targetPath = targetPath;
            customApplyProcess.commandText = root.customCommand;
            customApplyProcess.running = true;
            return;
        }
        applyProcess.wallpaperPath = filePath;
        applyProcess.targetPath = targetPath;
        applyProcess.transitionType = configuredTransitionType;
        applyProcess.running = true;
    }

    Process {
        id: scanProcess
        command: root.scanCommand
        stdout: SplitParser {
            onRead: data => {
                if (!root.acceptingScanResults)
                    return;
                try {
                    root.upsertWallpaper(JSON.parse(data));
                } catch (error) {
                }
            }
        }
        onExited: {
            if (!root.acceptingScanResults)
                return;
            root.acceptingScanResults = false;
            root.wallpapersLoaded = true;
            root.syncCurrentIndex();
            root.startNextThumbnail();
        }
    }

    // ── Omarchy bridge processes (plugin addition) ───────────────────────────
    Process {
        id: omarchyStateProcess
        command: ["bash", root.bridgeScript, "state"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.applyOmarchyState(this.text)
        }
    }

    Process {
        id: themesProcess
        command: ["bash", root.bridgeScript, "themes"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    root.upsertTheme(JSON.parse(data));
                } catch (error) {
                }
            }
        }
        onExited: root.finishThemes()
    }

    Process {
        id: themeApplyProcess
        property string themeName: ""
        command: ["bash", root.bridgeScript, "apply-theme", themeName]
        running: false
        onExited: function(exitCode) {
            root.handleThemeApplied(themeName, exitCode === 0);
        }
    }

    Process {
        id: omarchyBackgroundApplyProcess
        property string backgroundPath: ""
        command: ["bash", root.bridgeScript, "apply-background", backgroundPath]
        running: false
        onExited: function(exitCode) {
            running = false;
            if (exitCode === 0) {
                root.omarchyCurrentBackground = backgroundPath;
                root.wallpaperApplySucceeded(backgroundPath);
            }
            if (root.closeAfterApply) {
                root.closeAfterApply = false;
                root.closeRequested();
            }
        }
    }

    Connections {
        target: SystemServices

        function onWallpaperThumbnailFinished(sourcePath, finishedCachePath, cacheAvailable, updated, errorString) {
            if (sourcePath !== root.inFlightThumbnailSourcePath || finishedCachePath !== root.inFlightThumbnailCachePath)
                return;

            root.thumbnailInFlight = false;
            root.inFlightThumbnailSourcePath = "";
            root.inFlightThumbnailCachePath = "";

            if (root.showCondition && cacheAvailable && errorString === "") {
                const modelIndex = root.wallpaperIndexByPath[sourcePath];
                if (modelIndex !== undefined && modelIndex >= 0 && modelIndex < allWallpapers.count) {
                    const revision = Date.now();
                    allWallpapers.setProperty(modelIndex, "thumbnailReady", true);
                    allWallpapers.setProperty(modelIndex, "thumbnailRequested", true);
                    allWallpapers.setProperty(modelIndex, "thumbnailSource", root.thumbnailUrl(finishedCachePath, revision));
                    allWallpapers.setProperty(modelIndex, "cacheRevision", revision);

                    const filteredIdx = root.filteredIndexByPath[sourcePath];
                    if (filteredIdx !== undefined) {
                        filteredWallpapers.setProperty(filteredIdx, "thumbnailReady", true);
                        filteredWallpapers.setProperty(filteredIdx, "thumbnailRequested", true);
                        filteredWallpapers.setProperty(filteredIdx, "thumbnailSource", root.thumbnailUrl(finishedCachePath, revision));
                        filteredWallpapers.setProperty(filteredIdx, "cacheRevision", revision);
                    }
                }
            }

            root.startNextThumbnail();
        }
    }

    Process {
        id: applyProcess
        property string wallpaperPath: ""
        property string targetPath: ""
        property string transitionType: "center"
        command: [
            "python3", "-c", root.applyScript,
            wallpaperPath,
            targetPath,
            transitionType,
            String(root.transitionStep),
            String(root.transitionDuration),
            String(root.transitionFps),
            String(root.transitionAngle),
            root.transitionPosition,
            root.transitionBezier,
            root.transitionWave,
            root.transitionInvertY ? "true" : "false",
            root.pywalEnabled ? "true" : "false"
        ]
        onExited: function(exitCode) {
            running = false;
            if (exitCode === 0)
                root.wallpaperApplySucceeded(wallpaperPath);
            if (root.closeAfterApply) {
                root.closeAfterApply = false;
                root.closeRequested();
            }
        }
    }

    Process {
        id: customApplyProcess
        property string wallpaperPath: ""
        property string targetPath: ""
        property string commandText: ""
        command: [
            "bash", "-c", commandText,
            "tide-island-wallpaper",
            wallpaperPath,
            targetPath
        ]
        onExited: function(exitCode) {
            running = false;
            if (exitCode === 0)
                root.wallpaperApplySucceeded(wallpaperPath);
            if (root.closeAfterApply) {
                root.closeAfterApply = false;
                root.closeRequested();
            }
        }
    }

    readonly property real topPad: 14
    readonly property real botPad: 8
    readonly property real hPad: 12
    readonly property real headerH: 34
    readonly property real headerGap: 6
    readonly property real labelH: 22
    readonly property real labelGap: 5

    readonly property real cardW: Math.round(slotW * 1.15)
    readonly property real cardH: Math.round(cardW * 0.58)
    readonly property real spacing: slotW * 1.20

    readonly property real sideScale: 0.78

    readonly property real slotW: (width - hPad * 2) / 5

    readonly property real cardAreaH: height - topPad - headerH - headerGap - botPad
    readonly property real cardPathY: cardAreaH / 2

    // ── UI ────────────────────────────────────────────────────────────────────
    Column {
        anchors.fill: parent
        anchors.topMargin: root.topPad
        anchors.leftMargin: root.hPad
        anchors.rightMargin: root.hPad
        anchors.bottomMargin: root.botPad
        spacing: 6

        // ── Search bar (collapsible) ──────────────────────────────────────
        Item {
            id: searchBar
            property bool expanded: false

            width: parent.width
            height: 34

            Rectangle {
                id: searchBg
                width: searchBar.expanded ? searchBar.width : 34
                height: 34
                anchors.right: parent.right
                radius: 10
                color: Qt.rgba(1, 1, 1, searchBar.expanded ? 0.06 : (iconMouse.containsMouse ? 0.10 : 0.06))
                border.width: searchInput.activeFocus ? 1 : 0
                border.color: "#60a5fa"

                Behavior on width {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutCubic
                    }
                }
            }

            Rectangle {
                id: iconButton
                width: 34
                height: 34
                anchors.right: parent.right
                color: "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "\uf002"
                    font.family: root.iconFontFamily
                    font.pixelSize: 12
                    color: Qt.rgba(1, 1, 1, searchBar.expanded ? 0.55 : 0.35)
                }

                MouseArea {
                    id: iconMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !searchBar.expanded
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.focusSearch()
                }
            }

            TextInput {
                id: searchInput
                visible: searchBar.expanded
                anchors.left: searchBg.left
                anchors.right: clearButton.visible ? clearButton.left : iconButton.left
                anchors.leftMargin: 10
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                color: "white"
                font.pixelSize: 12
                font.family: root.textFontFamily
                clip: true
                selectByMouse: true
                onTextChanged: root.searchQuery = text

                onActiveFocusChanged: {
                    if (!activeFocus && text === "")
                        searchBar.expanded = false;
                }

                Keys.onEscapePressed: {
                    if (text !== "")
                        text = "";
                    else
                        searchBar.expanded = false;
                }
            }

            Text {
                visible: searchBar.expanded && searchInput.text === ""
                text: root.mode === "themes" ? "Search themes…" : "Search wallpapers…"
                font.pixelSize: 12
                font.family: root.textFontFamily
                color: Qt.rgba(1, 1, 1, 0.28)
                anchors.left: searchInput.left
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                id: clearButton
                visible: searchBar.expanded && searchInput.text !== ""
                width: 20
                height: 20
                radius: 10
                color: clearMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                anchors.right: iconButton.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    anchors.centerIn: parent
                    text: "\uf00d"
                    font.family: root.iconFontFamily
                    font.pixelSize: 10
                    color: Qt.rgba(1, 1, 1, 0.5)
                }

                MouseArea {
                    id: clearMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: searchInput.text = ""
                }
            }
        }
        // ── Carousel ───────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: root.cardAreaH

            // Empty state (wallpapers)
            Column {
                anchors.centerIn: parent
                spacing: 8
                visible: root.mode === "wallpapers" && (!root.wallpapersLoaded || filteredWallpapers.count === 0)

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: !root.wallpapersLoaded ? "Scanning…" : "\uf03e"
                    font.pixelSize: !root.wallpapersLoaded ? 12 : 26
                    font.family: !root.wallpapersLoaded ? root.textFontFamily : root.iconFontFamily
                    color: Qt.rgba(1, 1, 1, 0.22)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.wallpapersLoaded && filteredWallpapers.count === 0
                    text: allWallpapers.count === 0 ? ("No wallpapers found\nin " + root.displayPath(root.wallpaperDir)) : ("No wallpapers match \"" + root.searchQuery + "\"")
                    horizontalAlignment: Text.AlignHCenter
                    color: Qt.rgba(1, 1, 1, 0.22)
                    font.pixelSize: 11
                    font.family: root.textFontFamily
                    lineHeight: 1.5
                }
            }

            // Empty state (themes)
            Column {
                anchors.centerIn: parent
                spacing: 8
                visible: root.mode === "themes" && (!root.themesLoaded || filteredThemes.count === 0)

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: !root.themesLoaded ? "Loading themes…" : "\uf53f"
                    font.pixelSize: !root.themesLoaded ? 12 : 26
                    font.family: !root.themesLoaded ? root.textFontFamily : root.iconFontFamily
                    color: Qt.rgba(1, 1, 1, 0.22)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.themesLoaded && filteredThemes.count === 0
                    text: !root.omarchyMode
                        ? "Omarchy was not detected\non this system"
                        : (allThemes.count === 0 ? "No Omarchy themes found" : ("No themes match \"" + root.searchQuery + "\""))
                    horizontalAlignment: Text.AlignHCenter
                    color: Qt.rgba(1, 1, 1, 0.22)
                    font.pixelSize: 11
                    font.family: root.textFontFamily
                    lineHeight: 1.5
                }
            }

            PathView {
                id: pathView
                anchors.fill: parent
                model: root.showCondition && root.mode === "wallpapers" ? filteredWallpapers : null
                visible: root.mode === "wallpapers" && filteredWallpapers.count > 0
                clip: false

                pathItemCount: Math.min(filteredWallpapers.count, 5)
                cacheItemCount: 4
                snapMode: PathView.SnapToItem
                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange
                highlightMoveDuration: 200

                path: Path {
                    startX: pathView.width / 2 - root.spacing * 2
                    startY: root.cardPathY
                    PathLine {
                        x: pathView.width / 2 + root.spacing * 2
                        y: root.cardPathY
                    }
                }

                delegate: Item {
                    id: del
                    readonly property bool isCurrent: PathView.isCurrentItem
                    readonly property bool onPath: PathView.onPath

                    width: root.cardW
                    height: root.cardH + root.labelGap + root.labelH
                    z: isCurrent ? 3 : 1

                    property real sc: isCurrent ? 1.0 : onPath ? root.sideScale : 0.0
                    Behavior on sc {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.OutCubic
                        }
                    }

                    property real op: isCurrent ? 1.0 : onPath ? 0.65 : 0.0
                    Behavior on op {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    Item {
                        id: inner
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        width: root.cardW
                        height: root.cardH + root.labelGap + root.labelH
                        scale: del.sc
                        opacity: del.op
                        transformOrigin: Item.Center

                        // Clipped image
                        ClippingRectangle {
                            id: thumb
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            radius: 14
                            color: "#1a1a1a"
                            antialiasing: false

                            Image {
                                anchors.fill: parent
                                source: root.showCondition && model.thumbnailSource ? model.thumbnailSource : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                smooth: true
                                mipmap: false
                                sourceSize: Qt.size(root.cardW * 2, root.cardH * 2)

                                Rectangle {
                                    anchors.fill: parent
                                    color: "#282828"
                                    opacity: parent.status === Image.Ready ? 0 : 1
                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: 200
                                        }
                                    }
                                }
                            }
                        }

                        // Border overlay
                        Rectangle {
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            radius: 14
                            color: "transparent"
                            border.width: root.isActiveWallpaper(model.filePath) ? 2.5 : 0
                            border.color: "#60a5fa"
                            Behavior on border.width {
                                NumberAnimation {
                                    duration: 150
                                }
                            }

                        }

                        // Click area
                        MouseArea {
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (del.isCurrent)
                                    root.applyWallpaper(model.filePath);
                                else
                                    pathView.currentIndex = index;
                            }
                        }

                        // Filename label
                        Text {
                            anchors.top: thumb.bottom
                            anchors.topMargin: root.labelGap
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW - 4
                            text: model.fileName
                            color: del.isCurrent ? "white" : Qt.rgba(1, 1, 1, 0.50)
                            font.pixelSize: del.isCurrent ? 11 : 10
                            font.family: root.textFontFamily
                            font.weight: del.isCurrent ? Font.Medium : Font.Normal
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideMiddle
                            Behavior on color {
                                ColorAnimation {
                                    duration: 150
                                }
                            }
                        }
                    }
                }
            }

            // ── Themes carousel (plugin addition) ─────────────────────────
            PathView {
                id: themesView
                anchors.fill: parent
                model: root.showCondition && root.mode === "themes" ? filteredThemes : null
                visible: root.mode === "themes" && filteredThemes.count > 0
                clip: false

                pathItemCount: Math.min(filteredThemes.count, 5)
                cacheItemCount: 4
                snapMode: PathView.SnapToItem
                preferredHighlightBegin: 0.5
                preferredHighlightEnd: 0.5
                highlightRangeMode: PathView.StrictlyEnforceRange
                highlightMoveDuration: 200

                path: Path {
                    startX: themesView.width / 2 - root.spacing * 2
                    startY: root.cardPathY
                    PathLine {
                        x: themesView.width / 2 + root.spacing * 2
                        y: root.cardPathY
                    }
                }

                delegate: Item {
                    id: themeDel
                    readonly property bool isCurrent: PathView.isCurrentItem
                    readonly property bool onPath: PathView.onPath
                    readonly property bool isActive: model.slug === root.effectiveThemeSlug()

                    width: root.cardW
                    height: root.cardH + root.labelGap + root.labelH
                    z: isCurrent ? 3 : 1

                    property real sc: isCurrent ? 1.0 : onPath ? root.sideScale : 0.0
                    Behavior on sc {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.OutCubic
                        }
                    }

                    property real op: isCurrent ? 1.0 : onPath ? 0.65 : 0.0
                    Behavior on op {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    Item {
                        id: themeInner
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        width: root.cardW
                        height: root.cardH + root.labelGap + root.labelH
                        scale: themeDel.sc
                        opacity: themeDel.op
                        transformOrigin: Item.Center

                        ClippingRectangle {
                            id: themeThumb
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            radius: 14
                            color: "#1a1a1a"
                            antialiasing: false

                            Image {
                                anchors.fill: parent
                                source: root.showCondition && model.previewSource ? model.previewSource : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                smooth: true
                                mipmap: false
                                sourceSize: Qt.size(root.cardW * 2, root.cardH * 2)

                                Rectangle {
                                    anchors.fill: parent
                                    color: "#282828"
                                    opacity: parent.status === Image.Ready ? 0 : 1
                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: 200
                                        }
                                    }
                                }
                            }
                        }

                        // Active-theme border
                        Rectangle {
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            radius: 14
                            color: "transparent"
                            border.width: themeDel.isActive ? 2.5 : 0
                            border.color: "#60a5fa"
                            Behavior on border.width {
                                NumberAnimation {
                                    duration: 150
                                }
                            }
                        }

                        // Third-party badge
                        Rectangle {
                            visible: model.thirdParty
                            anchors.top: themeThumb.top
                            anchors.left: themeThumb.left
                            anchors.margins: 8
                            width: badgeText.implicitWidth + 12
                            height: 18
                            radius: 9
                            color: Qt.rgba(0, 0, 0, 0.55)

                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: "3rd-party"
                                color: Qt.rgba(1, 1, 1, 0.8)
                                font.pixelSize: 9
                                font.family: root.textFontFamily
                            }
                        }

                        MouseArea {
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW
                            height: root.cardH
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (themeDel.isCurrent)
                                    root.applyTheme(model.slug);
                                else
                                    themesView.currentIndex = index;
                            }
                        }

                        Text {
                            anchors.top: themeThumb.bottom
                            anchors.topMargin: root.labelGap
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.cardW - 4
                            text: model.themeName
                            color: themeDel.isCurrent ? "white" : Qt.rgba(1, 1, 1, 0.50)
                            font.pixelSize: themeDel.isCurrent ? 11 : 10
                            font.family: root.textFontFamily
                            font.weight: themeDel.isCurrent ? Font.Medium : Font.Normal
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideMiddle
                            Behavior on color {
                                ColorAnimation {
                                    duration: 150
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
