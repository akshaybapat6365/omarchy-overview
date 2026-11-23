import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "Layout.js" as L

// One desk in the strip: a miniature of the whole desk (its wallpaper and its
// windows where they really are) with a bold number pill top-left and its
// name below; or, as the last tile, "+" for a new desk.
//
// Pointer: tap views the desk, double-tap goes there; press and slide
// sideways carries the desk to a new place; press on a window in the
// miniature and pull it down carries that window. Every state of SPEC 2.3
// is drawn here: hover, press, active, viewed, aimed, drop target (with the
// landing preview and "+1"), hover-hold (the ring fills clockwise), lifted.
Item {
    id: tile
    required property var bar
    required property string key
    readonly property var scene: bar.scene
    readonly property real u: scene.u
    readonly property bool isPlus: key === "plus"
    readonly property int deskId: isPlus ? bar.plusId : Number(key)
    readonly property var desk: isPlus ? ({ id: deskId, name: "New desk", waiting: 0, count: 0 })
                                       : (bar.deskById[deskId] || ({ id: deskId, name: "", waiting: 0, count: 0 }))
    readonly property var drag: bar.drag
    readonly property bool dragging: drag !== null && drag.kind !== ""
    readonly property bool lifted: !isPlus && drag !== null && drag.kind === "desk" && drag.itemId === deskId
    readonly property bool carryingWindow: drag !== null && (drag.kind === "window" || (drag.commit !== null && drag.landing !== null))
    readonly property var tgt: bar.dropState || ({})
    readonly property bool dropTarget: isPlus ? tgt.type === "plus"
                                              : ((tgt.type === "desk" || tgt.type === "grid") && tgt.id === deskId)
    readonly property bool aimed: drag !== null && drag.keyboard && drag.aimId === deskId
    readonly property bool active: !isPlus && deskId === bar.activeDesk
    readonly property bool viewed: deskId === bar.viewedDesk && !active && !scene.query
    readonly property real hold: drag !== null && drag.holdId === deskId ? drag.holdProgress : 0
    readonly property bool hot: hover.hovered && !dragging
    readonly property bool pressedNow: tap.pressed && !dragging
    readonly property real k: width / Math.max(1, scene.width)
    readonly property string number: isPlus ? "" : String(bar.labels[deskId] !== undefined ? bar.labels[deskId] : deskId)
    // An empty desk (the bar dims its number): the wallpaper miniature put back the way the theme quiets things
    // (darkened toward the ground on a dark theme, a wash of the accent on a light one, never plain transparency,
    // which over a dark ground still reads at full colour) and one bold filled "Empty" pill in its middle, so it
    // reads as empty at a glance and never as "New desk" (glass, dashed edge, a drawn plus). It wakes to full
    // strength where he is, under the pointer, where a window is about to land and while he carries it. No window
    // plates, no capture, no timer: nothing runs for it.
    readonly property bool empty: !isPlus && !(desk.count > 0)
    readonly property bool quiet: empty && !active && !dropTarget && !lifted && !hot

    function picturesPending() {
        for (var i = 0; i < miniRep.count; i++) { var m = miniRep.itemAt(i); if (m && m.picturePending) return true; }
        return false;
    }
    function miniItem(wid) {
        for (var i = 0; i < miniRep.count; i++) { var m = miniRep.itemAt(i); if (m && m.wid === wid && m.here) return m; }
        return null;
    }
    function miniAt(p) {          // the topmost window of the miniature under p (face coordinates)
        for (var i = miniRep.count - 1; i >= 0; i--) {
            var m = miniRep.itemAt(i);
            if (m && m.here && p.x >= m.x && p.x <= m.x + m.width && p.y >= m.y && p.y <= m.y + m.height) return m.wid;
        }
        return "";
    }

    // ---- place: the slot, plus an offset that springs back to zero -----------
    width: bar.tileW
    height: bar.tileH
    Behavior on width { enabled: tile.scene.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: tile.scene.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    readonly property real slotX: bar.slotX(key)
    property real lastSlotX: NaN
    property real fx: 0
    property real fy: 0
    property real fs: 1
    onSlotXChanged: {
        if (!isNaN(lastSlotX) && !bar.manual && !lifted && scene.settled) { fx += lastSlotX - slotX; travel.restart(); }
        lastSlotX = slotX;
    }
    ParallelAnimation {
        id: travel
        NumberAnimation { target: tile; property: "fx"; to: 0; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { target: tile; property: "fy"; to: 0; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { target: tile; property: "fs"; to: 1; duration: 200; easing.type: Easing.OutCubic }
    }
    property real liftedX: 0
    property real liftedY: 0
    onLiftedChanged: {
        if (lifted) { travel.stop(); fx = 0; fy = 0; fs = 1; return; }
        // let go: glide from where the hand left it into the slot
        fx = liftedX - slotX; fy = liftedY; fs = 1.08;
        travel.restart();
    }
    x: lifted ? liftedX : slotX + fx
    y: bar.stripY + (lifted ? liftedY : fy)
    Binding { target: tile; property: "liftedX"; value: tile.bar.liftX; when: tile.lifted }
    Binding { target: tile; property: "liftedY"; value: tile.bar.liftY; when: tile.lifted }
    function pose() { return { x: x, y: y - bar.stripY, s: fs * (lifted ? 1.08 : 1) }; }
    function arrive() {
        var p = bar.flipFrom[key];
        lastSlotX = slotX;
        if (key === bar.popKey) { pop.restart(); return; }
        if (!p) return;
        fx = p.x - slotX; fy = p.y; fs = p.s;
        travel.restart();
    }
    // A desk that appears while the overview is open grows in from 0.85.
    property real popScale: 1
    property real popOpacity: 1
    ParallelAnimation {
        id: pop
        NumberAnimation { target: tile; property: "popScale"; from: 0.85; to: 1; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { target: tile; property: "popOpacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
    }
    Component.onCompleted: {
        lastSlotX = slotX;
        if (scene.settled) { if (bar.flipFrom[key] && key !== bar.popKey) arrive(); else pop.restart(); }
    }

    z: lifted ? 100 : (dropTarget || aimed ? 10 : (hot ? 5 : 1))
    // While a desk is carried "+" is no target, so it steps back (40 %) and never reads as "drop here".
    readonly property bool deskCarried: drag !== null && drag.kind === "desk"
    opacity: (lifted ? drag.liftOpacity : (isPlus && deskCarried ? 0.4 : 1)) * popOpacity
    Behavior on opacity { enabled: tile.lifted || tile.isPlus; NumberAnimation { duration: 140 } }
    property real stateScale: lifted ? 1.08 : dropTarget ? 1.06 : pressedNow ? 0.97 : hot ? 1.04 : 1
    Behavior on stateScale { NumberAnimation { duration: tile.pressedNow ? 80 : 140; easing.type: Easing.OutCubic } }
    scale: stateScale * fs * popScale

    // ---- shadow and glow ---------------------------------------------------------
    RectangularShadow {
        anchors.fill: face
        radius: face.radius
        blur: (tile.lifted ? 46 : 26) * tile.u
        offset: Qt.vector2d(0, (tile.lifted ? 24 : 10) * tile.u)
        color: tile.scene.shadowColor
        opacity: tile.isPlus ? 0.35 : (tile.lifted ? 1 : 0.9)
    }
    RectangularShadow {
        anchors.fill: face
        radius: face.radius
        blur: 24 * tile.u
        spread: 2 * tile.u
        color: tile.bar.accentGlow
        opacity: tile.dropTarget || tile.lifted ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }

    // ---- the face ------------------------------------------------------------------
    Item {
        id: face
        property real radius: 14 * tile.u
        width: tile.width
        height: tile.height
        layer.enabled: true
        layer.smooth: true
        layer.effect: ShaderEffect {
            property vector2d size: Qt.vector2d(face.width, face.height)
            property real radius: face.radius
            fragmentShader: Qt.resolvedUrl("shaders/rounded.frag.qsb")
        }

        Rectangle { anchors.fill: parent; color: tile.scene.surfaceColor }
        Image {
            anchors.fill: parent
            source: tile.scene.wallpaper
            sourceSize.width: 560
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            opacity: tile.isPlus ? 0.28 : 1
        }
        // The empty desk's quieting: the theme's ground over the wallpaper, and on a light theme the accent on top.
        Item {
            objectName: "emptyScrim"
            anchors.fill: parent
            visible: opacity > 0.01
            opacity: tile.quiet ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(tile.scene.background.r, tile.scene.background.g, tile.scene.background.b, tile.scene.lightMode ? 0.5 : 0.72)
            }
            Rectangle {
                anchors.fill: parent
                visible: tile.scene.lightMode
                color: Qt.rgba(tile.scene.accent.r, tile.scene.accent.g, tile.scene.accent.b, 0.2)
            }
        }

        // The desk's windows: each shows the one picture of that window (its own
        // capture only when the window's card is not capturing it).
        Item {
            anchors.fill: parent
            opacity: tile.dropTarget && tile.carryingWindow ? 0.6 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Repeater {
                id: miniRep
                model: tile.isPlus || tile.empty ? null : tile.scene.winModel
                delegate: Item {
                    id: mini
                    required property string wid
                    readonly property var win: tile.scene.byId[wid] || null
                    readonly property bool here: win !== null && win.desk === tile.deskId
                    readonly property bool cardCapturing: here && tile.bar.cardCapturing(wid)
                    // A miniature keeps a picture it already has until the card's own arrives (no blink when paging).
                    property bool kept: false
                    readonly property bool owns: here && tile.scene.capturing && (!cardCapturing || (kept && !tile.bar.cardReady(wid)))
                    readonly property bool carried: tile.drag !== null && tile.drag.kind === "window" && tile.drag.itemId === wid
                    visible: here
                    x: here ? win.x * tile.k : 0
                    y: here ? win.y * tile.k : 0
                    width: here ? win.w * tile.k : 0
                    height: here ? win.h * tile.k : 0
                    opacity: carried ? 0.35 : 1
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    Rectangle { anchors.fill: parent; color: tile.scene.surfaceColor; radius: 2 * tile.u }
                    readonly property bool picturePending: miniLoader.item ? miniLoader.item.pending === true : false
                    onPicturePendingChanged: if (!picturePending) tile.scene.pictureArrived()
                    Loader {
                        id: miniLoader
                        anchors.fill: parent
                        active: mini.owns
                        sourceComponent: tile.scene.thumbnail
                        onLoaded: {
                            item.winId = Qt.binding(function () { return mini.wid; });
                            item.capturing = Qt.binding(function () { return tile.scene.capturing; });
                        }
                        onItemChanged: {
                            tile.bar.setCapture(mini.wid, "mini", item);
                            if (!item) Qt.callLater(function () { if (mini) mini.kept = false; });   // the miniature may be gone (its desk emptied)
                        }
                    }
                    Connections {
                        target: miniLoader.item
                        ignoreUnknownSignals: true
                        function onReadyChanged() { mini.kept = miniLoader.item !== null && miniLoader.item.ready === true; }
                    }
                    ShaderEffectSource {
                        anchors.fill: parent
                        visible: !mini.owns && sourceItem !== null
                        sourceItem: mini.here && !mini.owns ? tile.bar.pictureOf(mini.wid) : null
                        hideSource: false
                        smooth: true
                        mipmap: true
                    }
                    Component.onDestruction: tile.bar.setCapture(wid, "mini", null)
                    Rectangle { anchors.fill: parent; color: "transparent"; border.width: Math.max(1, tile.u); border.color: Qt.rgba(0, 0, 0, 0.35); radius: 2 * tile.u }
                }
            }
        }

        // Where the carried window will appear: its own picture at 70 %, exactly
        // where it floats, or the right half for a tiled window.
        Item {
            id: preview
            readonly property string wid: tile.drag && tile.drag.kind === "window" ? String(tile.drag.itemId)
                                          : (tile.drag && tile.drag.landing ? tile.drag.landing.wid : "")
            readonly property var spot: wid ? L.landingSpot(tile.scene.byId[wid], tile.scene.width, tile.scene.height) : null
            visible: opacity > 0.01
            opacity: tile.dropTarget && !tile.isPlus && wid && spot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            x: spot ? spot.x * tile.width : 0
            y: spot ? spot.y * tile.height : 0
            width: spot ? spot.w * tile.width : 0
            height: spot ? spot.h * tile.height : 0
            Rectangle { anchors.fill: parent; radius: 3 * tile.u; color: tile.bar.accentSoft }
            ShaderEffectSource {
                anchors.fill: parent
                sourceItem: preview.wid && preview.opacity > 0 ? tile.bar.pictureOf(preview.wid) : null
                visible: sourceItem !== null
                opacity: 0.7
                smooth: true
                mipmap: true
            }
            Rectangle { anchors.fill: parent; radius: 3 * tile.u; color: "transparent"; border.width: 2 * tile.u; border.color: tile.scene.accent }
        }

        // "+": a new desk, quiet frosted glass card that brightens on hover or drop.
        Item {
            visible: tile.isPlus
            anchors.fill: parent
            Rectangle {
                anchors.fill: parent
                color: tile.dropTarget ? Qt.rgba(tile.scene.accent.r, tile.scene.accent.g, tile.scene.accent.b, 0.24)
                                       : tile.hot ? (tile.scene.lightMode ? Qt.rgba(tile.scene.accent.r, tile.scene.accent.g, tile.scene.accent.b, 0.16) : tile.bar.accentSoft)
                                       : tile.scene.lightMode ? Qt.rgba(1, 1, 1, 0.56) : Qt.rgba(1, 1, 1, 0.08)
                Behavior on color { ColorAnimation { duration: 140 } }
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: Math.max(1, tile.u)
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: face.radius * 0.85
                    anchors.rightMargin: face.radius * 0.85
                    height: Math.max(1, tile.u)
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, tile.scene.lightMode ? 0.72 : 0.20) }
                        GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, tile.scene.lightMode ? 0.72 : 0.20) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
            }
            Item {
                anchors.centerIn: parent
                width: 26 * tile.u; height: width
                scale: tile.dropTarget ? 1.18 : (tile.hot ? 1.08 : 1)
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                readonly property color plusInk: tile.dropTarget || tile.hot ? tile.scene.accent : tile.scene.inkSoft
                Rectangle { anchors.centerIn: parent; width: parent.width; height: 2.5 * tile.u; radius: height / 2; color: parent.plusInk; Behavior on color { ColorAnimation { duration: 140 } } }
                Rectangle { anchors.centerIn: parent; height: parent.width; width: 2.5 * tile.u; radius: width / 2; color: parent.plusInk; Behavior on color { ColorAnimation { duration: 140 } } }
            }
        }
        // ---- pointer ---------------------------------------------------------------------
        HoverHandler {
            id: hover
            cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        }
        TapHandler {
            id: tap
            enabled: tile.scene.isOpen && !tile.scene.closing
            onTapped: if (tile.isPlus) tile.bar.plusTapped(); else tile.bar.tileTapped(tile.deskId)
            onDoubleTapped: tile.bar.tileDoubleTapped(tile.deskId)
        }
        DragHandler {
            id: dragH
            target: null
            dragThreshold: Math.round(16 * tile.u)
            enabled: tile.scene.isOpen && !tile.scene.closing && tile.drag !== null
            function scenePoint(sp) { return tile.scene.mapFromItem(null, sp.x, sp.y); }
            onActiveChanged: {
                var d = tile.drag;
                if (active) {
                    var press = face.mapToItem(tile.scene, centroid.pressPosition.x, centroid.pressPosition.y);
                    // Window or desk, from where the pointer went (Qt 6.12 reports translation 0,0 here).
                    var wid = tile.miniAt(centroid.pressPosition);
                    var dx = centroid.scenePosition.x - centroid.scenePressPosition.x, dy = centroid.scenePosition.y - centroid.scenePressPosition.y;
                    var pullsDown = dy > Math.abs(dx);
                    if (wid && (pullsDown || tile.bar.ids.length < 2 || tile.isPlus)) tile.bar.pickFromMini(wid, press);
                    else if (!tile.isPlus) d.begin("desk", tile.deskId, press);
                    if (d.kind !== "") d.move(scenePoint(centroid.scenePosition));
                } else if (d.kind !== "") d.drop();
            }
            onCentroidChanged: if (active && tile.drag.kind !== "") tile.drag.move(scenePoint(centroid.scenePosition))
            onCanceled: if (tile.drag.kind !== "") tile.drag.cancel()
        }
    }

    // Crisp hairline around every tile (including "+"); brightens to accent on hover/drop for "+".
    Rectangle {
        anchors.fill: face
        radius: face.radius
        color: "transparent"
        border.width: tile.isPlus && tile.dropTarget ? 2 * tile.u : Math.max(1, tile.u)
        border.color: tile.isPlus && (tile.dropTarget || tile.hot)
                      ? tile.scene.accent
                      : tile.isPlus
                      ? (tile.scene.lightMode ? Qt.rgba(0, 0, 0, 0.16) : Qt.rgba(1, 1, 1, 0.18))
                      : (tile.scene.lightMode ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.16))
        Behavior on border.color { ColorAnimation { duration: 140 } }
    }

    // Active/lifted/dropTarget state drives the inline number badge below the tile,
    // leaving 100 % of the miniature preview unobstructed (no corner badge stamped over windows).
    readonly property bool pillAccent: active || lifted || dropTarget

    // "+1": the desk gains this window.
    Rectangle {
        id: plusOne
        anchors.top: face.top
        anchors.right: face.right
        anchors.margins: 8 * tile.u
        height: 24 * tile.u
        width: plusOneText.implicitWidth + 16 * tile.u
        radius: height / 2
        color: tile.scene.accent
        visible: opacity > 0.01
        opacity: tile.dropTarget && !tile.isPlus && tile.carryingWindow ? 1 : 0
        scale: opacity > 0.5 ? 1 : 0.8
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Rectangle {
            anchors.top: parent.top
            anchors.topMargin: Math.max(1, tile.u)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: plusOne.radius * 0.8
            anchors.rightMargin: plusOne.radius * 0.8
            height: Math.max(1, tile.u)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, 0.30) }
                GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, 0.30) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Text {
            id: plusOneText
            anchors.centerIn: parent
            text: "+1"
            color: tile.bar.accentInk
            font.family: tile.scene.monoFont
            font.pixelSize: 13.5 * tile.u
            font.weight: Font.Bold
            font.features: ({ "tnum": 1 })
        }
    }

    // "Empty": a quiet frosted glass pill centered on an empty desk.
    Rectangle {
        id: emptyBadge
        objectName: "emptyBadge"
        anchors.centerIn: face
        height: 26 * tile.u
        width: emptyText.implicitWidth + 24 * tile.u
        radius: height / 2
        color: tile.scene.lightMode ? Qt.rgba(1, 1, 1, 0.86) : Qt.rgba(0.08, 0.09, 0.12, 0.78)
        border.width: Math.max(1, tile.u)
        border.color: tile.scene.lightMode ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.20)
        visible: opacity > 0.01
        opacity: tile.empty && !tile.dropTarget ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Rectangle {
            anchors.top: parent.top
            anchors.topMargin: Math.max(1, tile.u)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: emptyBadge.radius * 0.85
            anchors.rightMargin: emptyBadge.radius * 0.85
            height: Math.max(1, tile.u)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, tile.scene.lightMode ? 0.72 : 0.22) }
                GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, tile.scene.lightMode ? 0.72 : 0.22) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Text {
            id: emptyText
            anchors.centerIn: parent
            text: "Empty"
            color: tile.scene.lightMode ? tile.scene.ink : Qt.rgba(tile.scene.ink.r, tile.scene.ink.g, tile.scene.ink.b, 0.92)
            font.family: tile.scene.uiFont
            font.pixelSize: 13 * tile.u
            font.weight: Font.DemiBold
        }
    }

    // Rings, 4 u off the face: 3 u accent where he is, where he aims and where it will drop;
    // 2 u soft accent on the desk he is looking at.
    Rectangle {
        anchors.fill: face
        anchors.margins: -7 * tile.u
        radius: face.radius + 7 * tile.u
        color: "transparent"
        readonly property bool strong: tile.active || tile.dropTarget || tile.aimed || tile.lifted
        border.width: (strong ? 3 : 2) * tile.u
        border.color: strong ? tile.scene.accent : tile.bar.accentGlow
        opacity: strong || tile.viewed ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }
    // Hover-hold: a timer of its own, 4 u just outside the accent ring, white on a dark theme and ink on a light
    // one, filling clockwise from the top; when full, the grid pages to this desk.
    Shape {
        anchors.fill: face
        anchors.margins: -14 * tile.u
        visible: tile.hold > 0
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: "transparent"
            fillRule: ShapePath.OddEvenFill
            fillGradient: ConicalGradient {
                centerX: (tile.width + 28 * tile.u) / 2
                centerY: (tile.height + 28 * tile.u) / 2
                angle: 90
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: Math.max(0, 1 - tile.hold - 0.0001); color: "transparent" }
                GradientStop { position: Math.max(0, 1 - tile.hold); color: tile.holdInk }
                GradientStop { position: 1; color: tile.holdInk }
            }
            PathRectangle { x: 0; y: 0; width: tile.width + 28 * tile.u; height: tile.height + 28 * tile.u; radius: face.radius + 14 * tile.u }
            PathRectangle { x: 4 * tile.u; y: 4 * tile.u; width: tile.width + 20 * tile.u; height: tile.height + 20 * tile.u; radius: face.radius + 10 * tile.u }
        }
    }

    // Under the tile: inline numbered pill (relabelled live) + app name, never occluding the miniature preview.
    // Non-lifted captions gently recede during a desk drag so the carried tile never clashes visually with them.
    readonly property color holdInk: scene.lightMode ? Qt.rgba(scene.ink.r, scene.ink.g, scene.ink.b, 0.85) : Qt.rgba(1, 1, 1, 0.85)
    Row {
        id: caption
        anchors.top: face.bottom
        anchors.topMargin: 17 * tile.u
        anchors.horizontalCenter: face.horizontalCenter
        spacing: 8 * tile.u
        width: Math.min(implicitWidth, tile.width)
        opacity: tile.lifted ? 0 : (tile.deskCarried ? 0.42 : 1)
        Behavior on opacity { NumberAnimation { duration: 120 } }
        Rectangle {
            visible: tile.desk.waiting > 0
            width: 8 * tile.u; height: width; radius: width / 2
            color: tile.scene.amber
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            id: inlineNumPill
            visible: !tile.isPlus
            height: 21 * tile.u
            width: Math.max(height, inlineNumText.implicitWidth + 12 * tile.u)
            radius: height / 2
            anchors.verticalCenter: parent.verticalCenter
            color: tile.pillAccent ? tile.scene.accent
                                   : tile.scene.lightMode ? Qt.rgba(1, 1, 1, 0.74) : Qt.rgba(1, 1, 1, 0.14)
            border.width: tile.pillAccent ? 0 : Math.max(1, tile.u)
            border.color: tile.scene.lightMode ? Qt.rgba(0, 0, 0, 0.15) : Qt.rgba(1, 1, 1, 0.18)
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Math.max(1, tile.u)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: inlineNumPill.radius * 0.75
                anchors.rightMargin: inlineNumPill.radius * 0.75
                height: Math.max(1, tile.u)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, tile.pillAccent ? 0.28 : (tile.scene.lightMode ? 0.65 : 0.22)) }
                    GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, tile.pillAccent ? 0.28 : (tile.scene.lightMode ? 0.65 : 0.22)) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
            Text {
                id: inlineNumText
                anchors.centerIn: parent
                text: tile.number
                color: tile.pillAccent ? tile.bar.accentInk : tile.scene.ink
                font.family: tile.scene.monoFont
                font.pixelSize: 12.5 * tile.u
                font.weight: Font.Bold
                font.features: ({ "tnum": 1 })
                Behavior on text {
                    SequentialAnimation {
                        NumberAnimation { target: inlineNumText; property: "opacity"; to: 0; duration: 60 }
                        PropertyAction {}
                        NumberAnimation { target: inlineNumText; property: "opacity"; to: 1; duration: 60 }
                    }
                }
            }
        }
        Text {
            id: deskWord
            visible: tile.isPlus || tile.empty || tile.desk.name === ""
            text: tile.isPlus ? "New desk" : (tile.empty ? "Empty" : "Desk " + tile.number)
            color: tile.isPlus || tile.empty ? tile.scene.inkSoft : tile.scene.ink
            font.family: tile.scene.uiFont
            font.pixelSize: 14 * tile.u
            font.weight: tile.active ? Font.Bold : Font.Medium
            font.letterSpacing: -0.1 * tile.u
            font.features: ({ "tnum": 1 })
            anchors.verticalCenter: parent.verticalCenter
            style: tile.scene.lightMode ? Text.Normal : Text.Raised
            styleColor: Qt.rgba(0, 0, 0, 0.35)
        }
        Text {
            visible: !tile.isPlus && !tile.empty && tile.desk.name !== ""
            text: tile.desk.name
            color: tile.active ? tile.scene.ink : tile.scene.inkSoft
            font.family: tile.scene.uiFont
            font.pixelSize: 14 * tile.u
            font.weight: tile.active ? Font.DemiBold : Font.Medium
            font.letterSpacing: -0.1 * tile.u
            elide: Text.ElideRight
            width: Math.max(0, Math.min(implicitWidth, tile.width - (inlineNumPill.visible ? inlineNumPill.width + caption.spacing : 0) - (tile.desk.waiting > 0 ? 16 * tile.u : 0)))
            anchors.verticalCenter: parent.verticalCenter
            style: tile.scene.lightMode ? Text.Normal : Text.Raised
            styleColor: Qt.rgba(0, 0, 0, 0.35)
        }
    }

}
