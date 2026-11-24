// The bar's empty desks in the overview, driven through the REAL pointer and keyboard paths of a real Scene
// (DeskTile/WindowCard DragHandlers, TapHandlers, Keys), off-screen, no compositor:
//   /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_emptydesks.qml
// His desktop on 2026-11-19: windows on desks 1 2 3 5 6, desk 4 empty; the bar lists 1 2 3 4 5 6. The desks come
// from Desks.strip (the same call shell.qml makes); ops are answered by a stand-in that does what ops/ovops.lua does
// (an empty desk does not exist: Hyprland has nothing to renumber or keep), then the strip is rebuilt from it.
import QtQuick
import QtTest
import "../.."
import "../../Desks.js" as D

Item {
    id: root
    width: 1200
    height: 750

    // the "compositor": window -> desk, the active desk
    property var where: ({})
    property int active: 3
    function startState() {
        where = { "0xa1": 1, "0xa2": 2, "0xa3": 3, "0xa4": 3, "0xa5": 5, "0xa6": 6 };
        active = 3;
    }
    function existing() {
        var s = {}; for (var k in where) s[where[k]] = true; s[active] = true;
        return Object.keys(s).map(Number).sort(function (a, b) { return a - b; });
    }
    property var wins: {
        var out = [], ks = Object.keys(where).sort();
        for (var i = 0; i < ks.length; i++)
            out.push({ id: ks[i], desk: where[ks[i]], x: 8 + (i % 2) * 590, y: 30, w: 580, h: 700, title: "Test", label: "Test", app: "App", icon: "", agent: "", focusRank: i });
        return out;
    }
    property var desks: {
        var info = {};
        for (var i = 0; i < wins.length; i++) { var d = wins[i].desk; info[d] = info[d] || { name: "App", waiting: 0, count: 0 }; info[d].count++; }
        var facts = { slots: 10, blocks: { "eDP-1": 0 }, screens: [{ name: "eDP-1", shown: active }],
                      desks: existing().map(function (id) { return { id: id, screen: "eDP-1" }; }).concat(guest ? [{ id: 21, screen: "eDP-1" }] : []) };
        return D.strip(facts, "eDP-1", info);
    }
    property bool guest: false       // a visiting desk (21, another block's number) sits on this screen
    property var sent: []
    property int seq: 0
    property var chosen: []

    // What ovops.lua does with each op (a position with no desk is a gap: nothing to move).
    function apply(op) {
        var w = Object.assign({}, where), a = active, i;
        if (op.op === "move" || op.op === "newdesk") w[op.win] = op.desk;
        else if (op.op === "reorder") {
            var m = {};
            for (i = 0; i < op.order.length; i++) m[op.order[i]] = op.positions[i];
            for (var k in w) if (m[w[k]] !== undefined) w[k] = m[w[k]];
            if (m[a] !== undefined) a = m[a];
        } else if (op.op === "insert") {
            for (var k2 in w) if (w[k2] >= op.right && w[k2] <= op.last) w[k2]++;
            if (a >= op.right && a <= op.last) a++;
            w[op.win] = op.right;
        }
        where = w; active = a;
    }
    Scene {
        id: sc
        width: root.width
        height: root.height
        windows: root.wins
        desks: root.desks
        activeDesk: root.active
        onOperate: function (op) {
            var n = ++root.seq, c = JSON.parse(JSON.stringify(op));
            delete c.tag;
            root.sent = root.sent.concat([c]);
            sc.opSent(op.tag, n);
            Qt.callLater(function () { root.apply(c); Qt.callLater(function () { sc.opDone(n, true, ""); }); });
        }
        onActivateDesk: function (id) { root.chosen = root.chosen.concat([id]); }
    }

    TestCase {
        name: "EmptyDesks"
        when: windowShown

        function init() {
            sc.snapShut();
            root.startState();
            wait(700);
            root.sent = []; root.chosen = [];
        }
        function cleanup() { root.guest = false; }
        function waitSettled() { tryVerify(function () { return sc.settled; }, 2000, "settled"); }
        function openAndFocus() { sc.open(); waitSettled(); sc.forceActiveFocus(); wait(50); }
        function card(id) { var c = sc.cardRects(); for (var i = 0; i < c.length; i++) if (c[i].id === id) return { x: c[i].x + c[i].w / 2, y: c[i].y + c[i].h / 2 }; return null; }
        function tile(id) { var t = sc.tileRects(); for (var i = 0; i < t.length; i++) if (id === "plus" ? t[i].plus : (!t[i].plus && t[i].id === id)) return { x: t[i].x + t[i].w / 2, y: t[i].y + t[i].h / 2, r: t[i] }; return null; }
        function glide(a, b, n) { for (var i = 1; i <= n; i++) mouseMove(sc, a.x + (b.x - a.x) * i / n, a.y + (b.y - a.y) * i / n, 16, Qt.LeftButton); }
        function canon(o) { if (!o) return "null"; var r = {}; Object.keys(o).sort().forEach(function (k) { r[k] = o[k]; }); return JSON.stringify(r); }
        function lastOp() { return root.sent.length ? root.sent[root.sent.length - 1] : null; }
        function mapText() { var k = Object.keys(root.where).sort(); return k.map(function (x) { return x.slice(3) + "=" + root.where[x]; }).join(" "); }
        function stripIds() { return JSON.stringify(sc.tileRects().map(function (t) { return t.plus ? "+" + t.id : t.id; })); }
        function key(k, mods) { keyClick(k, mods || Qt.NoModifier); wait(80); }
        function waitOps(n) { tryVerify(function () { return root.sent.length >= n && !sc.opBusy; }, 2000, n + " op(s) answered"); wait(120); }

        // Review blocker: with a visiting desk listed, the carried picture must still show the reorder that the drop sends.
        function test_visiting_desk_drag_preview_shows_the_reorder() {
            root.guest = true; wait(50);
            openAndFocus();
            compare(stripIds(), '[1,2,3,4,5,6,21,"+7"]', "the visiting desk is listed last, as in the bar");
            var a = tile(2), five = tile(5), six = tile(6);
            var to = { x: (five.r.x + five.r.w + six.r.x) / 2, y: a.y + 6 };
            mousePress(sc, a.x, a.y); glide(a, to, 24); wait(60);
            compare(JSON.stringify(sc.dragController.bar.order), "[1,3,4,5,2,6,21]", "the picture while carrying shows the reorder");
            mouseRelease(sc, to.x, to.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "reorder", order: [1, 3, 4, 5, 2, 6], positions: [1, 2, 3, 4, 5, 6] }), "the drop sends what the picture showed");
            // carried off the strip (cancel zone): the picture is the start, the visiting desk still last, nothing sent
            root.sent = [];
            var b = tile(3);
            mousePress(sc, b.x, b.y); glide(b, { x: b.x, y: b.y + 400 * sc.dragController.bar.u }, 20); wait(60);
            verify(sc.dragController.cancelZone, "in the cancel zone");
            compare(JSON.stringify(sc.dragController.previewOrder), JSON.stringify(sc.dragController.bar.ids), "cancel zone: the start order, visiting desk included");
            mouseRelease(sc, b.x, b.y + 400 * sc.dragController.bar.u); wait(400);
            compare(root.sent.length, 0, "nothing sent from the cancel zone");
        }

        // Review major: an empty desk reads as empty at a glance: quieted by the theme's ground (not plain opacity)
        // and one bold "Empty" pill on its face; a desk with windows has neither; a drop target hides the pill.
        function shown(name) {
            var out = {}, stack = [sc];
            while (stack.length) {
                var it = stack.pop();
                if (it.objectName === name && it.opacity > 0.5 && it.visible) {
                    var t = it; while (t && t.deskId === undefined) t = t.parent;
                    if (t && !t.isPlus) out[t.deskId] = true;
                }
                for (var i = 0; i < it.children.length; i++) stack.push(it.children[i]);
            }
            return JSON.stringify(Object.keys(out).map(Number).sort());
        }
        function test_empty_desk_reads_empty() {
            openAndFocus(); wait(300);
            compare(shown("emptyBadge"), "[4]", "only the empty desk carries the Empty pill");
            compare(shown("emptyScrim"), "[4]", "only the empty desk is quieted");
            var a = card("0xa3"), b = tile(4);
            mousePress(sc, a.x, a.y); glide(a, { x: a.x, y: a.y - 40 }, 4); glide({ x: a.x, y: a.y - 40 }, b, 14); wait(300);
            compare(shown("emptyBadge"), "[]", "the drop target shows the landing, not the pill");
            compare(shown("emptyScrim"), "[]", "and wakes to full strength");
            mouseRelease(sc, a.x, a.y + 2000); wait(400);
        }
        function test_one_desk_in_use_four_quiet_desks() {
            root.where = { "0xa1": 1 }; root.active = 1; wait(100);
            openAndFocus(); wait(300);
            compare(stripIds(), '[1,2,3,4,5,"+6"]');
            compare(shown("emptyBadge"), "[2,3,4,5]");
            compare(shown("emptyScrim"), "[2,3,4,5]");
        }

        function test_strip_lists_the_bars_desks() {
            openAndFocus();
            compare(stripIds(), '[1,2,3,4,5,6,"+7"]', "the bar's desks, empty 4 included, then New desk (7)");
            compare(JSON.stringify(sc.dragController.bar.labelList()), "[1,2,3,4,5,6]");
            var four = sc.desks[3];
            verify(four.id === 4 && four.count === 0 && four.exists === false && four.name === "Empty", "desk 4 is an empty desk the compositor does not hold");
        }

        function test_window_dropped_on_empty_desk_then_undo() {
            openAndFocus();
            var a = card("0xa3"), b = tile(4);
            mousePress(sc, a.x, a.y); glide(a, { x: a.x, y: a.y - 40 }, 4); glide({ x: a.x, y: a.y - 40 }, b, 14); wait(100);
            compare(sc.dragController.target ? sc.dragController.target.id : -1, 4, "empty desk 4 is the drop target");
            mouseRelease(sc, b.x, b.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "move", win: "0xa3", desk: 4 }));
            compare(mapText(), "1=1 2=2 3=4 4=3 5=5 6=6", "window 3 now on desk 4");
            compare(sc.pillState().text, "Moved"); verify(sc.pillState().undo, "Undo offered");
            key(Qt.Key_Z, Qt.ControlModifier); waitOps(2);
            compare(canon(lastOp()), canon({ op: "move", win: "0xa3", desk: 3 }), "Undo moves it back");
            compare(mapText(), "1=1 2=2 3=3 4=3 5=5 6=6");
            compare(stripIds(), '[1,2,3,4,5,6,"+7"]', "desk 4 empty again, its tile still there");
        }

        function test_desk_2_to_position_5_and_back_with_the_gap() {
            openAndFocus();
            var a = tile(2), five = tile(5), six = tile(6);
            var to = { x: (five.r.x + five.r.w + six.r.x) / 2, y: a.y + 6 };
            mousePress(sc, a.x, a.y); glide(a, to, 24); wait(60);
            compare(JSON.stringify(sc.dragController.previewOrder), "[1,3,4,5,2,6]", "picture while carrying: 1 3 [4] 5 2 6");
            compare(JSON.stringify(sc.dragController.bar.labelList()), "[1,2,3,4,5,6]", "pills are positions");
            mouseRelease(sc, to.x, to.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "reorder", order: [1, 3, 4, 5, 2, 6], positions: [1, 2, 3, 4, 5, 6] }));
            // as the picture: old 3 -> 2, the gap (4) -> 3, old 5 -> 4, old 2 -> 5; 1 and 6 untouched
            compare(mapText(), "1=1 2=5 3=2 4=2 5=4 6=6");
            compare(root.active, 2, "the active desk followed its desk");
            compare(stripIds(), '[1,2,3,4,5,6,"+7"]', "the gap moved to 3; still six desks");
            compare(sc.desks[2].count, 0, "desk 3 is now the empty one");
            // and back: the desk at position 5 to position 2
            var b = tile(5), one = tile(1), two = tile(2);
            var back = { x: (one.r.x + one.r.w + two.r.x) / 2, y: b.y + 6 };
            mousePress(sc, b.x, b.y); glide(b, back, 24); wait(60);
            compare(JSON.stringify(sc.dragController.previewOrder), "[1,5,2,3,4,6]");
            mouseRelease(sc, back.x, back.y); waitOps(2);
            compare(canon(lastOp()), canon({ op: "reorder", order: [1, 5, 2, 3, 4, 6], positions: [1, 2, 3, 4, 5, 6] }));
            compare(mapText(), "1=1 2=2 3=3 4=3 5=5 6=6", "the start exactly");
            compare(root.active, 3);
        }

        function test_empty_desk_carried_moves_the_gap_and_undo() {
            openAndFocus();
            var a = tile(4), one = tile(1);
            var to = { x: one.r.x + 4, y: a.y + 6 };
            mousePress(sc, a.x, a.y); glide(a, to, 24); wait(60);
            compare(JSON.stringify(sc.dragController.previewOrder), "[4,1,2,3,5,6]");
            mouseRelease(sc, to.x, to.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "reorder", order: [4, 1, 2, 3, 5, 6], positions: [1, 2, 3, 4, 5, 6] }));
            compare(mapText(), "1=2 2=3 3=4 4=4 5=5 6=6", "the gap is now desk 1");
            compare(sc.desks[0].count, 0);
            key(Qt.Key_Z, Qt.ControlModifier); waitOps(2);
            compare(canon(lastOp()), canon({ op: "reorder", order: [2, 3, 4, 1, 5, 6], positions: [1, 2, 3, 4, 5, 6] }), "Undo: the inverse over the same positions");
            compare(mapText(), "1=1 2=2 3=3 4=3 5=5 6=6");
        }

        function test_two_gaps_trading_places_send_nothing() {
            root.where = { "0xa1": 1, "0xa2": 2, "0xa3": 3 }; root.active = 1; wait(50);
            openAndFocus();
            compare(stripIds(), '[1,2,3,4,5,"+6"]');
            var a = tile(4), five = tile(5);
            var to = { x: five.r.x + five.r.w - 4, y: a.y + 6 };
            mousePress(sc, a.x, a.y); glide(a, to, 20); wait(60);
            compare(JSON.stringify(sc.dragController.previewOrder), "[1,2,3,5,4]");
            mouseRelease(sc, to.x, to.y); wait(200);
            compare(root.sent.length, 0, "only empty desks moved: the picture is the same, nothing sent");
        }

        function test_choose_empty_desk_pointer_and_keyboard() {
            openAndFocus();
            var t = tile(4);
            mouseClick(sc, t.x, t.y); wait(400);
            compare(sc.viewedDesk, 4, "a click views the empty desk");
            verify(sc.gridOrder.length === 0, "its grid is empty");
            key(Qt.Key_Return);
            compare(JSON.stringify(root.chosen), "[4]", "Enter goes to the viewed empty desk");
            sc.snapShut(); root.chosen = []; openAndFocus();
            key(Qt.Key_4, Qt.ControlModifier); wait(300);
            compare(sc.viewedDesk, 4, "Ctrl+4 views it");
            sc.snapShut(); root.chosen = []; openAndFocus();
            // control: a desk with windows, the same gesture
            t = tile(5);
            mouseClick(sc, t.x, t.y); wait(60); mouseClick(sc, t.x, t.y); wait(400);
            var ctl = JSON.stringify(root.chosen);
            sc.snapShut(); root.chosen = []; openAndFocus();
            t = tile(4);
            mouseClick(sc, t.x, t.y); wait(60); mouseClick(sc, t.x, t.y); wait(400);
            // Off-screen, two clicks never reach TapHandler.doubleTapped, on a desk with windows either (the control):
            // a finding for main, not of empty desks. Pinned: the empty desk answers exactly as the control does.
            compare(JSON.stringify(root.chosen), ctl === "[5]" ? "[4]" : ctl, "double-click on the empty desk = on desk 5 (" + ctl + ")");
        }

        function test_hover_hold_on_empty_desk_then_drop_on_its_grid() {
            openAndFocus();
            var a = card("0xa4"), b = tile(4);
            mousePress(sc, a.x, a.y); glide(a, { x: a.x, y: a.y - 40 }, 4); glide({ x: a.x, y: a.y - 40 }, b, 14);
            tryVerify(function () { return sc.viewedDesk === 4; }, 1500, "hover-hold pages to the empty desk");
            var g = { x: sc.width / 2, y: sc.height * 0.7 };
            glide(b, g, 12); wait(80);
            compare(sc.dragController.target ? sc.dragController.target.type + sc.dragController.target.id : "", "grid4", "its grid is the target");
            mouseRelease(sc, g.x, g.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "move", win: "0xa4", desk: 4 }));
        }

        function test_keyboard_moves_to_empty_desk() {
            openAndFocus();
            sc.selectedId = "0xa3"; sc.showSelection = true;
            key(Qt.Key_Right, Qt.ControlModifier | Qt.ShiftModifier); waitOps(1);
            compare(canon(lastOp()), canon({ op: "move", win: "0xa3", desk: 4 }), "Ctrl+Shift+Right: desk 3 -> the next desk the bar shows, 4");
            key(Qt.Key_Z, Qt.ControlModifier); waitOps(2);
            sc.selectedId = "0xa3"; sc.showSelection = true;
            key(Qt.Key_Space); key(Qt.Key_Right); wait(50);
            compare(sc.dragController.target ? sc.dragController.target.id : -1, 4, "keyboard drag: the arrow aims at desk 4");
            key(Qt.Key_Return); waitOps(3);
            compare(canon(lastOp()), canon({ op: "move", win: "0xa3", desk: 4 }));
        }

        function test_new_desk_is_beyond_the_shown_ones() {
            root.where = { "0xa1": 1, "0xa2": 2, "0xa3": 3 }; root.active = 3; wait(50);
            openAndFocus();
            compare(stripIds(), '[1,2,3,4,5,"+6"]');
            var a = card("0xa3"), p = tile("plus");
            mousePress(sc, a.x, a.y); glide(a, { x: a.x, y: a.y - 40 }, 4); glide({ x: a.x, y: a.y - 40 }, p, 14); wait(100);
            mouseRelease(sc, p.x, p.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "newdesk", win: "0xa3", desk: 6 }), "New desk is 6, after the shown 5");
        }

        function test_insert_bar_shifts_up_to_the_last_shown() {
            openAndFocus();
            var a = card("0xa3"), one = tile(1), two = tile(2);
            var g = { x: (one.r.x + one.r.w + two.r.x) / 2, y: one.y };
            mousePress(sc, a.x, a.y); glide(a, { x: a.x, y: a.y - 40 }, 4); glide({ x: a.x, y: a.y - 40 }, g, 14);
            tryVerify(function () { return sc.dragController.target && sc.dragController.target.type === "gap"; }, 1000, "the gap arms");
            mouseRelease(sc, g.x, g.y); waitOps(1);
            compare(canon(lastOp()), canon({ op: "insert", left: 1, right: 2, win: "0xa3", last: 6 }));
            compare(mapText(), "1=1 2=3 3=2 4=4 5=6 6=7", "new 2; old 2-3 up one; the gap moves to 5; old 5-6 up one");
        }

        function test_swipe_and_enter_empty_and_new_desk() {
            // 1. 2-finger horizontal swipe reaches "+ New desk" (desk 7) from desk 6.
            root.active = 6; wait(50);
            openAndFocus();
            compare(sc.viewedDesk, 6);
            for (var i = 0; i < 12; i++) { sc.scrollBy(-root.width / 30 * 1.1); wait(10); }
            sc.scrollRelease();
            waitSettled();
            compare(sc.viewedDesk, 7, "2-finger swipe reaches + New desk (7)");
            verify(sc.gridOrder.length === 0, "new desk grid is empty");

            // 2. Clicking the empty backdrop switches into the viewed new desk (7) instead of cancelling back to 6.
            mouseClick(sc, sc.width / 2, sc.height * 0.72);
            tryVerify(function () { return !sc.isOpen; }, 1500, "overview closes into new desk");
            compare(JSON.stringify(root.chosen), "[7]", "backdrop click enters new desk 7");

            // 3. Tapping + New desk once views it; tapping it again enters it.
            root.chosen = [];
            openAndFocus();
            var p = tile("plus");
            mouseClick(sc, p.x, p.y); waitSettled();
            compare(sc.viewedDesk, 7, "first tap on + New desk views desk 7");
            compare(JSON.stringify(root.chosen), "[]", "first tap previews without leaving yet");
            mouseClick(sc, p.x, p.y);
            tryVerify(function () { return !sc.isOpen; }, 1500, "second tap on + New desk enters desk 7");
            compare(JSON.stringify(root.chosen), "[7]", "second tap enters new desk 7");

            // 4. Viewing an empty desk (4) and closing with 3-finger swipe down enters desk 4; Esc still cancels.
            root.active = 3; root.chosen = []; wait(50);
            openAndFocus();
            var t4 = tile(4);
            mouseClick(sc, t4.x, t4.y); waitSettled();
            compare(sc.viewedDesk, 4);
            var t0 = Date.now();
            sc.strokeBegin(3, "DOWN", 0, t0);
            for (var j = 1; j <= 10; j++) { wait(12); sc.strokeUpdate(-2.6 * j, t0 + j * 12); }
            sc.strokeEnd(-26, t0 + 130, false);
            tryVerify(function () { return !sc.isOpen; }, 1500, "3-finger swipe down closes overview");
            compare(JSON.stringify(root.chosen), "[4]", "3-finger swipe down enters viewed empty desk 4");

            // 5. Esc on a viewed empty desk still cancels back without switching.
            root.chosen = [];
            openAndFocus();
            mouseClick(sc, t4.x, t4.y); waitSettled();
            compare(sc.viewedDesk, 4);
            key(Qt.Key_Escape);
            tryVerify(function () { return !sc.isOpen; }, 1500, "Esc closes overview");
            compare(JSON.stringify(root.chosen), "[]", "Esc cancels without switching desks");
        }

        function findByObjectName(item, name) {
            var stack = [item];
            while (stack.length) {
                var cur = stack.pop();
                if (cur && cur.objectName === name) return cur;
                if (cur && cur.children) {
                    for (var i = 0; i < cur.children.length; i++) stack.push(cur.children[i]);
                }
            }
            return null;
        }

        function test_power_shortcuts_ctrl_digits_ctrl_n_and_search_coexistence() {
            openAndFocus();
            compare(sc.viewedDesk, 3);

            // Bottom Liquid Glass hint pill is visible at subtle low visual weight when settled and idle.
            var hint = findByObjectName(sc, "interactionHintPill");
            verify(hint !== null, "interactionHintPill exists");
            tryVerify(function () { return hint.visible && Math.abs(hint.opacity - 0.62) < 0.03; }, 800,
                      "hint pill settles at 0.62 opacity when idle (got " + hint.opacity + ")");

            // 1. Ctrl+1..9 switches viewedDesk smoothly (including empty desk 4); second press enters it.
            key(Qt.Key_1, Qt.ControlModifier); waitSettled();
            compare(sc.viewedDesk, 1, "Ctrl+1 jumps to desk 1");
            verify(sc.isOpen && !sc.closing, "first Ctrl+1 stays open");
            key(Qt.Key_4, Qt.ControlModifier); waitSettled();
            compare(sc.viewedDesk, 4, "Ctrl+4 jumps to empty desk 4");
            verify(sc.gridOrder.length === 0, "empty desk 4 grid is empty");
            key(Qt.Key_4, Qt.ControlModifier);
            tryVerify(function () { return !sc.isOpen; }, 1500, "second Ctrl+4 enters empty desk 4");
            compare(JSON.stringify(root.chosen), "[4]", "second Ctrl+4 activates desk 4");

            // 2. Ctrl+Left / Ctrl+Right glides across desks (including empty desk 4 and + New desk 7).
            root.chosen = [];
            openAndFocus();
            compare(sc.viewedDesk, 3);
            key(Qt.Key_Right, Qt.ControlModifier); waitSettled();
            compare(sc.viewedDesk, 4, "Ctrl+Right steps into empty desk 4");
            key(Qt.Key_Left, Qt.ControlModifier); waitSettled();
            compare(sc.viewedDesk, 3, "Ctrl+Left steps back to desk 3");

            // 3. Ctrl+N jumps straight to "+ New desk" (7); second Ctrl+N opens fresh empty desk 7.
            key(Qt.Key_N, Qt.ControlModifier); waitSettled();
            compare(sc.viewedDesk, 7, "Ctrl+N jumps to + New desk (7)");
            verify(sc.isOpen && !sc.closing && sc.gridOrder.length === 0, "first Ctrl+N views new desk 7");
            key(Qt.Key_N, Qt.ControlModifier);
            tryVerify(function () { return !sc.isOpen; }, 1500, "second Ctrl+N enters fresh empty desk 7");
            compare(JSON.stringify(root.chosen), "[7]", "second Ctrl+N activates new desk 7");

            // 4. Instant type-to-search (bare digits & letters) works with zero conflict and hides the hint pill;
            //    Ctrl+4 while searching clears query and jumps cleanly to desk 4.
            root.chosen = [];
            openAndFocus();
            keyClick(Qt.Key_1);
            keyClick(Qt.Key_H);
            keyClick(Qt.Key_T);
            wait(60);
            compare(sc.query, "1ht", "bare digits and letters start instant search seamlessly");
            tryVerify(function () { return hint.opacity < 0.02; }, 800, "hint pill fades out while searching");
            key(Qt.Key_4, Qt.ControlModifier); waitSettled();
            compare(sc.query, "", "Ctrl+4 clears active search query");
            compare(sc.viewedDesk, 4, "Ctrl+4 jumps to desk 4 after clearing search");

            // 5. Ctrl+Shift+1..9 and Ctrl+Shift+N still move windows without conflict, and ResultPill hides the hint pill.
            key(Qt.Key_3, Qt.ControlModifier); waitSettled();
            sc.selectedId = "0xa3"; sc.showSelection = true;
            key(Qt.Key_Percent, Qt.ControlModifier | Qt.ShiftModifier); waitOps(1);   // Ctrl+Shift+5 (US '%')
            compare(canon(lastOp()), canon({ op: "move", win: "0xa3", desk: 5 }), "Ctrl+Shift+5 moves selected window to desk 5");
            verify(sc.pillState() !== null && sc.pillState().text === "Moved", "ResultPill is up");
            tryVerify(function () { return hint.opacity < 0.02; }, 800, "hint pill fades out while ResultPill is shown");

            sc.selectedId = "0xa4"; sc.showSelection = true;
            key(Qt.Key_N, Qt.ControlModifier | Qt.ShiftModifier); waitOps(2);
            compare(canon(lastOp()), canon({ op: "newdesk", win: "0xa4", desk: 7 }), "Ctrl+Shift+N moves selected window to new desk 7");
        }
    }
}
