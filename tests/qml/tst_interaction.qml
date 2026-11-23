// Review tests (adversarial reviewer, interaction share): user actions of SPEC section 2 driven through the
// REAL pointer and keyboard paths of a real Scene (WindowCard/DeskTile DragHandlers, MouseAreas, Keys), not the
// drag test hook. Off-screen, no compositor, no Quickshell:
//   /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_interaction.qml
// Tests named test_DEFECT_* reproduce a defect found in review and are expected to FAIL on main bddd4c7; the
// others pin behaviour that works and must keep working.
import QtQuick
import QtTest
import "../.."
import "../../Gesture.js" as G

Item {
    id: root
    width: 1200
    height: 750

    property var fakeWindows: {
        var w = [], id = 0;
        function add(desk, x, y, ww, hh, rank) { w.push({ id: "0xa" + (id++), desk: desk, x: x, y: y, w: ww, h: hh, title: "Test", label: "Test", app: "App", icon: "", agent: "", focusRank: rank }); }
        add(1, 8, 30, 580, 700, 3); add(2, 8, 30, 1180, 700, 2); add(3, 8, 30, 580, 700, 0); add(3, 600, 30, 580, 700, 1); add(4, 8, 30, 1180, 700, 4);
        return w;
    }
    property var fakeDesks: [{ id: 1, name: "App", isNew: false, waiting: 0, count: 1 }, { id: 2, name: "App", isNew: false, waiting: 0, count: 1 },
                             { id: 3, name: "App", isNew: false, waiting: 0, count: 2 }, { id: 4, name: "App", isNew: false, waiting: 0, count: 1 },
                             { id: 5, name: "New desk", isNew: true, waiting: 0, count: 0 }]
    property var sent: []          // ops the scene asked the "host" to run, each stamped with whether the button was down
    property bool buttonDown: false
    property int seq: 0
    Scene {
        id: sc
        width: root.width
        height: root.height
        windows: root.fakeWindows
        desks: root.fakeDesks
        activeDesk: 3
        onOperate: function (op) {
            var n = ++root.seq, c = JSON.parse(JSON.stringify(op));
            delete c.tag; c.seq = n; c.whileButtonDown = root.buttonDown;
            var s = root.sent.slice(); s.push(c); root.sent = s;
            sc.opSent(op.tag, n);
            // no answer: the model never changes in this harness, so the drag controller's commit lets go after 600 ms
        }
    }

    TestCase {
        name: "Interaction"
        when: windowShown

        function init() {
            if (root.buttonDown) { mouseRelease(sc, 5, 745, Qt.LeftButton); root.buttonDown = false; }
            sc.snapShut();
            sc.windows = root.fakeWindows; sc.desks = root.fakeDesks; sc.activeDesk = 3;
            wait(700);                       // any commit from the previous test lets go
            root.sent = [];
        }
        function waitSettled(ms) { tryVerify(function () { return sc.settled; }, ms || 2000, "settled"); }
        function openAndFocus() { sc.open(); waitSettled(); sc.forceActiveFocus(); wait(50); }
        function card(id) { var c = sc.cardRects(); for (var i = 0; i < c.length; i++) if (c[i].id === id) return { x: c[i].x + c[i].w / 2, y: c[i].y + c[i].h / 2 }; return null; }
        function tile(id) { var t = sc.tileRects(); for (var i = 0; i < t.length; i++) if (id === "plus" ? t[i].plus : (!t[i].plus && t[i].id === id)) return { x: t[i].x + t[i].w / 2, y: t[i].y + t[i].h / 2, r: t[i] }; return null; }
        function press(p) { mousePress(sc, p.x, p.y, Qt.LeftButton); root.buttonDown = true; }
        function release(p) { root.buttonDown = false; mouseRelease(sc, p.x, p.y, Qt.LeftButton); }
        function glide(a, b, n) { for (var i = 1; i <= n; i++) mouseMove(sc, a.x + (b.x - a.x) * i / n, a.y + (b.y - a.y) * i / n, 16, Qt.LeftButton); }
        function opsText() { return JSON.stringify(root.sent.map(function (o) { return sc.dragController.describe(o) + (o.whileButtonDown ? " (button still down)" : ""); })); }

        // ---- pinned behaviour: the real pointer paths work ----------------------------------------------

        function test_pointer_card_to_tile_moves_once_on_release() {
            openAndFocus();
            var a = card("0xa2"), b = tile(4);
            verify(a && b, "card and tile found");
            press(a); glide(a, { x: a.x, y: a.y - 40 }, 4);
            compare(sc.dragController.kind, "window", "the card lifted after the threshold");
            glide({ x: a.x, y: a.y - 40 }, b, 12);
            wait(100);
            compare(root.sent.length, 0, "nothing is sent while the button is down");
            release(b); wait(50);
            compare(opsText(), JSON.stringify(["move 0xa2→4"]));
            verify(sc.isOpen && !sc.closing, "a drop keeps the overview open (the card's click does not also 'choose')");
        }

        function test_pointer_card_to_plus_makes_a_new_desk() {
            openAndFocus();
            var a = card("0xa3"), b = tile("plus");
            press(a); glide(a, b, 16); wait(80);
            release(b); wait(50);
            compare(opsText(), JSON.stringify(["newdesk 0xa3"]));
        }

        function test_pointer_desk_2_past_4_reorders() {
            openAndFocus();
            var a = tile(2), four = tile(4), plus = tile("plus");
            var to = { x: (four.x + four.r.w / 2 + plus.r.x) / 2, y: a.y + 6 };
            press(a); glide(a, to, 20); wait(60);
            compare(JSON.stringify(sc.dragController.previewOrder), "[1,3,4,2]", "live preview order");
            compare(JSON.stringify(sc.dragController.bar.labelList()), "[1,2,3,4]", "pills relabel live (numbers are positions)");
            release(to); wait(50);
            compare(opsText(), JSON.stringify(["reorder [1,3,4,2]"]));
        }

        function test_pointer_desk_released_far_below_the_strip_sends_nothing() {
            openAndFocus();
            var a = tile(2), to = { x: tile(4).x, y: a.y + 400 };
            press(a); glide(a, { x: a.x + 30, y: a.y }, 4); glide({ x: a.x + 30, y: a.y }, to, 16); wait(60);
            verify(sc.dragController.cancelZone, "past 140 u: cancel zone");
            release(to); wait(50);
            compare(root.sent.length, 0, "cancel sends nothing: " + opsText());
        }

        // SPEC 2.5 "Pick up ... from a window inside any tile miniature". DeskTile decides window-or-desk from
        // DragHandler.translation inside onActiveChanged, but Qt 6.12 reports translation (0,0) at that moment
        // (probe: a 60 px straight-down drag logs "on 0,0"), so pullsDown is always false: with 2+ desks a pull
        // down always lifts the DESK. The stage only ever drove this through the IPC "pick" phase.
        function test_DEFECT_pointer_window_out_of_a_miniature_to_another_desk() {
            openAndFocus();
            var t4 = tile(4).r, a = { x: t4.x + t4.w * 0.5, y: t4.y + t4.h * 0.5 }, b = tile(2);
            press(a); glide(a, { x: a.x, y: a.y + 60 }, 6);              // pulled down: the window, not the desk
            compare(sc.dragController.kind, "window", "a pull down out of the miniature carries the window");
            compare(String(sc.dragController.itemId), "0xa4");
            glide({ x: a.x, y: a.y + 60 }, b, 16); wait(80);
            release(b); wait(50);
            compare(opsText(), JSON.stringify(["move 0xa4→2"]));
        }

        function test_overview_closing_mid_drag_sends_nothing() {
            openAndFocus();
            var a = card("0xa2"), b = tile(4);
            press(a); glide(a, { x: a.x, y: a.y - 40 }, 4);
            compare(sc.dragController.kind, "window");
            sc.close("back");                                            // Esc, a 3-finger close, the toggle key...
            glide({ x: a.x, y: a.y - 40 }, b, 8);
            release(b); wait(50);
            compare(root.sent.length, 0, "a drag does not survive the overview closing: " + opsText());
        }

        // ---- defects --------------------------------------------------------------------------------------

        // SPEC 2.5: "Hover-hold 750 ms over a tile pages the grid to that desk; then dropping anywhere on the grid
        // moves it there." The card's DragHandler is enabled only while scene.settled (and while the card is in the
        // grid); the page turn makes both false, and Qt deactivates a disabled active handler on the NEXT pointer
        // event, so WindowCard's onActiveChanged calls drop() while the button is still held: the window is moved to
        // the held desk the moment the hand moves on, wherever it was going.
        function test_DEFECT_hover_hold_then_move_on_drops_early() {
            openAndFocus();
            var a = card("0xa2"), t2 = tile(2), t4 = tile(4);
            press(a); glide(a, t2, 16);
            compare(sc.dragController.kind, "window");
            wait(1000);                                                  // hover-hold fills (750 ms) and pages to desk 2
            compare(sc.viewedDesk, 2, "hover-hold paged the grid to desk 2");
            glide(t2, t4, 10); wait(100);                                // he changes his mind and carries it on to desk 4
            var tgt = sc.dragController.target;
            verify(tgt && tgt.type === "desk" && tgt.id === 4, "the carried card follows the hand after a hover-hold (target " + JSON.stringify(tgt) + ", pos " + sc.dragController.pos + ")");
            var before = opsText();
            release(t4); wait(50);
            compare(before, "[]", "no op may be sent while the button is still down");
            compare(opsText(), JSON.stringify(["move 0xa2→4"]), "the op goes where he let go");
        }

        // Passes only by accident: after the hold the target is frozen on the held desk, which is also where a grid drop goes.
        function test_hover_hold_then_drop_on_the_grid() {
            openAndFocus();
            var a = card("0xa2"), t2 = tile(2), grid = { x: root.width / 2, y: root.height * 0.7 };
            press(a); glide(a, t2, 16);
            wait(1000);
            compare(sc.viewedDesk, 2);
            glide(t2, grid, 10); wait(100);
            compare(sc.dragController.kind, "window", "still carrying over the paged grid");
            release(grid); wait(50);
            compare(opsText(), JSON.stringify(["move 0xa2→2"]), "one move, sent at release");
        }

        // SPEC §0 L4: a stroke ends by e, a new b, configreloaded, the socket lost, "plus Esc; test all of them".
        // Keys.onPressed swallows every key while tracking, and close() returns while tracking: if a stroke's "e"
        // never arrives, a half-open overview that holds the keyboard (a closing stroke keeps committedOpen, so the
        // host keeps Exclusive focus and a full input mask) can only be left by another swipe.
        function test_DEFECT_esc_ends_a_live_stroke() {
            openAndFocus();
            sc.strokeBegin(3, "DOWN", 0, Date.now());
            sc.strokeUpdate(-7, Date.now());                             // fingers rest at t 0.75; the "e" is lost
            wait(60);
            verify(sc.tracking);
            compare(sc.committedOpen, true, "the host keeps the keyboard and the pointer during this stroke");
            keyClick(Qt.Key_Escape);
            tryVerify(function () { return !sc.isOpen; }, 1500, "Esc closes a half-open overview whose stroke never ended");
        }

        function test_DEFECT_close_request_ends_a_live_stroke() {
            // backdrop click, the toggle key and "qs ipc call overview close" all reach Scene.close()
            sc.strokeBegin(3, "UP", 0, Date.now());
            sc.strokeUpdate(10, Date.now());
            wait(60);
            sc.close("back");
            tryVerify(function () { return !sc.isOpen; }, 1500, "a close request ends a stroke whose 'e' never came");
        }

        // A window that appears while the overview is open (or was not yet in the model at the open) is never given
        // a capture: planCaptures() runs only on open and on a page turn, so its card stays an icon plate.
        function test_DEFECT_window_added_while_open_gets_a_picture() {
            openAndFocus();
            var w = root.fakeWindows.slice();
            w.push({ id: "0xa9", desk: 3, x: 300, y: 300, w: 400, h: 300, title: "T", label: "T", app: "App", icon: "", agent: "", focusRank: 5 });
            sc.windows = w;
            wait(100);
            verify(sc.captureAllowed["0xa9"] === true, "the new window on the viewed desk may capture (budget 24, 6 used)");
        }

        // A window closed by its app while he carries it: its card (and its DragHandler) is destroyed mid-drag, so
        // no release ever reaches the drag machine: kind stays "window", every later drag is refused by begin()
        // until Esc, and hover/selection stay off (scene.dragId is set).
        function test_DEFECT_carried_window_that_closes_sends_nothing() {
            openAndFocus();
            var a = card("0xa2"), b = tile(4);
            press(a); glide(a, { x: a.x, y: a.y - 40 }, 4);
            compare(sc.dragController.kind, "window");
            sc.windows = root.fakeWindows.filter(function (x) { return x.id !== "0xa2"; });
            glide({ x: a.x, y: a.y - 40 }, b, 8);
            var before = opsText();
            release(b); wait(50);
            compare(before, "[]", "nothing sent while the button is down");
            compare(root.sent.length, 0, "no op for a window that is gone: " + opsText());
            compare(sc.dragController.kind, "", "the drag is over once the button is up");
            var c = card("0xa3"), t = tile(4);
            press(c); glide(c, t, 12); release(t); wait(50);
            compare(opsText(), JSON.stringify(["move 0xa3→4"]), "the next drag works");
        }

        // Lua already sends millimetres with positive = fingers up (overview.lua mm = -dy / gain). Scene re-derives
        // the sign from the first non-zero travel: one update against the stroke's direction flips the whole stroke.
        function test_DEFECT_one_jittery_first_update_does_not_flip_a_close() {
            openAndFocus();
            var t0 = Date.now();
            sc.strokeBegin(3, "DOWN", 0, t0);
            sc.strokeUpdate(0.05, t0 + 12);                              // one jittery first update
            for (var i = 1; i <= 10; i++) { wait(12); sc.strokeUpdate(0.05 - 2.5 * i, t0 + 12 + 12 * i); }
            sc.strokeEnd(-24.95, t0 + 140, false);
            tryVerify(function () { return !sc.isOpen; }, 1500, "25 mm down closes (decision " + sc.stats.decisionLast + ")");
        }

        // Alt+Shift+Right pressed twice before the compositor has answered (or held down: key repeat is ~30 ms,
        // the answer plus the back end's 60 ms settle is ~100 ms). DragController.moveDesk refuses while its commit
        // is pending, and Scene.moveViewedDeskBy then falls through to a second reorder built from the STALE model
        // and the stale viewed desk: the same swap again, which undoes the first one.
        function test_DEFECT_alt_shift_right_twice_quickly() {
            openAndFocus();
            sc.viewDesk(2); waitSettled();
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            wait(20);
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            wait(50);
            var orders = root.sent.map(function (o) { return JSON.stringify(o.order); });
            verify(orders.length === 1 || (orders.length === 2 && orders[1] !== orders[0]),
                   "a second press either waits or builds on the first, never repeats the same swap: " + JSON.stringify(orders));
        }
    }
}
