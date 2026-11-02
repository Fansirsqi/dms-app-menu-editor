import QtQuick
import Quickshell
import qs.Common

QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "appMenuEditor"
    property string trigger: "!app"

    signal itemsChanged

    function getItems(query) {
        const needle = (query || "").trim().toLowerCase();
        const item = {
            name: I18n.trFor("appMenuEditor", "App Menu Editor"),
            icon: "svg:" + Qt.resolvedUrl("icon.svg"),
            comment: I18n.trFor("appMenuEditor", "Open the floating App Menu Editor"),
            action: "open",
            categories: [I18n.trFor("appMenuEditor", "App Menu Editor")]
        };
        if (needle.length === 0)
            return [item];
        const haystack = [item.name, item.comment, "desktop launcher menu 菜单 启动项 快捷方式"].join(" ").toLowerCase();
        return haystack.indexOf(needle) >= 0 ? [item] : [];
    }

    function openOverlay() {
        const daemon = pluginService?.pluginDaemonInstances?.[pluginId];
        if (daemon && typeof daemon.show === "function") {
            daemon.show();
            return;
        }
        Quickshell.execDetached(["dms", "ipc", "call", "appMenuEditor", "open"]);
    }

    function executeItem(item) {
        if (!item || item.action !== "open")
            return;
        openOverlay();
    }
}
