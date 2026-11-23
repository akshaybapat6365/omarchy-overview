import QtQuick
import "Layout.js" as L

// One drag state machine for the overview: a window carried to a desk, to
// "+" or into a gap between two desks, or a desk carried to a new place in
// the strip. Pointer (DragHandler in WindowCard/DeskTile), keyboard (Space,
// arrows, Enter, Esc) and the test hook all drive the same five methods, so
// what the hook proves is what the hand does. Geometry questions go to the
// strip (SpacesBar.qml); the pure arithmetic is in Layout.js.
// Nothing reaches Hyprland while a drag is live: the drop emits exactly one
// opRequested(op), and every cancel path emits nothing at all.
//
// FROZEN INTERFACE (SPEC 4.1):
//   properties  kind ("" | "window" | "desk"), itemId, pos,
//               target ({ type: "desk"|"plus"|"gap"|"grid", id, left, right }), previewOrder
//   methods     begin(kind, id, pos), move(pos), drop(), cancel(), liftSelected(), aim(deskId)
//   signals     opRequested(op), cancelled()
//   op = { op: "move"|"newdesk"|"reorder"|"insert", win, desk, order, left, right }
// Additions (lane 3):
//   begin(kind, id, pos, from)   from = { grab: point, rect } — where the item was picked up
//   step(+-1)                    keyboard: aim at the next/previous tile
//   moveDesk(id, delta)          Alt+Shift+Left/Right: one reorder op, no drag
//   drive(kind, id, x, y, phase) -> JSON   the test hook (phases: begin pick move drop cancel lift aim step state)
//   describe(op) -> "move 0xb003→4" | "newdesk 0xb003" | "reorder [1,3,4,5,2,6]" | "insert 1|2 0xb005"
//   bar                          the SpacesBar (Scene binds it; the bar registers itself otherwise)
// Kept for Scene.qml's aliases (scaffold API): dragId, dragPos, dropDesk; beginDrag(id, p), dragTo(p), endDrag().
// Writing dragId = "" (Scene does on open/close) cancels a live drag.
QtObject {
    id: dc
    objectName: "overviewDrag"

    required property var scene
    property var bar: null
    readonly property real u: scene ? scene.u : 1

    // ---- frozen state ------------------------------------------------------
    property string kind: ""
    property var itemId: null
    property point pos: Qt.point(0, 0)
    property var target: null
    property var previewOrder: []
    signal opRequested(var op)
    signal cancelled()

    // ---- what the tiles and cards read -------------------------------------
    property bool keyboard: false
    property point startPos: Qt.point(0, 0)
    property point grab: Qt.point(0.5, 0.5)    // desk: pointer minus the tile's top-left; window: fraction of the card
    property var origin: null                   // window picked from a miniature: { x, y, w, h } in scene coordinates
    property int fromDesk: -1
    property var startIds: []
    property real offStrip: 0                   // desk drag: distance of the pointer above/below the strip
    readonly property bool cancelZone: kind === "desk" && offStrip > 140 * u
    readonly property real liftOpacity: kind === "desk" && offStrip > 100 * u ? 0.6 : 1
    property int aimId: -1
    property int holdId: -1                     // hover-hold: the tile whose ring is filling
    property real holdProgress: 0
    property int gapIndex: -1                   // gap zone under the pointer
    property bool gapArmed: false               // ... held for 150 ms: the tiles part
    property var landing: null                  // { wid, rect } after an accepted window drop
    property var commit: null                   // { op, ids, plusId, snapshot, active } until the model shows the change

    // ---- scaffold API (Scene.qml aliases these) -----------------------------
    property string dragId: ""
    property point dragPos: Qt.point(0, 0)
    property int dropDesk: -1
    property bool quiet: false
    onDragIdChanged: if (!quiet && dragId === "" && kind !== "") cancel()
    function beginDrag(id, p) { begin("window", id, p); }
    function dragTo(p) { move(p); }
    function endDrag() { drop(); }

    property Timer gapTimer: Timer { interval: 150; onTriggered: { dc.gapArmed = dc.gapIndex >= 0; dc.update(); } }
    property NumberAnimation holdAnim: NumberAnimation {
        target: dc; property: "holdProgress"; from: 0; to: 1; duration: 750
        onFinished: dc.holdDone()
    }
    property Timer commitTimer: Timer { interval: 600; onTriggered: dc.finishCommit(false) }
    property Connections watch: Connections {
        target: dc.scene
        function onWindowsChanged() { dc.checkCommit(); dc.checkCarried(); }
        function onActiveDeskChanged() { dc.checkCommit(); }
    }
    // The carried window closed (or the carried desk went away) under his hand: its card and DragHandler are
    // gone, so no release will ever come. End the drag here; nothing is sent.
    function checkCarried() {
        if (kind === "window" && !scene.byId[itemId]) cancel();
        else if (kind === "desk" && bar && bar.ids.indexOf(itemId) < 0) cancel();
    }

    // ---- the five methods ----------------------------------------------------
    function begin(k, id, p, from) {
        if (kind !== "" || commit || !bar || !scene.isOpen || scene.closing || scene.opBusy === true) return false;
        if (k === "window") {
            var w = scene.byId[id];
            if (!w) return false;
            fromDesk = w.desk;
            grab = from && from.grab ? from.grab : Qt.point(0.5, 0.5);
            origin = from && from.rect ? from.rect : null;
            previewOrder = [];
        } else if (k === "desk") {
            id = Number(id);
            if (bar.ownIds.length < 2 || bar.ownIds.indexOf(id) < 0) return false;
            var r = bar.tileRect(id);
            grab = from && from.grab ? from.grab : Qt.point(p.x - r.x, p.y - r.y);
            origin = null;
            fromDesk = id;
            startIds = bar.ownIds.slice();
            previewOrder = startIds.concat(bar.guestIds);
        } else return false;
        landing = null;
        target = null; offStrip = 0; keyboard = false; aimId = -1;
        gapIndex = -1; gapArmed = false;
        kind = k; itemId = id;
        startPos = p; pos = p; dragPos = p;
        quiet = true; dragId = k === "window" ? id : "desk:" + id; quiet = false;
        if (typeof scene.hideResult === "function") scene.hideResult();   // the last op's pill never reads as this drag's
        bar.takeKeys();
        update();
        return true;
    }
    function move(p) {
        if (kind === "") return;
        pos = p; dragPos = p;
        update();
    }
    function drop() {
        if (kind === "") return false;
        var op = null, t = target;
        if (kind === "window" && t) {
            if (t.type === "desk" || t.type === "grid") op = { op: "move", win: itemId, desk: t.id };
            else if (t.type === "plus") op = { op: "newdesk", win: itemId, desk: bar.plusId };
            else if (t.type === "gap") op = insertOp(t.left, t.right, itemId);
        } else if (kind === "desk" && !cancelZone) {
            op = reorderOp(previewOrder.slice(0, startIds.length), startIds);
        }
        if (!op) { cancel(); return false; }
        if (kind === "window" && t.type !== "grid") landing = { wid: itemId, rect: bar.landingRect(t, itemId) };
        commit = { op: op, ids: bar.ids.slice(), plusId: bar.plusId, snapshot: snapshot(), active: scene.activeDesk };
        end();                      // the drag is over; preview order and target stay until the model catches up
        commitTimer.restart();
        opRequested(op);
        return true;
    }
    function cancel() {
        if (kind === "") return;
        end();
        previewOrder = [];
        target = null;
        cancelled();
    }
    function liftSelected() {
        var id = scene.selectedId, g = id ? scene.layout[id] : null;
        if (!g) return false;
        if (!begin("window", id, Qt.point(g.x + g.w / 2, g.y + g.h / 2), { grab: Qt.point(0.5, 0.15) })) return false;
        keyboard = true;
        aim(fromDesk);
        return true;
    }
    function aim(deskId) {
        if (kind !== "window") return;
        keyboard = true;
        aimId = Number(deskId);
        pos = bar.aimPoint(aimId); dragPos = pos;
        update();
    }
    function step(d) {
        if (!keyboard || kind !== "window") return;
        var list = bar.ids.concat([bar.plusId]), i = list.indexOf(aimId);
        aim(list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i) + d))]);
    }
    function moveDesk(id, delta) {
        if (kind !== "" || commit || !bar) return false;
        var ids = bar.ownIds, i = ids.indexOf(Number(id)), j = i + delta;
        if (i < 0 || j < 0 || j >= ids.length) return false;
        var order = ids.slice();
        order.splice(i, 1); order.splice(j, 0, Number(id));
        var op = reorderOp(order, ids);
        if (!op) return false;
        previewOrder = order.concat(bar.guestIds);
        commit = { op: op, ids: ids.slice(), plusId: bar.plusId, snapshot: snapshot(), active: scene.activeDesk };
        commitTimer.restart();
        opRequested(op);
        return true;
    }

    // A desk reorder over the screen's own desks as positions (an empty desk is a gap that moves with the picture).
    // Nothing to send when no desk that exists changes its number (only gaps traded places: the picture is the same).
    function reorderOp(order, positions) {
        if (same(order, positions)) return null;
        for (var i = 0; i < order.length; i++)
            if (order[i] !== positions[i] && scene.deskExists(order[i])) return { op: "reorder", order: order, positions: positions.slice() };
        return null;
    }
    // A new desk in a gap: every desk from right to the last the strip shows moves up one (ovops.insert).
    function insertOp(left, right, wid) {
        var own = bar.ownIds, last = own.length ? own[own.length - 1] : undefined;
        var op = { op: "insert", left: left, right: right, win: wid };
        if (last !== undefined && right !== undefined && right !== null && right <= last) op.last = last;
        return op;
    }

    // ---- inside ----------------------------------------------------------------
    function end() {
        quiet = true;
        kind = ""; itemId = null; dragId = "";
        quiet = false;
        keyboard = false; offStrip = 0; aimId = -1;
        gapIndex = -1; gapArmed = false; gapTimer.stop();
        holdStop();
        dropDesk = -1;
        if (!commit) { previewOrder = []; target = null; }
        if (bar) bar.releaseKeys();
    }
    function update() {
        if (kind === "window") updateWindow();
        else if (kind === "desk") updateDesk();
    }
    function updateDesk() {
        var b = bar.band();
        offStrip = Math.max(0, b.top - pos.y, pos.y - b.bottom);
        // The picture is the whole strip: own desks in their new order, then the visiting desks, which never move.
        var o = (cancelZone ? startIds.slice()
                            : L.previewOrder(startIds, itemId, bar.toContent(pos.x - grab.x) + bar.tileW / 2, bar.geo))
                .concat(bar.guestIds);
        if (!same(o, previewOrder)) previewOrder = o;
    }
    function updateWindow() {
        var h;
        if (keyboard) {
            h = aimId === bar.plusId ? { type: "plus" } : { type: "desk", id: aimId };
        } else {
            h = bar.hitWindow(pos);
            if (h && h.type === "gap") {
                if (gapIndex !== h.index) { gapIndex = h.index; gapArmed = false; gapTimer.restart(); }
                if (gapArmed) { holdStop(); setTarget({ type: "gap", left: h.left, right: h.right }); return; }
                h = h.tileId >= 0 ? { type: "desk", id: h.tileId } : null;     // the tile it overlaps, until the dwell is over
            } else if (gapIndex >= 0) { gapIndex = -1; gapArmed = false; gapTimer.stop(); }
            if (h && h.type === "desk" && h.id !== scene.viewedDesk) holdOn(h.id); else holdStop();
        }
        var t = null;
        if (h && h.type === "desk") t = h.id === fromDesk ? null : { type: "desk", id: h.id };
        else if (h && h.type === "plus") t = { type: "plus" };
        else if (h && h.type === "grid") {
            var v = scene.viewedDesk;
            if (bar.ids.indexOf(v) < 0) t = { type: "plus" };          // a new desk he is looking at, not yet real
            else if (v !== fromDesk) t = { type: "grid", id: v };
        }
        setTarget(t);
    }
    function setTarget(t) {
        if (!sameTarget(t, target)) target = t;
        dropDesk = t && (t.type === "desk" || t.type === "grid") ? t.id : -1;
    }
    function holdOn(id) {
        if (holdId === id) return;
        holdId = id;
        holdProgress = 0;
        holdAnim.restart();
    }
    function holdStop() {
        if (holdId < 0) return;
        holdId = -1;
        holdAnim.stop();
        holdProgress = 0;
    }
    function holdDone() {
        if (holdId < 0 || holdProgress < 1 || kind !== "window") return;
        var id = holdId;
        holdStop();
        bar.hoverOpen(id);
        update();
    }

    // The drop is shown as done once the model says so (the real back end
    // answers within ~50 ms; the mock at once). Until then the strip keeps
    // the preview; after 600 ms without a change it lets go (the host shows
    // the failure pill and re-reads the model).
    function snapshot() {
        var m = {}, ws = scene.windows;
        for (var i = 0; i < ws.length; i++) m[ws[i].id] = ws[i].desk;
        return m;
    }
    function checkCommit() {
        if (!commit) return;
        var changed = scene.activeDesk !== commit.active, ws = scene.windows;
        for (var i = 0; !changed && i < ws.length; i++)
            if (commit.snapshot[ws[i].id] !== undefined && commit.snapshot[ws[i].id] !== ws[i].desk) changed = true;
        if (!changed && bar && !same(bar.ids, commit.ids)) changed = true;
        if (changed) finishCommit(true);
    }
    function finishCommit(applied) {
        if (!commit) return;
        var c = commit;
        commitTimer.stop();
        commit = null;
        if (bar) bar.settle(c, applied);       // reads previewOrder/target before they go
        previewOrder = [];
        target = null;
        if (bar) bar.afterCommit();
        if (!applied) landing = null;
    }

    // ---- words for logs and the test hook (ids and addresses only, never a title) ----
    function describe(op) {
        if (!op) return "";
        if (op.op === "move") return "move " + op.win + "→" + op.desk;
        if (op.op === "newdesk") return "newdesk " + op.win;
        if (op.op === "reorder") return "reorder [" + op.order.join(",") + "]";
        if (op.op === "insert") return "insert " + op.left + "|" + op.right + " " + op.win;
        return op.op;
    }
    function state() {
        return {
            kind: kind, itemId: itemId, keyboard: keyboard, target: target, previewOrder: previewOrder,
            labels: bar ? bar.labelList() : [], holdId: holdId, holdProgress: Math.round(holdProgress * 100) / 100,
            gapIndex: gapIndex, gapArmed: gapArmed, offStrip: Math.round(offStrip), cancelZone: cancelZone,
            committing: commit !== null, landing: landing ? landing.wid : "", viewedDesk: scene.viewedDesk,
            captures: bar ? bar.captureCount : -1, scroll: bar ? Math.round(bar.scrollX) : 0
        };
    }
    function drive(k, id, x, y, phase) {
        var p = Qt.point(x, y), ok = true;
        if (phase === "begin") ok = begin(k, k === "desk" ? Number(id) : id, p);
        else if (phase === "pick") ok = bar.pickFromMini(id, p);
        else if (phase === "move") move(p);
        else if (phase === "drop") ok = drop();
        else if (phase === "cancel") cancel();
        else if (phase === "lift") { if (id) scene.selectedId = id; ok = liftSelected(); }
        else if (phase === "aim") aim(Number(id));
        else if (phase === "step") step(x);
        else if (phase === "movedesk") ok = moveDesk(Number(id), x);
        var s = state();
        s.ok = ok !== false;
        return JSON.stringify(s);
    }

    function same(a, b) {
        if (!a || !b || a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }
    function sameTarget(a, b) {
        if (!a || !b) return a === b;
        return a.type === b.type && a.id === b.id && a.left === b.left && a.right === b.right;
    }
}
