import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "Layout.js" as L

// The desk strip along the top: one live miniature per desk, then "+".
// It owns the strip's geometry (Layout.deskStrip with its 130 u floor and
// horizontal scroll), the live preview of a desk drag (tiles step aside and
// their number pills relabel as he moves), the parting of two tiles and the
// insert bar for a window held in a gap, auto-scroll near the ends while
// carrying something, and the one-capture-per-window register that lets a
// miniature show its card's picture instead of capturing the window again.
//
// Tiles are keyed by desk id (and "plus"), so a refresh never rebuilds them
// and a running capture survives. Every change of place is drawn as an
// offset that springs back to zero (first-last-invert-play), which is also
// how a committed reorder lands without a single wrong frame: the poses
// before the model changed are carried over to the tiles that now hold
// those desks.
//
// FROZEN INTERFACE (SPEC 4.1):
//   properties  desks, activeDesk, viewedDesk, previewOrder, dropState
//   signals     tileTapped(id), tileDoubleTapped(id), plusTapped(), hoverOpen(id)
// Scene.qml should bind:  drag: dragCtl; previewOrder: dragCtl.previewOrder; dropState: dragCtl.target || ({})
//   and connect the four signals (view a desk / go there / view a new desk / page to the held desk).
//   Until it does, the bar finds the DragController itself and uses its state.
// Also used by Scene.qml (scaffold API): scene, tileCount, tileAt(i) (each tile has picturesPending()).
Item {
    id: bar
    objectName: "overviewSpacesBar"

    required property var scene
    property var desks: []
    property int activeDesk: 1
    property int viewedDesk: 1
    property var drag: null
    property var previewOrder: drag ? drag.previewOrder : []
    property var dropState: drag && drag.target ? drag.target : ({})

    signal tileTapped(int id)
    signal tileDoubleTapped(int id)
    signal plusTapped()
    signal hoverOpen(int id)

    readonly property real u: scene.u

    // ---- tokens the SPEC adds (2.2); everything else is the scene's --------
    readonly property color accentSoft: scene.accentSoft      // accent 22 %, one definition (Scene.qml)
    readonly property color accentGlow: scene.accentGlow      // accent 35 %
    // ink on an accent fill: the darker of the theme's two ends when the accent is light, white otherwise
    readonly property color accentInk: (0.299 * scene.accent.r + 0.587 * scene.accent.g + 0.114 * scene.accent.b) > 0.62
                                       ? (scene.lightMode ? scene.chipInk : Qt.rgba(scene.background.r * 0.5, scene.background.g * 0.5, scene.background.b * 0.5, 1))
                                       : "#ffffff"

    // ---- desks ----------------------------------------------------------------
    readonly property var realDesks: desks.filter(function (d) { return !d.isNew; })
    readonly property var ids: realDesks.map(function (d) { return d.id; })
    // The screen's own desks (the bar's run, empty ones included) take part in a reorder; guests (another screen's
    // desks waiting here, listed last as the bar does) stay where they are and keep their numbers.
    readonly property var ownIds: realDesks.filter(function (d) { return !d.guest; }).map(function (d) { return d.id; })
    readonly property var guestIds: realDesks.filter(function (d) { return !!d.guest; }).map(function (d) { return d.id; })
    readonly property int plusId: {
        for (var i = 0; i < desks.length; i++) if (desks[i].isNew) return desks[i].id;
        return ids.length ? Math.max.apply(null, ids) + 1 : 1;
    }
    readonly property var deskById: {
        var m = {};
        for (var i = 0; i < realDesks.length; i++) m[realDesks[i].id] = realDesks[i];
        return m;
    }
    // Numbers are positions: while a desk is carried, every pill already shows the number it will have.
    readonly property var order: previewOrder && previewOrder.length === ids.length ? previewOrder : ids
    readonly property var labels: {
        var m = L.labelsFor(order.slice(0, ownIds.length));
        for (var i = 0; i < guestIds.length; i++) m[guestIds[i]] = guestIds[i];
        return m;
    }
    function labelList() { return order.map(function (id) { return labels[id]; }); }

    // ---- geometry (strip coordinates; the row is drawn shifted by -scrollX) ----
    property real scrollX: 0
    readonly property var geo: L.deskStrip(ids.length + 1, width, scene.stripMargin, 30 * u, 272 * u, width / Math.max(1, height), undefined, 0)
    readonly property real tileW: geo.length ? geo[0].w : 0
    readonly property real tileH: geo.length ? geo[0].h : 0
    readonly property real stripY: scene.stripTop
    readonly property int partAt: dropState && dropState.type === "gap" ? ids.indexOf(dropState.left) : -1
    function slotIndex(key) {
        if (key === "plus") return ids.length;
        var i = order.indexOf(Number(key));
        return i >= 0 ? i : ids.indexOf(Number(key));
    }
    function slotX(key) {
        var i = slotIndex(key), g = geo[i];
        if (!g) return 0;
        return g.x + (partAt >= 0 ? (i <= partAt ? -20 : 20) * u : 0);
    }
    function toContent(sceneX) { return bar.mapFromItem(scene, sceneX, 0).x + scrollX; }
    function band() {
        var p = scene.mapFromItem(bar, 0, stripY);
        return { top: p.y, bottom: p.y + tileH };
    }
    function tileRect(key) {
        var k = key === "plus" || key === plusId ? "plus" : String(key);
        var x = slotX(k) - scrollX;
        return scene.mapFromItem(bar, x, stripY, tileW, tileH);
    }
    function aimPoint(id) {
        var r = tileRect(id);
        return Qt.point(r.x + r.width / 2, r.y + r.height + 90 * u);
    }
    // What a carried window is over: null | desk | plus | gap (with the tile it overlaps) | grid.
    function hitWindow(p) {
        var b = bar.mapFromItem(scene, p.x, p.y);
        if (b.y > stripY + tileH + 60 * u) return { type: "grid" };
        if (geo.scrolls && (b.x < geo.viewX || b.x > geo.viewX + geo.viewW)) return null;
        var h = L.stripHit(geo, ids.length, b.x + scrollX, b.y, stripY - 12 * u, stripY + tileH + 40 * u);
        if (!h) return null;
        if (h.type === "desk") return { type: "desk", id: ids[h.index] };
        if (h.type === "gap") return { type: "gap", index: h.index, left: ids[h.index], right: ids[h.index + 1], tileId: h.tile >= 0 ? ids[h.tile] : -1 };
        return h;
    }
    // Where an accepted window lands, in scene coordinates.
    function landingRect(t, wid) {
        var win = scene.byId[wid];
        if (t.type === "gap") {
            var i = ids.indexOf(t.left), g = geo[i];
            var cx = (g.x + g.w + geo[i + 1].x) / 2 - scrollX;
            var r0 = scene.mapFromItem(bar, cx, stripY + tileH / 2);
            return Qt.rect(r0.x - tileW * 0.22, r0.y - tileH * 0.22, tileW * 0.44, tileH * 0.44);
        }
        var r = tileRect(t.type === "plus" ? "plus" : t.id);
        if (t.type === "plus") return Qt.rect(r.x + r.width * 0.2, r.y + r.height * 0.2, r.width * 0.6, r.height * 0.6);
        var s = L.landingSpot(win, scene.width, scene.height);
        return Qt.rect(r.x + s.x * r.width, r.y + s.y * r.height, s.w * r.width, s.h * r.height);
    }

    // ---- scroll ------------------------------------------------------------------
    function clampScroll(x) { return Math.max(0, Math.min(geo.maxScroll || 0, x)); }
    onGeoChanged: if (scrollX !== clampScroll(scrollX)) scrollX = clampScroll(scrollX)
    function show(id, animated) {
        if (!geo.scrolls) return;
        var i = ids.indexOf(id);
        var to = L.scrollToShow(geo, i < 0 ? ids.length : i);
        if (!animated) { scrollAnim.stop(); scrollX = to; return; }
        scrollAnim.to = to; scrollAnim.restart();
    }
    NumberAnimation { id: scrollAnim; target: bar; property: "scrollX"; duration: 260; easing.type: Easing.OutCubic }
    Connections {
        target: bar.scene
        function onIsOpenChanged() { if (bar.scene.isOpen) bar.show(bar.activeDesk, false); }
    }
    onViewedDeskChanged: if (!drag || drag.kind === "") show(viewedDesk, true)

    // Auto-scroll: a carried window or desk within 50 u of an end, after 100 ms, scrolls up to 1500 u/s.
    FrameAnimation {
        id: autoScroll
        property real dwell: 0
        running: bar.drag !== null && bar.drag.kind !== "" && bar.geo.scrolls
        onRunningChanged: dwell = 0
        onTriggered: {
            var d = bar.drag, p = bar.mapFromItem(bar.scene, d.pos.x, d.pos.y);
            var near = d.kind === "desk" || (p.y > bar.stripY - 40 * bar.u && p.y < bar.stripY + bar.tileH + 60 * bar.u);
            var v = near ? L.autoScrollSpeed(p.x, bar.geo.viewX, bar.geo.viewW, 50 * bar.u, 1500 * bar.u) : 0;
            if (v === 0) { dwell = 0; return; }
            dwell += frameTime;
            if (dwell < 0.1) return;
            var next = bar.clampScroll(bar.scrollX + v * frameTime);
            if (next === bar.scrollX) return;
            scrollAnim.stop();
            bar.scrollX = next;
            d.update();
        }
    }

    // ---- keys during a drag (Esc cancels, Enter drops, arrows aim a keyboard drag) ----
    function takeKeys() { keys.forceActiveFocus(); }
    function releaseKeys() { if (keys.activeFocus) scene.forceActiveFocus(); }
    Item {
        id: keys
        Keys.onPressed: function (e) {
            var d = bar.drag;
            if (!d || d.kind === "") { bar.scene.forceActiveFocus(); return; }
            if (e.key === Qt.Key_Escape) d.cancel();
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) d.drop();
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Backtab) d.step(-1);
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Tab) d.step(1);
            e.accepted = true;
        }
    }

    // ---- one capture per window --------------------------------------------------
    // A window's picture is captured once: by its card while the card is in the
    // grid, else by its miniature. The other one shows that picture through a
    // ShaderEffectSource (no second capture).
    // Two revisions, so a miniature that starts or stops its own capture never
    // re-triggers the question "is the card capturing?" it was answering.
    property var captures: ({})          // "<wid>|card" / "<wid>|mini" -> the capturing item
    property int cardRev: 0
    property int miniRev: 0
    readonly property int captureCount: { cardRev; miniRev; return Object.keys(captures).length; }
    function setCapture(wid, owner, item) {
        var k = wid + "|" + owner;
        if (captures[k] === (item || undefined)) return;
        if (item) captures[k] = item; else delete captures[k];
        if (owner === "card") cardRev++; else miniRev++;
    }
    function pictureOf(wid) {
        cardRev; miniRev;
        var c = captures[wid + "|card"], m = captures[wid + "|mini"];
        if (c && c.ready) return c;
        if (m && m.ready) return m;
        return c || m || null;
    }
    function cardCapturing(wid) { cardRev; return captures[wid + "|card"] !== undefined; }
    function cardReady(wid) { cardRev; var c = captures[wid + "|card"]; return c !== undefined && c.ready === true; }
    Connections {
        target: bar.scene
        function onSettledChanged() {
            if (!bar.scene.settled) return;
            var cards = 0, minis = 0, wins = {};
            for (var k in bar.captures) { var p = k.split("|"); wins[p[0]] = true; if (p[1] === "card") cards++; else minis++; }
            console.log("overview: captures " + (cards + minis) + " for " + Object.keys(wins).length + " of " + bar.scene.windows.length
                        + " windows (" + cards + " cards, " + minis + " miniatures)");
        }
    }

    // ---- picking a window out of a miniature ----------------------------------------
    function pickFromMini(wid, p) {
        var w = scene.byId[wid];
        if (!w || !drag) return false;
        var t = tileItem(String(w.desk)), m = t ? t.miniItem(wid) : null;
        if (!m) return false;
        var r = scene.mapFromItem(m, 0, 0, m.width, m.height);
        var grab = Qt.point(Math.max(0, Math.min(1, (p.x - r.x) / Math.max(1, r.width))), Math.max(0, Math.min(1, (p.y - r.y) / Math.max(1, r.height))));
        return drag.begin("window", wid, p, { grab: grab, rect: r });
    }

    // ---- landing a committed change without a wrong frame ---------------------------
    // settle(): called with the commit before the preview is cleared; records where
    // every tile is drawn and which tile will hold that desk afterwards.
    property var flipFrom: ({})
    property string popKey: ""
    property bool manual: false
    function settle(c, applied) {
        var poses = {};
        for (var i = 0; i < tileRep.count; i++) { var t = tileRep.itemAt(i); if (t) poses[t.key] = t.pose(); }
        var map = {}, pop = "", op = c.op;
        function to(o) { return o; }
        var newOf = to;
        if (applied && op.op === "reorder") {
            var s = (op.positions || c.ids).slice().sort(function (a, b) { return a - b; });
            newOf = function (o) { var j = op.order.indexOf(o); return j >= 0 ? s[j] : o; };
        } else if (applied && op.op === "insert") {
            var free = -1;
            for (var k = op.left + 1; k < op.right; k++) if (c.ids.indexOf(k) < 0) { free = k; break; }
            if (free >= 0) pop = String(free);
            else { pop = String(op.right); newOf = function (o) { return o >= op.right && (!op.last || o <= op.last) ? o + 1 : o; }; }
        } else if (applied && op.op === "newdesk") pop = String(c.plusId);
        for (var key in poses) map[key === "plus" ? "plus" : String(newOf(Number(key)))] = poses[key];
        flipFrom = map;
        popKey = pop;
        manual = true;
    }
    function afterCommit() {
        for (var i = 0; i < tileRep.count; i++) { var t = tileRep.itemAt(i); if (t) t.arrive(); }
        manual = false;
        Qt.callLater(function () { bar.flipFrom = ({}); bar.popKey = ""; });
    }

    // ---- keyed tiles ---------------------------------------------------------------
    ListModel { id: tileList }
    function syncTiles() {
        var want = ids.map(String).concat(["plus"]), have = {};
        for (var i = tileList.count - 1; i >= 0; i--) {
            var k = tileList.get(i).key;
            if (want.indexOf(k) < 0) tileList.remove(i); else have[k] = true;
        }
        for (i = 0; i < want.length; i++) if (!have[want[i]]) tileList.append({ key: want[i] });
        if (drag) { drag.checkCommit(); drag.checkCarried(); }
    }
    onIdsChanged: syncTiles()
    Component.onCompleted: {
        if (!drag) {
            var d = scene.data;
            for (var i = 0; i < d.length; i++) if (d[i] && d[i].objectName === "overviewDrag") { drag = d[i]; break; }
        }
        if (drag && !drag.bar) drag.bar = bar;
        syncTiles();
    }
    readonly property alias tileCount: tileRep.count
    function tileAt(i) { return tileRep.itemAt(i); }
    function tileItem(key) {
        for (var i = 0; i < tileRep.count; i++) { var t = tileRep.itemAt(i); if (t && t.key === key) return t; }
        return null;
    }
    readonly property real liftX: drag && drag.kind === "desk" ? toContent(drag.pos.x - drag.grab.x) : 0
    // A held desk stays strictly on or slightly above the strip lane (-3 u .. 0 u): lifted (1.08)
    // and ringed, it clears the 26 u bar above and never dips onto neighbouring captions below.
    readonly property real liftY: {
        if (!drag || drag.kind !== "desk") return 0;
        var dy = drag.pos.y - drag.startPos.y;
        return Math.max(-3 * u, Math.min(0, L.rubberY(dy, 0.25, 3 * u)));
    }

    // The visible band: the whole width, faded 40 u at an end the row runs past.
    Item {
        id: view
        width: bar.width
        height: bar.stripY + bar.tileH + 72 * bar.u
        layer.enabled: bar.geo.scrolls
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: fadeMask
            maskThresholdMin: 0
            maskSpreadAtMin: 1
        }
        WheelHandler {
            enabled: bar.geo.scrolls
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function (ev) {
                var d = ev.pixelDelta.x !== 0 ? ev.pixelDelta.x : ev.pixelDelta.y !== 0 ? ev.pixelDelta.y
                      : (ev.angleDelta.x !== 0 ? ev.angleDelta.x : ev.angleDelta.y) / 2;
                scrollAnim.stop();
                bar.scrollX = bar.clampScroll(bar.scrollX - d * bar.u);
                if (bar.drag && bar.drag.kind !== "") bar.drag.update();
            }
        }
        Item {
            id: content
            x: -bar.scrollX
            width: bar.geo.contentW || bar.width
            height: view.height
            // Where a carried desk will land: a soft recessed glass slot gliding smoothly with the strip.
            Item {
                id: landingSlot
                readonly property bool on: bar.drag !== null && bar.drag.kind === "desk" && !bar.drag.cancelZone
                property real slotX: 0
                Binding on slotX { when: landingSlot.on; value: bar.slotX(String(bar.drag.itemId)); restoreMode: Binding.RestoreNone }
                x: slotX
                y: bar.stripY
                width: bar.tileW
                height: bar.tileH
                z: -1
                visible: opacity > 0.01
                opacity: on ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on slotX { enabled: landingSlot.on && landingSlot.opacity > 0.9; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Rectangle {
                    id: landingSlotBox
                    anchors.fill: parent
                    radius: 14 * bar.u
                    color: Qt.rgba(bar.scene.accent.r, bar.scene.accent.g, bar.scene.accent.b, bar.scene.lightMode ? 0.18 : 0.14)
                    border.width: 1.5 * bar.u
                    border.color: Qt.rgba(bar.scene.accent.r, bar.scene.accent.g, bar.scene.accent.b, bar.scene.lightMode ? 0.62 : 0.52)
                    Rectangle {
                        anchors.top: parent.top
                        anchors.topMargin: Math.max(1, bar.u)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: landingSlotBox.radius * 0.85
                        anchors.rightMargin: landingSlotBox.radius * 0.85
                        height: Math.max(1, bar.u)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 0.28; color: Qt.rgba(1, 1, 1, bar.scene.lightMode ? 0.58 : 0.18) }
                            GradientStop { position: 0.72; color: Qt.rgba(1, 1, 1, bar.scene.lightMode ? 0.44 : 0.14) }
                            GradientStop { position: 1.0; color: "transparent" }
                        }
                    }
                }
            }
            Repeater {
                id: tileRep
                model: tileList
                readonly property var owner: bar
                delegate: DeskTile { bar: tileRep.owner }
            }
            // A window held in a gap: the neighbours part and a bold accent bar marks the new desk.
            Item {
                id: insertBar
                readonly property int at: bar.partAt
                readonly property var a: at >= 0 ? bar.geo[at] : null
                readonly property var b: at >= 0 ? bar.geo[at + 1] : null
                visible: opacity > 0.01
                opacity: at >= 0 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                x: a && b ? (a.x + a.w + b.x) / 2 - width / 2 : x
                y: bar.stripY
                width: 6 * bar.u
                height: bar.tileH
                transform: Scale { origin.y: insertBar.height / 2; yScale: insertBar.at >= 0 ? 1 : 0.6; Behavior on yScale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } } }
                RectangularShadow {
                    anchors.fill: parent
                    radius: width / 2
                    blur: 18 * bar.u
                    spread: 2 * bar.u
                    color: bar.accentGlow
                }
                Rectangle { anchors.fill: parent; radius: width / 2; color: bar.scene.accent }
                // What a drop here does, in words: under the bar, on the captions' line, clear of the carried token.
                RectangularShadow {
                    anchors.fill: insertPill
                    radius: insertPill.radius
                    blur: 14 * bar.u
                    offset: Qt.vector2d(0, 3 * bar.u)
                    color: bar.scene.contactColor
                }
                Rectangle {
                    id: insertPill
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.bottom
                    anchors.topMargin: 14 * bar.u
                    height: 22 * bar.u
                    width: newDeskText.implicitWidth + 18 * bar.u
                    radius: height / 2
                    color: bar.scene.accent
                    Rectangle {
                        anchors.top: parent.top
                        anchors.topMargin: Math.max(1, bar.u)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: insertPill.radius * 0.8
                        anchors.rightMargin: insertPill.radius * 0.8
                        height: Math.max(1, bar.u)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, 0.32) }
                            GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, 0.32) }
                            GradientStop { position: 1.0; color: "transparent" }
                        }
                    }
                    Text {
                        id: newDeskText
                        anchors.centerIn: parent
                        text: "New desk"
                        color: bar.accentInk
                        font.family: bar.scene.uiFont
                        font.pixelSize: 13 * bar.u
                        font.weight: Font.Bold
                        font.letterSpacing: -0.1 * bar.u
                    }
                }
            }
        }
    }
    Item {
        id: fadeMask
        visible: false
        layer.enabled: true
        width: view.width
        height: view.height
        readonly property real f: 40 * bar.u / Math.max(1, width)
        readonly property real l: bar.geo.viewX / Math.max(1, width)
        readonly property real r: (bar.geo.viewX + bar.geo.viewW) / Math.max(1, width)
        readonly property bool fadeL: bar.scrollX > 0.5
        readonly property bool fadeR: bar.scrollX < (bar.geo.maxScroll || 0) - 0.5
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: fadeMask.fadeL ? "transparent" : "white" }
                GradientStop { position: fadeMask.l; color: fadeMask.fadeL ? "transparent" : "white" }
                GradientStop { position: fadeMask.l + fadeMask.f; color: "white" }
                GradientStop { position: fadeMask.r - fadeMask.f; color: "white" }
                GradientStop { position: fadeMask.r; color: fadeMask.fadeR ? "transparent" : "white" }
                GradientStop { position: 1; color: fadeMask.fadeR ? "transparent" : "white" }
            }
        }
    }
}
