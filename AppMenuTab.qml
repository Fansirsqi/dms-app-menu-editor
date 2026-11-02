pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Modules.DDash
import qs.Modules.DDash.Overview

DashTabComponent {
    id: root

    // ---------------------------------------------------------------- helpers

    function t(text) {
        return I18n.trFor("appMenuEditor", text);
    }

    readonly property string appsDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ApplicationsLocation))
    readonly property string appsDirShort: Paths.shortenHome(appsDir)

    readonly property var appDirectories: {
        const dirs = [appsDir];
        const seen = {};
        seen[appsDir] = true;
        const dataDirs = (Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":");
        for (let i = 0; i < dataDirs.length; i++) {
            const dir = dataDirs[i].replace(/\/+$/, "") + "/applications";
            if (dir.length > 0 && !seen[dir]) {
                seen[dir] = true;
                dirs.push(dir);
            }
        }
        const home = Quickshell.env("HOME") || "";
        const extras = [
            home + "/.local/share/flatpak/exports/share/applications",
            "/var/lib/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications"
        ];
        for (let i = 0; i < extras.length; i++) {
            if (!seen[extras[i]]) {
                seen[extras[i]] = true;
                dirs.push(extras[i]);
            }
        }
        return dirs;
    }

    readonly property bool showHidden: options.showHidden === true

    // ---------------------------------------------------------------- state

    property string mode: "list" // list | edit
    property bool embedded: false
    property bool editing: false
    property bool editingSystem: false
    property string editPath: ""
    property string editWritePath: ""
    property string originalContent: ""

    property string searchText: ""

    property string fieldName: ""
    property string fieldExec: ""
    property string fieldIcon: ""
    property string fieldComment: ""
    property string fieldCategories: ""
    property string fieldGenericName: ""
    property bool fieldTerminal: false
    property string fieldFileName: ""
    property var envVars: []

    property bool confirmDelete: false
    property string errorText: ""
    property bool autoOpenPending: false

    property var entries: []
    property var knownFileNames: []
    property int scanSeq: 0
    property bool editContentReady: false
    property bool pendingSaveRequest: false
    property string dialogTool: ""

    property string pendingSavePath: ""
    property string pendingSaveContent: ""

    implicitHeight: DashMetrics.heightForRows(6)
    focusTarget: mode === "edit" ? nameField : searchField
    blocksTabNavigation: mode === "edit"

    readonly property real headerHeight: Theme.iconButtonSize
    readonly property real listRowHeight: Theme.iconSizeLarge + Theme.spacingL * 2
    readonly property real listIconSize: Theme.iconSizeLarge + Theme.spacingXS
    readonly property real editorIconSize: Theme.iconSizeLarge + Theme.spacingL
    readonly property real badgeHeight: Theme.iconSizeMedium

    // ---------------------------------------------------------------- derived

    readonly property var filteredEntries: {
        const needle = searchText.trim().toLowerCase();
        let list = entries;
        if (!showHidden)
            list = list.filter(entry => !entry.noDisplay && !entry.hidden);
        if (needle.length > 0) {
            list = list.filter(entry => {
                const haystack = [entry.name, entry.nameRaw, entry.exec, entry.comment, entry.fileName, entry.categories].join(" ").toLowerCase();
                return haystack.indexOf(needle) >= 0;
            });
        }
        return list.slice().sort((a, b) => (a.name || a.fileName).localeCompare(b.name || b.fileName));
    }

    readonly property string desiredFileName: {
        if (fieldFileName.trim().length > 0)
            return fieldFileName.trim();
        const slug = root.slugify(fieldName);
        return (slug.length > 0 ? slug : "app") + ".desktop";
    }

    readonly property string desiredPath: appsDir + "/" + desiredFileName
    readonly property string formIcon: fieldIcon.trim().length > 0 ? fieldIcon.trim() : inferIconName(fieldExec)
    readonly property bool formIconReady: formIcon.length > 0 && Paths.resolveIconPath(formIcon).length > 0

    function upsertEntry(entry) {
        if (!entry || !entry.filePath)
            return;
        const next = entries.filter(item => item.fileName !== entry.fileName);
        next.push(entry);
        entries = next;
    }

    function removeEntryByPath(filePath) {
        entries = entries.filter(entry => entry.filePath !== filePath);
    }

    function findEntry(filePath) {
        return entries.find(entry => entry.filePath === filePath) || null;
    }

    // ---------------------------------------------------------------- slugs

    function slugify(value) {
        let slug = (value || "").trim().toLowerCase();
        slug = slug.replace(/[^a-z0-9\u3400-\u9fff._-]+/g, "-");
        slug = slug.replace(/^[-.]+/, "").replace(/[-.]+$/, "");
        return slug;
    }

    function splitCommand(command) {
        const tokens = [];
        let current = "";
        let quote = "";
        for (let i = 0; i < command.length; i++) {
            const ch = command[i];
            if (quote.length > 0) {
                if (ch === quote)
                    quote = "";
                else
                    current += ch;
            } else if (ch === '"' || ch === "'") {
                quote = ch;
            } else if (/\s/.test(ch)) {
                if (current.length > 0) {
                    tokens.push(current);
                    current = "";
                }
            } else {
                current += ch;
            }
        }
        if (current.length > 0)
            tokens.push(current);
        return tokens;
    }

    // Best-effort icon name for entries that omit Icon=. Handles env
    // assignments, flatpak and simple shell wrappers.
    function inferIconName(exec) {
        const tokens = splitCommand((exec || "").replace(/%[fFuUdDnNickvm]/g, " "));
        let index = 0;
        while (index < tokens.length && (tokens[index] === "env" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[index])))
            index++;
        if (tokens[index] === "flatpak" && tokens[index + 1] === "run" && tokens[index + 2])
            return tokens[index + 2];
        if (/^(sh|bash|zsh|fish)$/.test(tokens[index] || "") && tokens[index + 1] === "-c" && tokens[index + 2])
            return inferIconName(tokens.slice(index + 2).join(" "));
        let base = (tokens[index] || "").split("/").pop();
        base = base.replace(/\.(desktop|sh|py|bin|AppImage|exe)$/i, "");
        if (!base || /^(env|sh|bash|zsh|fish|python\d*|node|perl|ruby|java|wine)$/.test(base))
            return "";
        return base.toLowerCase().replace(/[^a-z0-9._+-]+/g, "");
    }

    function resolvedIcon(exec, explicit) {
        const typed = (explicit || "").trim();
        if (typed.length > 0)
            return typed;
        const guess = inferIconName(exec);
        if (guess.length === 0)
            return "";
        return Paths.resolveIconPath(guess).length > 0 ? guess : "";
    }

    function uniquePath(fileName) {
        const used = new Set(knownFileNames);
        for (let i = 0; i < entries.length; i++)
            used.add(entries[i].fileName);
        let candidate = fileName;
        let counter = 2;
        while (used.has(candidate)) {
            candidate = fileName.replace(/\.desktop$/i, "") + "-" + counter + ".desktop";
            counter++;
        }
        return appsDir + "/" + candidate;
    }

    // ---------------------------------------------------------------- editor

    function resetForm() {
        fieldName = "";
        fieldExec = "";
        fieldIcon = "";
        fieldComment = "";
        fieldCategories = "";
        fieldGenericName = "";
        fieldTerminal = false;
        fieldFileName = "";
        envVars = [];
        errorText = "";
        confirmDelete = false;
    }

    function startCreate() {
        editing = false;
        editingSystem = false;
        editPath = "";
        editWritePath = "";
        originalContent = "";
        editContentReady = true;
        pendingSaveRequest = false;
        editReader.path = "";
        resetForm();
        mode = "edit";
        Qt.callLater(() => nameField.forceActiveFocus(Qt.OtherFocusReason));
    }

    function startEdit(entry) {
        if (!entry)
            return;
        editing = true;
        editingSystem = entry.isUser !== true;
        editPath = entry.filePath;
        editWritePath = editingSystem ? appsDir + "/" + entry.fileName : entry.filePath;
        originalContent = "";
        editContentReady = false;
        pendingSaveRequest = false;
        editReader.path = Paths.toFileUrl(entry.filePath);
        fieldName = entry.nameRaw || entry.name || "";
        const parsedExec = root.parseEnvPrefix(entry.exec || "");
        fieldExec = parsedExec.command;
        envVars = parsedExec.vars;
        fieldIcon = entry.icon || "";
        fieldComment = entry.comment || "";
        fieldCategories = entry.categories || "";
        fieldGenericName = entry.genericName || "";
        fieldTerminal = entry.terminal === true;
        fieldFileName = entry.fileName || "";
        errorText = "";
        confirmDelete = false;
        mode = "edit";
        Qt.callLater(() => nameField.forceActiveFocus(Qt.OtherFocusReason));
    }

    function cancelEdit() {
        mode = "list";
        editing = false;
        editingSystem = false;
        editPath = "";
        editWritePath = "";
        originalContent = "";
        editContentReady = false;
        pendingSaveRequest = false;
        editReader.path = "";
        resetForm();
        Qt.callLater(() => searchField.forceActiveFocus(Qt.OtherFocusReason));
    }

    function normalizeList(value) {
        const items = value.split(/[;,]/).map(item => item.trim()).filter(item => item.length > 0);
        if (items.length === 0)
            return "";
        return items.join(";") + ";";
    }

    function parseEnvPrefix(exec) {
        const text = exec || "";
        let index = 0;

        function skipSpaces() {
            while (index < text.length && /\s/.test(text[index]))
                index++;
        }

        function readToken() {
            let token = "";
            let quote = "";
            while (index < text.length) {
                const ch = text[index];
                if (quote.length > 0) {
                    if (ch === quote) {
                        quote = "";
                        index++;
                    } else {
                        token += ch;
                        index++;
                    }
                } else if (ch === '"' || ch === "'") {
                    quote = ch;
                    index++;
                } else if (/\s/.test(ch)) {
                    break;
                } else {
                    token += ch;
                    index++;
                }
            }
            return token;
        }

        skipSpaces();
        if (readToken() !== "env")
            return {
                command: text.trim(),
                vars: []
            };

        const vars = [];
        while (true) {
            skipSpaces();
            if (index >= text.length)
                break;
            const start = index;
            const token = readToken();
            if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(token)) {
                const eq = token.indexOf("=");
                vars.push({
                    name: token.slice(0, eq),
                    value: token.slice(eq + 1)
                });
            } else {
                index = start;
                break;
            }
        }
        skipSpaces();
        return {
            command: text.slice(index).trim(),
            vars: vars
        };
    }

    function isValidEnvName(name) {
        return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
    }

    function quoteEnvAssignment(name, value) {
        const raw = name + "=" + value;
        if (!/[\s"'\\]/.test(value))
            return raw;
        return '"' + raw.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    function buildEnvExec(command, vars) {
        const assignments = [];
        const list = vars || [];
        for (let i = 0; i < list.length; i++) {
            const name = (list[i].name || "").trim();
            if (name.length === 0)
                continue;
            assignments.push(quoteEnvAssignment(name, list[i].value || ""));
        }
        if (assignments.length === 0)
            return command;
        return "env " + assignments.join(" ") + " " + command;
    }

    function addEnvVar() {
        envVars = envVars.concat([{
            name: "",
            value: ""
        }]);
    }

    function removeEnvVar(index) {
        envVars = envVars.filter((item, i) => i !== index);
    }

    function buildContent(original, data) {
        const block = ["Type=Application", "Name=" + data.name];
        if (data.genericName)
            block.push("GenericName=" + data.genericName);
        if (data.comment)
            block.push("Comment=" + data.comment);
        block.push("Exec=" + data.exec);
        if (data.icon)
            block.push("Icon=" + data.icon);
        block.push("Terminal=" + (data.terminal ? "true" : "false"));
        if (data.categories)
            block.push("Categories=" + data.categories);
        if (data.keywords)
            block.push("Keywords=" + data.keywords);

        // Only the base keys are rewritten. Localized variants (Name[zh_CN] etc.)
        // and unknown keys are left untouched so translations survive a save.
        const managed = /^(Type|Name|GenericName|Comment|Exec|Icon|Terminal|Categories)$/;
        const isManaged = key => managed.test(key);

        const out = [];
        let inGroup = false;
        let inserted = false;
        const lines = original ? original.split("\n") : [];
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const trimmed = line.trim();
            if (trimmed === "[Desktop Entry]") {
                inGroup = true;
                inserted = true;
                out.push(line);
                for (let b = 0; b < block.length; b++)
                    out.push(block[b]);
                continue;
            }
            if (trimmed.startsWith("["))
                inGroup = false;
            if (inGroup && trimmed.length > 0 && !trimmed.startsWith("#")) {
                const eq = trimmed.indexOf("=");
                if (eq > 0 && isManaged(trimmed.slice(0, eq).trim()))
                    continue;
            }
            out.push(line);
        }

        if (!inserted)
            out.unshift("[Desktop Entry]", ...block, "");

        while (out.length > 0 && out[0].trim().length === 0)
            out.shift();
        return out.join("\n").replace(/\n+$/, "") + "\n";
    }

    function validate() {
        errorText = "";
        if (fieldName.trim().length === 0) {
            errorText = t("Name is required");
            nameField.forceActiveFocus();
            return false;
        }
        if (fieldExec.trim().length === 0) {
            errorText = t("Command is required");
            execField.forceActiveFocus();
            return false;
        }
        for (let i = 0; i < envVars.length; i++) {
            const name = (envVars[i].name || "").trim();
            if (name.length === 0)
                continue;
            if (!isValidEnvName(name)) {
                errorText = t("Invalid environment variable name: %1").arg(name);
                return false;
            }
        }
        return true;
    }

    function saveEntry() {
        if (!validate())
            return;
        if (editing && !editContentReady) {
            pendingSaveRequest = true;
            return;
        }

        const targetPath = editing ? editWritePath : uniquePath(desiredFileName);
        const fullExec = buildEnvExec(fieldExec.trim().replace(/[\r\n]+/g, " "), envVars);
        const data = {
            name: fieldName.trim().replace(/[\r\n]+/g, " "),
            genericName: fieldGenericName.trim().replace(/[\r\n]+/g, " "),
            comment: fieldComment.trim().replace(/[\r\n]+/g, " "),
            exec: fullExec,
            icon: resolvedIcon(fullExec, fieldIcon),
            terminal: fieldTerminal,
            categories: normalizeList(fieldCategories),
            keywords: ""
        };
        const content = buildContent(editing ? originalContent : "", data);

        pendingSavePath = targetPath;
        pendingSaveContent = content;
        writer.path = Paths.toFileUrl(targetPath);
        writer.setText(content);
    }

    function finishSave() {
        const path = pendingSavePath;
        const content = pendingSaveContent;
        if (!path)
            return;

        const preserved = editing ? findEntry(editPath) : null;
        const fullExec = buildEnvExec(fieldExec.trim(), envVars);
        const icon = resolvedIcon(fullExec, fieldIcon);
        const entry = {
            filePath: path,
            fileName: path.split("/").pop(),
            isUser: true,
            name: fieldName.trim(),
            nameRaw: fieldName.trim(),
            genericName: fieldGenericName.trim(),
            comment: fieldComment.trim(),
            exec: fullExec,
            icon: icon,
            displayIcon: icon.length > 0 ? icon : inferIconName(fullExec),
            categories: normalizeList(fieldCategories),
            terminal: fieldTerminal,
            noDisplay: preserved ? preserved.noDisplay === true : false,
            hidden: preserved ? preserved.hidden === true : false,
            content: content
        };
        upsertEntry(entry);

        const wasEditing = editing;
        pendingSavePath = "";
        pendingSaveContent = "";
        ToastService.showInfo(wasEditing ? t("Launcher updated") : t("Launcher created"), entry.fileName);
        refreshCaches();
        scanDebounce.restart();
        cancelEdit();
    }

    function deleteEntry() {
        if (!editing || editWritePath.length === 0)
            return;
        if (editingSystem) {
            ToastService.showError(t("System entries cannot be deleted"), t("Save to create a user override first"));
            return;
        }
        if (!editWritePath.startsWith(appsDir + "/"))
            return;
        if (!confirmDelete) {
            confirmDelete = true;
            confirmTimer.restart();
            return;
        }
        removeFileComponent.createObject(root, {
            targetPath: editWritePath,
            running: true
        });
    }

    function finishDelete(path, exitCode) {
        if (exitCode !== 0) {
            ToastService.showError(t("Could not delete the launcher"), path.split("/").pop());
            return;
        }
        removeEntryByPath(path);
        ToastService.showInfo(t("Launcher deleted"), path.split("/").pop());
        refreshCaches();
        scanDebounce.restart();
        cancelEdit();
    }

    // ---------------------------------------------------------------- external commands

    function scanApplications() {
        const seq = ++scanSeq;
        const script = Paths.strip(Qt.resolvedUrl("scan.py"));
        const locale = Qt.locale().name || "C";
        Proc.runCommand("appMenuEditor.scan", ["python3", "-S", script, appsDir, locale].concat(appDirectories), (stdout, exitCode) => {
            if (seq !== root.scanSeq)
                return;
            if (exitCode !== 0) {
                ToastService.showError(root.t("Could not scan applications"), "python3");
                return;
            }
            try {
                const list = JSON.parse(stdout);
                for (let i = 0; i < list.length; i++) {
                    const entry = list[i];
                    if (!entry.displayIcon)
                        entry.displayIcon = entry.icon || root.inferIconName(entry.exec);
                }
                root.knownFileNames = list.map(entry => entry.fileName);
                root.entries = list;
            } catch (error) {
                ToastService.showError(root.t("Could not scan applications"), String(error));
            }
        }, 0, 15000);
    }

    function refreshCaches() {
        cacheRefresh.running = true;
    }

    function quoteExec(path) {
        if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(path))
            return path;
        return '"' + path.replace(/(["`$\\])/g, "\\$1") + '"';
    }

    function suggestIcon(path) {
        let base = (path.split("/").pop() || "").replace(/\.(desktop|sh|py|bin|AppImage)$/i, "");
        return base.toLowerCase().replace(/[^a-z0-9._-]+/g, "");
    }

    function pickExecutable() {
        if (dialogTool.length === 0) {
            ToastService.showError(t("No file dialog available"), "kdialog / zenity");
            return;
        }
        const home = Quickshell.env("HOME") || "/";
        const command = dialogTool === "kdialog" ? ["kdialog", "--getopenfilename", home, "*|" + t("Executables")] : ["zenity", "--file-selection", "--title=" + t("Choose executable")];
        Proc.runCommand("appMenuEditor.pickExecutable", command, (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            const path = stdout.trim().split("\n")[0];
            if (!path)
                return;
            fieldExec = quoteExec(path);
            if (fieldName.trim().length === 0)
                fieldName = (path.split("/").pop() || "").replace(/\.(desktop|sh|py|bin|AppImage)$/i, "");
            if (fieldIcon.trim().length === 0)
                fieldIcon = suggestIcon(path);
            execField.forceActiveFocus();
        }, 0, 600000);
    }

    function pickIcon() {
        if (dialogTool !== "kdialog") {
            iconField.forceActiveFocus();
            return;
        }
        Proc.runCommand("appMenuEditor.pickIcon", ["kdialog", "--geticon", fieldIcon || "application-x-executable"], (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            const icon = stdout.trim().split("\n")[0];
            if (icon)
                fieldIcon = icon;
        }, 0, 600000);
    }

    function testRun() {
        if (fieldExec.trim().length === 0)
            return;
        const command = fieldExec.replace(/%[fFuUdDnNickvm]/g, " ").trim();
        if (command.length === 0)
            return;
        const args = [];
        let hasEnv = false;
        for (let i = 0; i < envVars.length; i++) {
            const name = (envVars[i].name || "").trim();
            if (!isValidEnvName(name))
                continue;
            args.push(name + "=" + (envVars[i].value || ""));
            hasEnv = true;
        }
        if (hasEnv)
            args.unshift("env");
        args.push("sh", "-c", command);
        Quickshell.execDetached(args);
        ToastService.showInfo(t("Launched"), command);
    }

    function openFolder() {
        Qt.openUrlExternally(Paths.toFileUrl(appsDir));
    }

    function requestFloatingOverlay() {
        if (embedded || autoOpenPending)
            return;
        autoOpenPending = true;
        Quickshell.execDetached(["dms", "ipc", "call", "appMenuEditor", "open"]);
        if (dashHost)
            dashHost.dashVisible = false;
        Qt.callLater(() => autoOpenPending = false);
    }

    onVisibleChanged: {
        if (visible)
            Qt.callLater(root.requestFloatingOverlay);
    }

    // ---------------------------------------------------------------- keyboard

    function handleKeyEvent(event) {
        if (event.key === Qt.Key_Escape && mode === "edit") {
            cancelEdit();
            return true;
        }
        if (mode === "edit" && event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
            saveEntry();
            return true;
        }
        return false;
    }

    function restoreFocus() {
        if (mode === "edit")
            nameField.forceActiveFocus(Qt.OtherFocusReason);
        else
            searchField.forceActiveFocus(Qt.OtherFocusReason);
    }

    menuActions: [
        {
            label: t("New launcher"),
            iconName: "add",
            action: () => root.startCreate()
        },
        {
            label: t("Open in a floating window"),
            iconName: "open_in_new",
            action: () => Quickshell.execDetached(["dms", "ipc", "call", "appMenuEditor", "open"])
        },
        {
            label: t("Refresh"),
            iconName: "refresh",
            action: () => root.scanApplications()
        },
        {
            label: t("Open launcher folder"),
            iconName: "folder_open",
            action: () => root.openFolder()
        }
    ]

    // ---------------------------------------------------------------- directory model

    Timer {
        id: scanDebounce
        interval: 250
        onTriggered: root.scanApplications()
    }

    FolderListModel {
        id: userWatcher
        folder: ""
        nameFilters: ["*.desktop"]
        showDirs: false
        showDotAndDotDot: false
        showHidden: false

        onCountChanged: scanDebounce.restart()
        onStatusChanged: {
            if (status === FolderListModel.Ready)
                scanDebounce.restart();
        }
    }

    Process {
        id: ensureDir
        command: ["mkdir", "-p", root.appsDir]
        running: true
        onExited: exitCode => {
            if (exitCode === 0) {
                userWatcher.folder = Paths.toFileUrl(root.appsDir);
                root.scanApplications();
                return;
            }
            ToastService.showError(root.t("Could not create the launcher folder"), root.appsDirShort);
        }
    }

    FileView {
        id: editReader
        path: ""
        printErrors: false

        onLoaded: {
            root.originalContent = text();
            root.editContentReady = true;
            if (root.pendingSaveRequest) {
                root.pendingSaveRequest = false;
                root.saveEntry();
            }
        }

        onLoadFailed: {
            root.originalContent = "";
            root.editContentReady = true;
            if (root.pendingSaveRequest) {
                root.pendingSaveRequest = false;
                root.saveEntry();
            }
        }
    }

    FileView {
        id: writer
        blockLoading: true
        atomicWrites: true
        printErrors: true

        onSaved: root.finishSave()

        onSaveFailed: error => {
            root.pendingSavePath = "";
            root.pendingSaveContent = "";
            ToastService.showError(root.t("Could not save the launcher"), String(error));
        }
    }

    Process {
        id: cacheRefresh
        command: ["sh", "-c", "command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database \"$1\" >/dev/null 2>&1; command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1; command -v kbuildsycoca5 >/dev/null 2>&1 && kbuildsycoca5 >/dev/null 2>&1; exit 0", "sh", root.appsDir]
    }

    Component {
        id: removeFileComponent

        Process {
            property string targetPath: ""
            command: ["rm", "-f", targetPath]
            onExited: (exitCode, exitStatus) => {
                root.finishDelete(targetPath, exitCode);
                destroy();
            }
        }
    }

    Timer {
        id: confirmTimer
        interval: 4000
        onTriggered: root.confirmDelete = false
    }

    Component.onCompleted: {
        Proc.runCommand("appMenuEditor.toolProbe", ["sh", "-c", "command -v kdialog || command -v zenity"], (stdout, exitCode) => {
            const line = stdout.trim().split("\n")[0];
            if (line.endsWith("kdialog"))
                root.dialogTool = "kdialog";
            else if (line.endsWith("zenity"))
                root.dialogTool = "zenity";
        }, 0, 3000);
        if (visible)
            Qt.callLater(root.requestFloatingOverlay);
    }

    // ---------------------------------------------------------------- list view

    Item {
        id: listView
        anchors.fill: parent
        visible: root.mode === "list"

        Row {
            id: listHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.headerHeight
            spacing: Theme.spacingM

            Column {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.embedded
                width: parent.width - newButton.width - folderButton.width - refreshButton.width - floatButton.width - Theme.spacingM * 4
                spacing: 2

                StyledText {
                    text: root.t("App Menu Editor")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    width: parent.width
                }

                StyledText {
                    text: root.t("Browse and edit launchers from user and system app directories")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            DActionButton {
                id: floatButton
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.embedded
                iconName: "open_in_new"
                tooltipText: root.t("Open in a floating window")
                onClicked: Quickshell.execDetached(["dms", "ipc", "call", "appMenuEditor", "open"])
            }

            DActionButton {
                id: refreshButton
                anchors.verticalCenter: parent.verticalCenter
                iconName: "refresh"
                tooltipText: root.t("Refresh")
                onClicked: root.scanApplications()
            }

            DActionButton {
                id: folderButton
                anchors.verticalCenter: parent.verticalCenter
                iconName: "folder_open"
                tooltipText: root.t("Open launcher folder")
                onClicked: root.openFolder()
            }

            DButton {
                id: newButton
                anchors.verticalCenter: parent.verticalCenter
                text: root.t("New")
                iconName: "add"
                onClicked: root.startCreate()
            }
        }

        DTextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: listHeader.bottom
            anchors.topMargin: Theme.spacingM
            placeholderText: root.t("Search entries")
            leftIconName: "search"
            showClearButton: true
            text: root.searchText
            onTextChanged: root.searchText = text
        }

        DCard {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: searchField.bottom
            anchors.topMargin: Theme.spacingM
            anchors.bottom: hintRow.top
            anchors.bottomMargin: Theme.spacingS
            pad: 0
            clipContent: true
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
            border.width: 0

            ListView {
                id: entryList
                anchors.fill: parent
                clip: true
                model: root.filteredEntries
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: root.listRowHeight * 2

                delegate: Rectangle {
                    id: entryRow

                    required property var modelData

                    readonly property bool hovered: rowMouse.containsMouse
                    readonly property string entryIcon: entryRow.modelData.displayIcon || entryRow.modelData.icon || ""
                    readonly property bool entryIconReady: entryIcon.length > 0 && Paths.resolveIconPath(entryIcon).length > 0

                    width: entryList.width
                    height: root.listRowHeight
                    radius: Theme.cornerRadius
                    color: hovered ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingM

                        AppIconRenderer {
                            anchors.verticalCenter: parent.verticalCenter
                            width: root.listIconSize
                            height: root.listIconSize
                            iconValue: entryRow.entryIcon || "application-x-executable"
                            iconSize: root.listIconSize
                            fallbackText: entryRow.entryIconReady ? "" : (entryRow.modelData.name || "?").charAt(0).toUpperCase()
                            fallbackBackgroundColor: entryRow.entryIconReady ? "transparent" : Theme.surfaceLight
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - root.listIconSize - badgeRow.width - chevron.width - Theme.spacingM * 3
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: entryRow.modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: entryRow.modelData.comment || entryRow.modelData.exec || entryRow.modelData.fileName
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }

                        Row {
                            id: badgeRow
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS

                            StyledRect {
                                visible: entryRow.modelData.hidden === true
                                width: hiddenBadge.implicitWidth + Theme.spacingS * 2
                                height: root.badgeHeight
                                radius: Theme.cornerRadiusFull
                                color: Theme.withAlpha(Theme.error, 0.15)

                                StyledText {
                                    id: hiddenBadge
                                    anchors.centerIn: parent
                                    text: root.t("Hidden")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.error
                                }
                            }

                            StyledRect {
                                visible: entryRow.modelData.noDisplay === true
                                width: noDisplayBadge.implicitWidth + Theme.spacingS * 2
                                height: root.badgeHeight
                                radius: Theme.cornerRadiusFull
                                color: Theme.withAlpha(Theme.surfaceVariantText, 0.15)

                                StyledText {
                                    id: noDisplayBadge
                                    anchors.centerIn: parent
                                    text: "NoDisplay"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            StyledRect {
                                visible: entryRow.modelData.terminal === true
                                width: terminalBadge.implicitWidth + Theme.spacingS * 2
                                height: root.badgeHeight
                                radius: Theme.cornerRadiusFull
                                color: Theme.withAlpha(Theme.primary, 0.12)

                                StyledText {
                                    id: terminalBadge
                                    anchors.centerIn: parent
                                    text: root.t("Terminal")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.primary
                                }
                            }

                            StyledRect {
                                visible: entryRow.modelData.isUser === false
                                width: systemBadge.implicitWidth + Theme.spacingS * 2
                                height: root.badgeHeight
                                radius: Theme.cornerRadiusFull
                                color: Theme.withAlpha(Theme.secondary, 0.15)

                                StyledText {
                                    id: systemBadge
                                    anchors.centerIn: parent
                                    text: root.t("System")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.secondary
                                }
                            }
                        }

                        DIcon {
                            id: chevron
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron_right"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.startEdit(entryRow.modelData)
                    }
                }
            }

            Item {
                anchors.fill: parent
                visible: root.filteredEntries.length === 0

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    DIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "apps"
                        size: Theme.iconSizeLarge
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.searchText.length > 0 ? root.t("No matching entries") : root.t("No launchers yet")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: root.searchText.length === 0
                        text: root.t("Use New to create one")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }

        Row {
            id: hintRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Theme.iconSize
            spacing: Theme.spacingXS

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "folder"
                size: Theme.iconSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.iconSizeSmall - Theme.spacingXS * 2 - countText.implicitWidth
                text: root.appsDirShort
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideMiddle
            }

            StyledText {
                id: countText
                anchors.verticalCenter: parent.verticalCenter
                text: root.filteredEntries.length + " / " + root.entries.length
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    // ---------------------------------------------------------------- editor view

    Item {
        id: editView
        anchors.fill: parent
        visible: root.mode === "edit"

        Row {
            id: editHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.headerHeight
            spacing: Theme.spacingS

            DActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "arrow_back"
                tooltipText: root.t("Back")
                onClicked: root.cancelEdit()
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 40 - Theme.spacingS
                spacing: 2

                StyledText {
                    width: parent.width
                    text: root.editing ? root.t("Edit launcher") : root.t("New launcher")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: root.editing ? root.editPath : root.desiredPath
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideMiddle
                }
            }
        }

        DFlickable {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: editHeader.bottom
            anchors.topMargin: Theme.spacingM
            anchors.bottom: editFooter.top
            anchors.bottomMargin: Theme.spacingS
            clip: true
            contentWidth: width
            contentHeight: form.implicitHeight

            Column {
                id: form
                width: parent.width
                spacing: Theme.spacingM

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    AppIconRenderer {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.editorIconSize
                        height: root.editorIconSize
                        iconValue: root.formIcon || "application-x-executable"
                        iconSize: Theme.iconButtonSize
                        fallbackText: root.formIconReady ? "" : (root.fieldName || "?").charAt(0).toUpperCase()
                        fallbackBackgroundColor: root.formIconReady ? "transparent" : Theme.surfaceLight
                    }

                    DTextField {
                        id: nameField
                        outlined: true
                        width: parent.width - root.editorIconSize - Theme.spacingM
                        labelText: root.t("Name")
                        placeholderText: root.t("e.g. My App")
                        text: root.fieldName
                        showClearButton: true
                        onTextChanged: root.fieldName = text
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DTextField {
                        id: execField
                        outlined: true
                        width: parent.width - browseButton.width - Theme.spacingS
                        labelText: root.t("Command")
                        placeholderText: root.t("e.g. /opt/myapp/myapp --flag")
                        supportingText: root.t("The command that starts the app")
                        text: root.fieldExec
                        showClearButton: true
                        onTextChanged: root.fieldExec = text
                    }

                    DButton {
                        id: browseButton
                        text: root.t("Browse")
                        iconName: "folder_open"
                        anchors.bottom: execField.bottom
                        anchors.bottomMargin: execField.supportingHeight
                        onClicked: root.pickExecutable()
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - addEnvButton.width - Theme.spacingS
                            text: root.t("Environment variables")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        DButton {
                            id: addEnvButton
                            text: root.t("Add")
                            iconName: "add"
                            onClicked: root.addEnvVar()
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: root.envVars.length > 0

                        StyledText {
                            width: (parent.width - Theme.iconButtonSize - Theme.spacingS * 2) * 0.38
                            text: root.t("Variable name")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width - (parent.width - Theme.iconButtonSize - Theme.spacingS * 2) * 0.38 - Theme.iconButtonSize - Theme.spacingS * 2
                            text: root.t("Value")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }

                        Item {
                            width: Theme.iconButtonSize
                            height: 1
                        }
                    }

                    Repeater {
                        model: root.envVars

                        delegate: Row {
                            required property var modelData
                            required property int index

                            width: form.width
                            spacing: Theme.spacingS

                            DTextField {
                                id: envNameField
                                outlined: true
                                width: (parent.width - removeEnvButton.width - Theme.spacingS * 2) * 0.38
                                placeholderText: "KEY"
                                text: modelData.name
                                onTextChanged: {
                                    if (root.envVars[index])
                                        root.envVars[index].name = text;
                                }
                            }

                            DTextField {
                                id: envValueField
                                outlined: true
                                width: parent.width - envNameField.width - removeEnvButton.width - Theme.spacingS * 2
                                placeholderText: "VALUE"
                                text: modelData.value
                                onTextChanged: {
                                    if (root.envVars[index])
                                        root.envVars[index].value = text;
                                }
                            }

                            DActionButton {
                                id: removeEnvButton
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "delete"
                                tooltipText: root.t("Remove")
                                onClicked: root.removeEnvVar(index)
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: root.envVars.length === 0
                        text: root.t("Optional; one row per variable, e.g. http_proxy = http://127.0.0.1:7890")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DTextField {
                        id: iconField
                        outlined: true
                        width: parent.width - iconButton.width - Theme.spacingS
                        labelText: root.t("Icon")
                        placeholderText: root.inferIconName(root.fieldExec) || root.t("Icon name or path")
                        supportingText: {
                            const guess = root.inferIconName(root.fieldExec);
                            if (root.fieldIcon.trim().length === 0 && guess.length > 0)
                                return root.t("Auto-detected: %1").arg(guess);
                            return root.t("Icon theme name, e.g. firefox");
                        }
                        text: root.fieldIcon
                        showClearButton: true
                        onTextChanged: root.fieldIcon = text
                    }

                    DButton {
                        id: iconButton
                        text: root.t("Pick")
                        iconName: "palette"
                        anchors.bottom: iconField.bottom
                        anchors.bottomMargin: iconField.supportingHeight
                        onClicked: root.pickIcon()
                    }
                }

                DTextField {
                    id: commentField
                    outlined: true
                    width: parent.width
                    labelText: root.t("Comment")
                    placeholderText: root.t("Optional description")
                    text: root.fieldComment
                    onTextChanged: root.fieldComment = text
                }

                DTextField {
                    id: categoriesField
                    outlined: true
                    width: parent.width
                    labelText: root.t("Categories")
                    placeholderText: "Utility;Development;"
                    supportingText: root.t("Separated by semicolons")
                    text: root.fieldCategories
                    onTextChanged: root.fieldCategories = text
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DToggle {
                        id: terminalToggle
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.t("Run in terminal")
                        checked: root.fieldTerminal
                        onToggled: checked => root.fieldTerminal = checked
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.editingSystem
                    text: root.t("This is a system entry. Saving creates an override in your user applications folder.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.primary
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    visible: root.editing
                    text: root.t("Unknown keys and Desktop Actions are preserved when saving.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }

        Column {
            id: editFooter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                visible: root.errorText.length > 0
                text: root.errorText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
                wrapMode: Text.WordWrap
            }

            Item {
                width: parent.width
                height: root.headerHeight

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    DButton {
                        text: root.t("Test")
                        iconName: "play_arrow"
                        enabled: root.fieldExec.trim().length > 0
                        onClicked: root.testRun()
                    }

                    DButton {
                        text: root.editing ? (root.confirmDelete ? root.t("Confirm delete") : root.t("Delete")) : root.t("Cancel")
                        iconName: root.editing ? "delete" : "close"
                        enabled: !root.editingSystem
                        tooltipText: root.editingSystem ? root.t("System entries cannot be deleted; save to create a user override first") : ""
                        backgroundColor: root.editing ? Theme.withAlpha(Theme.error, 0.15) : Theme.secondaryContainer
                        textColor: root.editing ? Theme.error : Theme.onSecondaryContainer
                        onClicked: root.editing ? root.deleteEntry() : root.cancelEdit()
                    }

                    DButton {
                        text: root.t("Save")
                        iconName: "save"
                        backgroundColor: Theme.primary
                        textColor: Theme.onPrimary
                        onClicked: root.saveEntry()
                    }
                }
            }
        }
    }
}
