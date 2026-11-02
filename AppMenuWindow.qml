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
    readonly property real defaultCardWidth: Math.max(320, Math.min(920, screenWidth - Theme.spacingXL * 2))
    readonly property real defaultCardHeight: Math.max(360, Math.min(760, screenHeight - Theme.spacingXL * 2))
    readonly property real minCardWidth: Math.min(520, Math.max(320, screenWidth - Theme.spacingS * 2))
    readonly property real minCardHeight: Math.min(420, Math.max(320, screenHeight - Theme.spacingS * 2))
    readonly property real contentScale: 0.9

    property real cardW: 0
    property real cardH: 0
    property string resizeMode: ""
    property real resizeStartW: 0
    property real resizeStartH: 0
    property real resizeStartX: 0
    property real resizeStartY: 0
    property real resizeStartSceneX: 0
    property real resizeStartSceneY: 0

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

    WindowBlur {
        targetWindow: root
        blurEnabled: root.visible
        blurX: card.x
        blurY: card.y
        blurWidth: card.width
        blurHeight: card.height
        blurRadius: card.radius
        clipEnabled: true
        clipX: card.x
        clipY: card.y
        clipWidth: card.width
        clipHeight: card.height
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
        const maxW = Math.max(minCardWidth, screenWidth - Theme.spacingS * 2);
        const maxH = Math.max(minCardHeight, screenHeight - Theme.spacingS * 2);
        cardW = Math.max(minCardWidth, Math.min(cardW > 0 ? cardW : defaultCardWidth, maxW));
        cardH = Math.max(minCardHeight, Math.min(cardH > 0 ? cardH : defaultCardHeight, maxH));
        card.x = Math.max(Theme.spacingS, (screenWidth - card.width) / 2 - 80);
        card.y = Math.max(Theme.spacingS, (screenHeight - card.height) / 2 - 60);
        positioned = true;
    }

    function clampCard() {
        if (!positioned || screenWidth <= 0 || screenHeight <= 0)
            return;
        const maxW = Math.max(minCardWidth, screenWidth - Theme.spacingS * 2);
        const maxH = Math.max(minCardHeight, screenHeight - Theme.spacingS * 2);
        cardW = Math.max(minCardWidth, Math.min(cardW, maxW));
        cardH = Math.max(minCardHeight, Math.min(cardH, maxH));
        card.x = Math.max(Theme.spacingS, Math.min(card.x, screenWidth - card.width - Theme.spacingS));
        card.y = Math.max(Theme.spacingS, Math.min(card.y, screenHeight - card.height - Theme.spacingS));
    }

    function beginResize(mode, sceneX, sceneY) {
        resizeMode = mode;
        resizeStartW = card.width;
        resizeStartH = card.height;
        resizeStartX = card.x;
        resizeStartY = card.y;
        resizeStartSceneX = sceneX;
        resizeStartSceneY = sceneY;
        userMoved = true;
    }

    function endResize() {
        resizeMode = "";
    }

    function updateResize(sceneX, sceneY) {
        if (resizeMode.length === 0)
            return;
        const dx = sceneX - resizeStartSceneX;
        const dy = sceneY - resizeStartSceneY;
        const minW = Math.min(minCardWidth, screenWidth - Theme.spacingS * 2);
        const minH = Math.min(minCardHeight, screenHeight - Theme.spacingS * 2);
        let x = resizeStartX;
        let y = resizeStartY;
        let w = resizeStartW;
        let h = resizeStartH;

        if (resizeMode.indexOf("left") >= 0) {
            x = Math.max(Theme.spacingS, Math.min(resizeStartX + dx, resizeStartX + resizeStartW - minW));
            w = resizeStartW + (resizeStartX - x);
        }
        if (resizeMode.indexOf("right") >= 0)
            w = Math.max(minW, Math.min(resizeStartW + dx, screenWidth - resizeStartX - Theme.spacingS));
        if (resizeMode.indexOf("top") >= 0) {
            y = Math.max(Theme.spacingS, Math.min(resizeStartY + dy, resizeStartY + resizeStartH - minH));
            h = resizeStartH + (resizeStartY - y);
        }
        if (resizeMode.indexOf("bottom") >= 0)
            h = Math.max(minH, Math.min(resizeStartH + dy, screenHeight - resizeStartY - Theme.spacingS));

        cardW = w;
        cardH = h;
        card.x = x;
        card.y = y;
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
        width: root.cardW
        height: root.cardH
        radius: Theme.cornerRadiusL
        color: Theme.floatingWindowSurface
        border.width: Theme.layerOutlineWidth
        border.color: Theme.outlineMedium
        clip: true

        Item {
            id: header

            width: parent.width
            height: Theme.iconButtonSize

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - closeButton.width * 2 - Theme.spacingM * 2)
                text: I18n.trFor(root.pluginId, "App Menu Editor")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
                horizontalAlignment: Text.AlignHCenter
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
        }

        Item {
            id: canvas

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.spacingM
            clip: true

            Item {
                id: scaledCanvas

                width: parent.width / root.contentScale
                height: parent.height / root.contentScale
                anchors.centerIn: parent
                scale: root.contentScale
                transformOrigin: Item.Center

                Loader {
                    id: tabLoader

                    anchors.fill: parent
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
        }
    }

    component ResizeHandle: MouseArea {
        id: handle

        required property string mode
        property int resizeCursor: Qt.ArrowCursor

        visible: root.visible && root.cardW > 0 && root.cardH > 0
        z: 20
        cursorShape: resizeCursor
        hoverEnabled: true
        preventStealing: true

        onPressed: {
            const point = mapToItem(null, mouse.x, mouse.y);
            root.beginResize(mode, point.x, point.y);
            mouse.accepted = true;
        }
        onPositionChanged: {
            if (!pressed)
                return;
            const point = mapToItem(null, mouse.x, mouse.y);
            root.updateResize(point.x, point.y);
        }
        onReleased: root.endResize()
        onCanceled: root.endResize()
    }

    ResizeHandle {
        mode: "left"
        resizeCursor: Qt.SizeHorCursor
        x: card.x
        y: card.y + Theme.spacingM
        width: Theme.spacingS
        height: Math.max(0, card.height - Theme.spacingM * 2)
    }

    ResizeHandle {
        mode: "right"
        resizeCursor: Qt.SizeHorCursor
        x: card.x + card.width - Theme.spacingS
        y: card.y + Theme.spacingM
        width: Theme.spacingS
        height: Math.max(0, card.height - Theme.spacingM * 2)
    }

    ResizeHandle {
        mode: "top"
        resizeCursor: Qt.SizeVerCursor
        x: card.x + Theme.spacingM
        y: card.y
        width: Math.max(0, card.width - Theme.spacingM * 2)
        height: Theme.spacingS
    }

    ResizeHandle {
        mode: "bottom"
        resizeCursor: Qt.SizeVerCursor
        x: card.x + Theme.spacingM
        y: card.y + card.height - Theme.spacingS
        width: Math.max(0, card.width - Theme.spacingM * 2)
        height: Theme.spacingS
    }

    ResizeHandle {
        mode: "top-left"
        resizeCursor: Qt.SizeFDiagCursor
        x: card.x
        y: card.y
        width: Theme.spacingM
        height: Theme.spacingM
    }

    ResizeHandle {
        mode: "top-right"
        resizeCursor: Qt.SizeBDiagCursor
        x: card.x + card.width - Theme.spacingM
        y: card.y
        width: Theme.spacingM
        height: Theme.spacingM
    }

    ResizeHandle {
        mode: "bottom-left"
        resizeCursor: Qt.SizeBDiagCursor
        x: card.x
        y: card.y + card.height - Theme.spacingM
        width: Theme.spacingM
        height: Theme.spacingM
    }

    ResizeHandle {
        mode: "bottom-right"
        resizeCursor: Qt.SizeFDiagCursor
        x: card.x + card.width - Theme.spacingM
        y: card.y + card.height - Theme.spacingM
        width: Theme.spacingM
        height: Theme.spacingM
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
