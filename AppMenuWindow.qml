pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets

PanelWindow {
    id: root

    property string pluginId: "appMenuEditor"
    property var pluginService: null
    readonly property string entryId: "plugin_" + pluginId

    property var targetScreen: null
    property bool positioned: false
    property bool userMoved: false
    property string lastScreenName: ""

    readonly property real screenWidth: screen?.width ?? width
    readonly property real screenHeight: screen?.height ?? height
    readonly property real cardWidth: Math.max(320, Math.min(920, screenWidth - Theme.spacingXL * 2))
    readonly property real cardHeight: Math.max(360, Math.min(760, screenHeight - Theme.spacingXL * 2))

    objectName: "appMenuEditorOverlay"
    screen: targetScreen
    visible: false
    color: "transparent"

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    WlrLayershell.namespace: "dms:appMenuEditor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    mask: Region {
        item: card
    }

    onWidthChanged: {
        if (userMoved)
            clampCard();
        else
            centerCard();
    }
    onHeightChanged: {
        if (userMoved)
            clampCard();
        else
            centerCard();
    }
    onScreenChanged: {
        if (userMoved)
            clampCard();
        else
            centerCard();
    }
    onClosed: visible = false

    function centerCard() {
        if (screenWidth <= 0 || screenHeight <= 0)
            return;
        card.x = Math.max(Theme.spacingS, (screenWidth - card.width) / 2);
        card.y = Math.max(Theme.spacingS, (screenHeight - card.height) / 2);
        positioned = true;
    }

    function clampCard() {
        if (!positioned || screenWidth <= 0 || screenHeight <= 0)
            return;
        card.x = Math.max(Theme.spacingS, Math.min(card.x, screenWidth - card.width - Theme.spacingS));
        card.y = Math.max(Theme.spacingS, Math.min(card.y, screenHeight - card.height - Theme.spacingS));
    }

    function show() {
        const focused = CompositorService.getFocusedScreen();
        const screenName = focused?.name ?? "";
        if (screenName !== lastScreenName)
            userMoved = false;
        targetScreen = focused;
        visible = true;
        if (tabLoader.item && tabLoader.item.mode === "list")
            tabLoader.item.searchText = "";
        Qt.callLater(() => {
            if (!positioned || screenName !== lastScreenName) {
                centerCard();
                lastScreenName = screenName;
            } else {
                clampCard();
            }
            tabLoader.item?.focusTarget?.forceActiveFocus(Qt.OtherFocusReason);
        });
    }

    function hide() {
        visible = false;
    }

    function toggle() {
        if (visible)
            hide();
        else
            show();
    }

    Rectangle {
        id: card

        x: Theme.spacingS
        y: Theme.spacingS
        width: root.cardWidth
        height: root.cardHeight
        radius: Theme.cornerRadiusL
        color: Theme.surfaceContainerHigh
        border.width: Theme.layerOutlineWidth
        border.color: Theme.outlineMedium
        clip: true

        Item {
            id: header

            width: parent.width
            height: Theme.iconButtonSize

            StyledText {
                anchors.left: parent.left
                anchors.right: closeButton.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingS
                text: I18n.trFor(root.pluginId, "App Menu Editor")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: closeButton.width + Theme.spacingS
                drag.target: card
                drag.axis: Drag.XAndYAxis
                drag.minimumX: Theme.spacingS
                drag.maximumX: root.screenWidth - card.width - Theme.spacingS
                drag.minimumY: Theme.spacingS
                drag.maximumY: root.screenHeight - card.height - Theme.spacingS
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed: root.userMoved = true
            }

            DActionButton {
                id: closeButton
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                iconName: "close"
                tooltipText: I18n.trFor(root.pluginId, "Close")
                onClicked: root.hide()
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Theme.outlineVariant
            }
        }

        Loader {
            id: tabLoader

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            source: "AppMenuTab.qml"
            asynchronous: false

            onLoaded: {
                item.embedded = true;
                item.entryId = root.entryId;
                item.pluginId = root.pluginId;
                item.pluginService = root.pluginService;
                Qt.callLater(() => item.focusTarget?.forceActiveFocus(Qt.OtherFocusReason));
            }
        }
    }

    IpcHandler {
        target: "appMenuEditor"

        function open(): string {
            root.show();
            return "OPEN";
        }

        function close(): string {
            root.hide();
            return "CLOSED";
        }

        function toggle(): string {
            root.toggle();
            return root.visible ? "OPEN" : "CLOSED";
        }

        function status(): string {
            return root.visible ? "OPEN" : "CLOSED";
        }
    }
}
