import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "Layout.js" as L

// One window in the overview grid. It is laid out at its grid size and
// carried by a transform from where the window really is on screen to its
// grid place (first-last-invert-play), so the picture's texture never
// changes size while it travels: one GPU pass per card per frame.
//
// Carrying (SPEC 2.5): after 16 u the card lifts to at most 256 u on its long
// side at 85 %, keeps the point he grabbed, and leaves its slot as a hole;
// an accepted drop shrinks it into the target desk's miniature (220 ms), any
// other release sends it home (250 ms). Its picture is the window's one
// capture while it is in the grid; otherwise it borrows the miniature's.
Item {
    id: card
    required property string wid
    required property var scene

    // The strip (SpacesBar) holds the drag controller and the capture register.
    property var bar: null
    readonly property var drag: bar ? bar.drag : null
    function findBar() {
        var c = scene.children;
        for (var i = 0; i < c.length; i++) if (c[i] && c[i].objectName === "overviewSpacesBar") return c[i];
        return null;
    }

    readonly property var win: scene.byId[wid] || null
    readonly property var g: scene.layout[wid] || null
    readonly property bool inGrid: g !== null && win !== null
    readonly property bool onActive: win !== null && win.desk === scene.activeDesk
    readonly property real u: scene.u

    // Grid place, kept when the card leaves the grid so it fades where it was.
    property real gx: 0
    property real gy: 0
    property real gw: 100
    property real gh: 100
    property bool placed: false
    onGChanged: {
        if (!g) return;
        gx = g.x; gy = g.y; gw = g.w; gh = g.h;
        placed = true;
    }
    Component.onCompleted: {
        if (g) { gx = g.x; gy = g.y; gw = g.w; gh = g.h; placed = true; }
        bar = findBar();
        registerCapture();
    }
    Component.onDestruction: if (bar) bar.setCapture(wid, "card", null)
    readonly property bool reflow: scene.settled && placed && presence > 0.01 && restScale === 1
    Behavior on gx { enabled: card.reflow; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on gy { enabled: card.reflow; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on gw { enabled: card.reflow; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on gh { enabled: card.reflow; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    property real presence: inGrid ? 1 : 0
    Behavior on presence { enabled: scene.settled; NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

    // Travel: windows of the current desk fly between their real place and
    // the grid; everything else appears in place.
    readonly property bool flies: onActive && scene.flip
    readonly property real tf: flies ? scene.t : 1
    readonly property real hx: win ? win.x : gx
    readonly property real hy: win ? win.y : gy
    readonly property real s0: win ? Math.max(0.05, win.w / Math.max(1, gw)) : 1
    readonly property real travelScale: L.lerp(s0, 1, tf)
    readonly property real fade: (flies ? 1 : scene.t) * presence

    // Dragging: the card shrinks toward the pointer and follows it.
    readonly property bool dragging: drag !== null && drag.kind === "window" && drag.itemId === wid
    property real shrink: dragging ? 1 : 0
    Behavior on shrink { NumberAnimation { duration: card.dragging ? 120 : 250; easing.type: Easing.OutCubic } }
    // Over the strip the card becomes a small token (64 u long side, 60 %, the pointer at its top-left
    // quarter, corners like a miniature's), so the landing preview inside the tile is what the eye reads;
    // elsewhere it travels at up to 256 u, 85 %.
    readonly property bool overStrip: dragging && drag.target !== null && drag.target !== undefined
                                      && ["desk", "plus", "gap"].indexOf(drag.target.type) >= 0
    property real overK: overStrip ? 1 : 0
    Behavior on overK { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    readonly property real carryLong: L.lerp(256, 64, overK)
    readonly property real carryOpacity: L.lerp(0.85, 0.6, overK)
    readonly property real grabFx: dragging || shrink > 0 ? L.lerp(drag.grab.x, 0.25, overK) : 0.5
    readonly property real grabFy: dragging || shrink > 0 ? L.lerp(drag.grab.y, 0.25, overK) : 0.5
    readonly property real dragScale: Math.min(1, carryLong * u / Math.max(1, Math.max(gw, gh)))
    // Picked from a miniature (not in the grid): it starts at the miniature's place and size.
    property real restScale: 1
    onDraggingChanged: {
        if (!dragging || inGrid || !drag.origin || !win) return;
        var r = drag.origin;
        restScale = 1; gw = win.w; gh = win.h;
        restScale = Math.max(0.01, r.width / Math.max(1, gw));
        gx = r.x; gy = r.y;
    }
    onInGridChanged: if (inGrid) restScale = 1
    readonly property real baseX: L.lerp(hx, gx, tf)
    readonly property real baseY: L.lerp(hy, gy, tf)
    readonly property real dragX: (drag ? drag.pos.x : 0) - grabFx * gw * dragScale
    // Never over the 26 u bar: the top edge stays 4 u below it.
    readonly property real dragY: Math.max(30 * u, (drag ? drag.pos.y : 0) - grabFy * gh * dragScale)

    // An accepted drop: from where the hand let go into the target miniature, 220 ms.
    property real landT: 0
    property var landFrom: null
    property var landTo: null
    property int landDesk: -1
    property bool landed: false             // hidden until the model shows the move (or 600 ms pass)
    readonly property bool landingHere: drag !== null && drag.landing !== null && drag.landing.wid === wid
    onLandingHereChanged: {
        if (!landingHere) return;
        landFrom = { x: dragX, y: dragY, s: dragScale };
        landTo = drag.landing.rect;
        landDesk = win ? win.desk : -1;
        landed = false;
        landAnim.restart();
    }
    NumberAnimation {
        id: landAnim
        target: card; property: "landT"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic
        onFinished: { card.landed = true; landTimer.restart(); }
    }
    Timer { id: landTimer; interval: 600; onTriggered: { card.landed = false; card.landT = 0; } }
    readonly property bool landing: landAnim.running || (landed && win !== null && win.desk === landDesk)
    onWinChanged: if (landed && win && win.desk !== landDesk) { landed = false; landT = 0; landTimer.stop(); }

    readonly property bool selected: scene.selectedId === wid && scene.showSelection
    readonly property bool hovered: body.hoveredNow
    readonly property bool lifted: (selected || hovered) && !dragging && scene.settled
    readonly property bool pressed: mouse.pressed && !dragging
    // A window leaves with the corners it has on the desktop; as a token over the strip it takes a miniature's.
    readonly property real miniRadius: Math.max(6 * u, (bar ? bar.tileW / Math.max(1, scene.width) : 0.1) * 14 * u)
    readonly property real radiusShown: L.lerp(L.lerp(scene.homeRadius, 14, tf), miniRadius, overK)

    // The flight waits for these (see Scene.arming).
    readonly property bool awaited: inGrid && onActive
    readonly property bool picturePending: thumbLoader.item ? thumbLoader.item.pending === true : false
    onPicturePendingChanged: if (!picturePending) scene.pictureArrived()
    function refreshPicture() { if (thumbLoader.item) thumbLoader.item.refresh(); }

    visible: (fade > 0.005 || dragging || shrink > 0.001 || landing) && win !== null
    z: dragging || landing ? 1000 : (lifted ? 3 : (win && win.agent === "waiting" ? 2 : 1))

    // The window's one capture: the card takes it while it is in the grid.
    readonly property bool capturingNow: scene.capturing && inGrid
    function registerCapture() { if (bar) bar.setCapture(wid, "card", capturingNow ? thumbLoader.item : null); }
    onCapturingNowChanged: registerCapture()

    Item {
        id: body
        property bool hoveredNow: (mouse.containsMouse || closeMouse.containsMouse) && !scene.dragId
        width: card.gw
        height: card.gh
        transformOrigin: Item.TopLeft
        readonly property real restS: card.travelScale * card.restScale
        x: card.landing && card.landFrom ? L.lerp(card.landFrom.x, card.landTo.x, card.landT) : L.lerp(card.baseX, card.dragX, card.shrink)
        y: card.landing && card.landFrom ? L.lerp(card.landFrom.y, card.landTo.y, card.landT) : L.lerp(card.baseY, card.dragY, card.shrink)
        scale: card.landing && card.landFrom ? L.lerp(card.landFrom.s, card.landTo.width / Math.max(1, card.gw), card.landT)
                                             : L.lerp(restS, card.dragScale, card.shrink)
        opacity: card.landing ? (card.landed ? 0 : L.lerp(card.carryOpacity, 0.7, card.landT)) : L.lerp(card.fade, card.carryOpacity, card.shrink)

        readonly property real r: card.radiusShown / Math.max(0.01, scale)

        Item {
            id: lift
            anchors.fill: parent
            // Hover lifts 1.03, but never more than 8 u on an edge, so labels stay on one line;
            // a press sinks it to 0.98.
            scale: card.pressed ? 0.98 : card.lifted ? 1 + Math.min(0.03, 16 * card.u / Math.max(1, Math.max(card.gw, card.gh))) : 1
            Behavior on scale { NumberAnimation { duration: card.pressed ? 80 : 140; easing.type: Easing.OutCubic } }

            // Two shadows: a wide soft one for depth and a tight one for contact,
            // plus a luminous accent halo when selected via keyboard.
            RectangularShadow {
                anchors.fill: parent
                radius: body.r
                blur: (card.lifted || card.dragging ? 68 : 44) * card.u / body.scale
                spread: 0
                offset: Qt.vector2d(0, (card.lifted || card.dragging ? 28 : 16) * card.u / body.scale)
                color: scene.shadowColor
                opacity: card.tf * (card.lifted || card.dragging ? 1 : (scene.lightMode ? 0.92 : 0.85))
                Behavior on blur { NumberAnimation { duration: 140 } }
            }
            RectangularShadow {
                anchors.fill: parent
                radius: body.r
                blur: (card.lifted || card.dragging ? 12 : 8) * card.u / body.scale
                offset: Qt.vector2d(0, (card.lifted || card.dragging ? 4 : 2) * card.u / body.scale)
                color: scene.contactColor
                opacity: card.tf
            }
            RectangularShadow {
                anchors.fill: parent
                radius: body.r
                blur: 28 * card.u / body.scale
                spread: 2 * card.u / body.scale
                color: scene.accentGlow
                opacity: card.selected ? card.tf : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            // Until the picture arrives: the app's icon on a quiet surface.
            Rectangle {
                anchors.fill: parent
                radius: body.r
                color: scene.surfaceColor
                opacity: (thumbLoader.item && thumbLoader.item.ready) || borrowed.visible ? 0 : card.tf
                Image {
                    anchors.centerIn: parent
                    width: Math.min(72 * card.u, parent.width * 0.3)
                    height: width
                    sourceSize: Qt.size(128, 128)
                    source: card.win ? card.win.icon : ""
                    smooth: true
                    mipmap: true
                }
            }

            Item {
                id: picture
                anchors.fill: parent
                layer.enabled: true
                layer.smooth: true
                layer.effect: ShaderEffect {
                    property vector2d size: Qt.vector2d(picture.width, picture.height)
                    property real radius: body.r
                    fragmentShader: Qt.resolvedUrl("shaders/rounded.frag.qsb")
                }
                // Not in the grid but carried: the miniature's picture, no second capture.
                ShaderEffectSource {
                    id: borrowed
                    anchors.fill: parent
                    sourceItem: !card.capturingNow && (card.dragging || card.landing) && card.bar ? card.bar.pictureOf(card.wid) : null
                    visible: sourceItem !== null && sourceItem.ready === true
                    smooth: true
                }
                Loader {
                    id: thumbLoader
                    anchors.fill: parent
                    sourceComponent: scene.thumbnail
                    onLoaded: {
                        item.winId = Qt.binding(function () { return card.wid; });
                        item.capturing = Qt.binding(function () { return card.capturingNow; });
                        card.registerCapture();
                    }
                    // In flight the picture is simply there; a fade would show the window twice.
                    opacity: item && item.ready ? 1 : 0
                    Behavior on opacity { enabled: scene.settled; NumberAnimation { duration: 90 } }
                }
            }

            // A crisp hairline rim keeps borderless code/terminal windows cleanly framed on any wallpaper.
            Rectangle {
                anchors.fill: parent
                radius: body.r
                color: "transparent"
                border.width: Math.max(1, 1.25 * card.u) / body.scale
                border.color: card.hovered && !card.selected
                              ? (scene.lightMode ? Qt.rgba(0, 0, 0, 0.24) : Qt.rgba(1, 1, 1, 0.36))
                              : (scene.lightMode ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.18))
                Behavior on border.color { ColorAnimation { duration: 120 } }
            }

            // Quiet hover halo: immediate tactile feedback under the pointer without competing with selection.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4 * card.u / body.scale
                radius: body.r + 4 * card.u / body.scale
                color: "transparent"
                border.width: 2 * card.u / body.scale
                border.color: scene.lightMode ? Qt.rgba(scene.accent.r, scene.accent.g, scene.accent.b, 0.48)
                                              : Qt.rgba(1, 1, 1, 0.30)
                opacity: card.hovered && !card.selected && card.tf > 0.9 ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }

            // Keyboard (or pointer) selection: a ring in the accent colour.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6 * card.u / body.scale
                radius: body.r + 6 * card.u / body.scale
                color: "transparent"
                border.width: 3 * card.u / body.scale
                border.color: scene.accent
                opacity: card.selected ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }

            // Agent state, top right: amber "Waiting", or a quietly turning arc.
            Rectangle {
                id: waitingPill
                visible: card.win && card.win.agent === "waiting"
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 14 * card.u
                height: 30 * card.u
                width: waitRow.implicitWidth + 24 * card.u
                radius: height / 2
                color: scene.amber
                border.width: Math.max(1, card.u)
                border.color: Qt.rgba(1, 1, 1, scene.lightMode ? 0.35 : 0.22)
                opacity: card.tf
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: Math.max(1, card.u)
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: waitingPill.radius * 0.85
                    anchors.rightMargin: waitingPill.radius * 0.85
                    height: Math.max(1, card.u)
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, 0.36) }
                        GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, 0.36) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
                Row {
                    id: waitRow
                    anchors.centerIn: parent
                    spacing: 7 * card.u
                    Rectangle { width: 8 * card.u; height: width; radius: width / 2; color: scene.amberInk; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        text: "Waiting for you"
                        color: scene.amberInk
                        font.family: scene.uiFont
                        font.pixelSize: 14 * card.u
                        font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
            RectangularShadow {
                visible: waitingPill.visible
                anchors.fill: waitingPill
                radius: waitingPill.radius
                blur: 18 * card.u
                color: Qt.rgba(scene.amber.r, scene.amber.g, scene.amber.b, 0.55)
                opacity: card.tf
                z: -1
            }
            Item {
                id: workingMark
                visible: card.win && card.win.agent === "working"
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 14 * card.u
                width: 32 * card.u
                height: width
                opacity: card.tf
                RectangularShadow {
                    anchors.fill: parent
                    radius: width / 2
                    blur: 12 * card.u
                    offset: Qt.vector2d(0, 3 * card.u)
                    color: scene.contactColor
                }
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: scene.chipColor
                    border.width: Math.max(1, card.u)
                    border.color: scene.hairline
                }
                Shape {
                    id: arc
                    anchors.fill: parent
                    anchors.margins: 8 * card.u
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: scene.chipInk
                        strokeWidth: 2.4 * card.u
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: arc.width / 2; centerY: arc.height / 2; radiusX: arc.width / 2; radiusY: arc.height / 2; startAngle: 0; sweepAngle: 250 }
                    }
                    rotation: scene.spin * 30
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse && !scene.dragId && scene.settled) scene.hoverSelect(card.wid)
                onReleased: function (m) {
                    if (cardDrag.active || card.dragging) return;
                    if (m.button === Qt.MiddleButton) scene.requestCloseWindow(card.wid);
                    else scene.choose(card.wid);
                }
                // The handler sits inside the MouseArea so it sees the press first; past
                // 16 u it takes the pointer and the MouseArea's click is cancelled.
                DragHandler {
                    id: cardDrag
                    target: null
                    acceptedButtons: Qt.LeftButton
                    dragThreshold: Math.round(16 * card.u)
                    // Never disabled while it carries: a hover-hold page turn clears settled and inGrid mid-drag,
                    // and a disabled active handler freezes until the release (Qt 6.12).
                    enabled: (card.inGrid && scene.settled && card.drag !== null) || active
                    function scenePoint(sp) { return scene.mapFromItem(null, sp.x, sp.y); }
                    onActiveChanged: {
                        var d = card.drag;
                        if (active) {
                            var pp = centroid.pressPosition;
                            var press = mouse.mapToItem(scene, pp.x, pp.y);
                            d.begin("window", card.wid, press, { grab: Qt.point(pp.x / Math.max(1, mouse.width), pp.y / Math.max(1, mouse.height)) });
                            if (d.kind !== "") d.move(scenePoint(centroid.scenePosition));
                        } else if (d.kind !== "") d.drop();
                    }
                    onCentroidChanged: if (active && card.drag.kind !== "") card.drag.move(scenePoint(centroid.scenePosition))
                    onCanceled: if (card.drag.kind !== "") card.drag.cancel()
                }
            }

            // Close, top left like every other window control on a Mac, elevated
            // cleanly above the corner and selection ring only while hovered/selected.
            RectangularShadow {
                anchors.fill: closeBtn
                radius: closeBtn.radius
                blur: 14 * card.u
                offset: Qt.vector2d(0, 3 * card.u)
                color: scene.lightMode ? Qt.rgba(0, 0, 0, 0.22) : Qt.rgba(0, 0, 0, 0.58)
                opacity: closeBtn.opacity
                visible: closeBtn.visible
                scale: closeBtn.scale
                z: 5
            }
            Rectangle {
                id: closeBtn
                z: 6
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.margins: -11 * card.u
                width: 30 * card.u
                height: width
                radius: width / 2
                color: closeMouse.containsMouse ? scene.closeHot
                       : (scene.lightMode ? Qt.rgba(1, 1, 1, 0.96) : Qt.rgba(0.15, 0.16, 0.20, 0.94))
                border.width: Math.max(1, card.u)
                border.color: closeMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.28)
                              : (scene.lightMode ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.24))
                opacity: card.lifted ? 1 : 0
                visible: opacity > 0
                scale: closeMouse.pressed ? 0.92 : (card.lifted ? 1 : 0.7)
                Behavior on color { ColorAnimation { duration: 110 } }
                Behavior on border.color { ColorAnimation { duration: 110 } }
                Behavior on opacity { NumberAnimation { duration: 140 } }
                Behavior on scale { NumberAnimation { duration: closeMouse.pressed ? 70 : 160; easing.type: closeMouse.pressed ? Easing.OutCubic : Easing.OutBack; easing.overshoot: 1.2 } }
                Shape {
                    anchors.centerIn: parent
                    width: 9 * card.u
                    height: width
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: closeMouse.containsMouse ? "#ffffff" : scene.chipInk
                        strokeWidth: 1.8 * card.u
                        capStyle: ShapePath.RoundCap
                        startX: 0; startY: 0
                        PathLine { x: 9 * card.u; y: 9 * card.u }
                        PathMove { x: 9 * card.u; y: 0 }
                        PathLine { x: 0; y: 9 * card.u }
                    }
                }
                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    anchors.margins: -7 * card.u
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: scene.requestCloseWindow(card.wid)
                }
            }
        }
    }

    // Frosted glass capsule under the picture: app icon and title stay legible over any wallpaper.
    Item {
        id: label
        x: card.gx
        // Clears the lifted card and selection ring, keeping every label in a row on one baseline.
        y: card.gy + card.gh + 21 * card.u
        width: card.gw
        height: 32 * card.u
        // Only once the cards have nearly landed (t 0.8 -> 1): words never sit on a picture still in flight.
        opacity: card.presence * Math.max(0, Math.min(1, (scene.t - 0.8) / 0.2)) * (card.dragging || card.landing ? 0 : 1)
        visible: opacity > 0.01
        readonly property real titleMaxW: Math.max(0, label.width - 24 * card.u
                                                   - (icon.visible ? icon.width + labelRow.spacing : 0)
                                                   - (deskTag.visible ? deskTag.width + labelRow.spacing : 0))
        RectangularShadow {
            anchors.fill: labelPill
            radius: labelPill.radius
            blur: 14 * card.u
            offset: Qt.vector2d(0, 3 * card.u)
            color: scene.lightMode ? Qt.rgba(0.05, 0.07, 0.15, 0.12) : Qt.rgba(0, 0, 0, 0.36)
        }
        Rectangle {
            id: labelPill
            anchors.centerIn: parent
            height: parent.height
            width: Math.min(label.width, labelRow.implicitWidth + 24 * card.u)
            radius: height / 2
            color: scene.lightMode
                   ? (card.selected ? Qt.rgba(1, 1, 1, 0.94) : card.hovered ? Qt.rgba(1, 1, 1, 0.88) : Qt.rgba(1, 1, 1, 0.74))
                   : (card.selected ? Qt.rgba(scene.accent.r * 0.24 + 0.08, scene.accent.g * 0.24 + 0.09, scene.accent.b * 0.24 + 0.13, 0.86)
                      : card.hovered ? Qt.rgba(0.13, 0.14, 0.18, 0.80) : Qt.rgba(0.08, 0.09, 0.12, 0.62))
            border.width: Math.max(1, card.u)
            border.color: card.selected
                          ? Qt.rgba(scene.accent.r, scene.accent.g, scene.accent.b, scene.lightMode ? 0.72 : 0.78)
                          : card.hovered
                          ? (scene.lightMode ? Qt.rgba(0, 0, 0, 0.18) : Qt.rgba(1, 1, 1, 0.26))
                          : (scene.lightMode ? Qt.rgba(0, 0, 0, 0.11) : Qt.rgba(1, 1, 1, 0.14))
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }
            // Crisp 1px top specular highlight along the frosted glass capsule rim.
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Math.max(1, card.u)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: labelPill.radius * 0.85
                anchors.rightMargin: labelPill.radius * 0.85
                height: Math.max(1, card.u)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, scene.lightMode ? 0.78 : (card.selected ? 0.30 : 0.22)) }
                    GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, scene.lightMode ? 0.78 : (card.selected ? 0.30 : 0.22)) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
            Row {
                id: labelRow
                anchors.centerIn: parent
                spacing: 8 * card.u
                Image {
                    id: icon
                    width: 19 * card.u
                    height: width
                    anchors.verticalCenter: parent.verticalCenter
                    source: card.win ? card.win.icon : ""
                    sourceSize: Qt.size(64, 64)
                    smooth: true
                    mipmap: true
                    visible: status === Image.Ready
                }
                Rectangle {
                    id: deskTag
                    visible: scene.query.length > 0 && card.win !== null
                    anchors.verticalCenter: parent.verticalCenter
                    height: 20 * card.u
                    width: deskTagText.implicitWidth + 12 * card.u
                    radius: height / 2
                    color: scene.accentSoft
                    Text {
                        id: deskTagText
                        anchors.centerIn: parent
                        text: card.win ? "Desk " + card.win.desk : ""
                        color: scene.lightMode ? Qt.darker(scene.accent, 1.35) : Qt.lighter(scene.accent, 1.45)
                        font.family: scene.uiFont
                        font.pixelSize: 12 * card.u
                        font.weight: Font.Bold
                        font.features: ({ "tnum": 1 })
                    }
                }
                Text {
                    text: card.win ? card.win.label : ""
                    color: card.selected || card.hovered ? scene.ink
                           : (scene.lightMode ? scene.ink : Qt.rgba(scene.ink.r, scene.ink.g, scene.ink.b, 0.90))
                    font.family: scene.uiFont
                    font.pixelSize: 14.5 * card.u
                    font.weight: card.selected || card.hovered ? Font.DemiBold : Font.Medium
                    font.letterSpacing: -0.1 * card.u
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, label.titleMaxW)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
