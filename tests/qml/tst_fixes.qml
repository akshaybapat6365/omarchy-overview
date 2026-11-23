// Guards for the fixer's changes that the review tests do not pin, on a real Scene whose "host" answers ops like
// the real back end: the answer first, the model 40 ms later (HyprlandBackend: reply, then the settle re-read).
//   /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_fixes.qml
import QtQuick
import QtTest
import "../.."

Item {
    id: root
    width: 1200
    height: 750

    function freshWindows() {
        var w = [], id = 0;
        function add(desk, rank) { w.push({ id: "0xa" + (id++), desk: desk, x: 8, y: 30, w: 1180, h: 700, title: "Test", label: "Test", app: "App", icon: "", agent: "", focusRank: rank, floating: false }); }
        add(1, 3); add(2, 2); add(3, 0); add(4, 4);
        return w;
    }
    function desksOf(ws) {
        var ids = [], out = [];
        for (var i = 0; i < ws.length; i++) if (ids.indexOf(ws[i].desk) < 0) ids.push(ws[i].desk);
        ids.sort(function (a, b) { return a - b; });
        for (i = 0; i < ids.length; i++) out.push({ id: ids[i], name: "App", isNew: false, waiting: 0, count: 1 });
        out.push({ id: ids[ids.length - 1] + 1, name: "New desk", isNew: true, waiting: 0, count: 0 });
        return out;
    }
    property var sent: []
    property int seq: 0
    property string failNext: ""
    Scene {
        id: sc
        width: root.width
        height: root.height
        windows: root.freshWindows()
        desks: root.desksOf(windows)
        activeDesk: 3
        onOperate: function (op) {
            var n = ++root.seq, c = JSON.parse(JSON.stringify(op));
            delete c.tag; c.seq = n;
            var s = root.sent.slice(); s.push(c); root.sent = s;
            sc.opSent(op.tag, n);
            var why = root.failNext; root.failNext = "";
            answer.createObject(root, { opSeq: n, op: c, why: why });
        }
    }
    Component {
        id: answer
        Timer {
            id: ans
            property int opSeq
            property var op
            property string why
            interval: 30; running: true
            onTriggered: {
                if (why) { sc.opDone(opSeq, false, why); destroy(); return; }
                sc.opDone(opSeq, true, "");
                applyLater.start();
            }
            property Timer applyLater: Timer {
                interval: 40
                onTriggered: {
                    var o = ans.op, ws = sc.windows.map(function (w) { return Object.assign({}, w); });
                    if (o.op === "reorder") {
                        var S = sc.realDesks.slice(), map = {};
                        for (var i = 0; i < o.order.length; i++) map[o.order[i]] = S[i];
                        for (i = 0; i < ws.length; i++) ws[i].desk = map[ws[i].desk];
                        sc.activeDesk = map[sc.activeDesk];
                    } else if (o.op === "move") {
                        for (i = 0; i < ws.length; i++) if (ws[i].id === o.win) ws[i].desk = o.desk;
                    }
                    sc.windows = ws; sc.desks = root.desksOf(ws);
                    ans.destroy();
                }
            }
        }
    }

    TestCase {
        name: "Fixes"
        when: windowShown

        function init() {
            sc.snapShut();
            sc.windows = root.freshWindows(); sc.desks = root.desksOf(sc.windows); sc.activeDesk = 3;
            wait(800);
            root.sent = []; root.failNext = "";
        }
        function waitSettled() { tryVerify(function () { return sc.settled; }, 2000, "settled"); }
        function openAndFocus() { sc.open(); waitSettled(); sc.forceActiveFocus(); wait(50); }
        function deskOfWindow(id) { for (var i = 0; i < sc.windows.length; i++) if (sc.windows[i].id === id) return sc.windows[i].desk; return -1; }

        // Review (compositor + interaction): two quick Alt+Shift+Right must move the viewed desk two places,
        // the second op built from the model the first one left (the stage check of review-compositor.sh).
        function test_two_quick_alt_shift_right_move_two_places() {
            openAndFocus();
            sc.viewDesk(2); waitSettled();
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            wait(10);
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            tryVerify(function () { return root.sent.length === 2 && deskOfWindow("0xa1") === 4; }, 2000,
                      "desk 2 ends at place 4: " + JSON.stringify(root.sent.map(function (o) { return o.order; })));
            compare(JSON.stringify(root.sent[0].order), "[1,3,2,4]");
            compare(JSON.stringify(root.sent[1].order), "[1,2,4,3]", "the second is built on the first's result");
            tryCompare(sc, "viewedDesk", 4);
        }

        // Stage finding: the real back end refuses an op while it settles the last one ("busy"); the scene waits.
        function test_a_settling_back_end_holds_the_next_op() {
            openAndFocus();
            sc.viewDesk(2); waitSettled();
            sc.hostBusy = true;
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            wait(200);
            compare(root.sent.length, 0, "nothing sent while the back end settles");
            sc.hostBusy = false;
            tryVerify(function () { return root.sent.length === 1; }, 1000);
            compare(JSON.stringify(root.sent[0].order), "[1,3,2,4]");
        }

        // Six quick presses (a held key) clamp at the end of the strip and never undo each other.
        function test_held_alt_shift_left_lands_at_the_first_place() {
            openAndFocus();
            sc.viewDesk(4); waitSettled();
            for (var i = 0; i < 6; i++) { keyClick(Qt.Key_Left, Qt.AltModifier | Qt.ShiftModifier); wait(25); }
            tryVerify(function () { return deskOfWindow("0xa3") === 1 && !sc.opBusy; }, 3000, "desk 4 ends first: " + JSON.stringify(root.sent.map(function (o) { return o.order; })));
            verify(root.sent.length <= 3, "a few ops, not six: " + root.sent.length);
        }

        // A failed op drops what was queued behind it and says so in plain words.
        function test_failure_drops_the_queue_and_words_say_why() {
            openAndFocus();
            sc.viewDesk(2); waitSettled();
            root.failNext = "desk-layout-7";
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            keyClick(Qt.Key_Right, Qt.AltModifier | Qt.ShiftModifier);
            tryVerify(function () { return sc.pillState() !== null && sc.pillState().kind === "fail"; }, 1500);
            compare(sc.pillState().text, "Couldn't move it — Desk 7 has its own layout");
            wait(800);
            compare(root.sent.length, 1, "nothing queued is sent after a failure");
            compare(sc.failureWords("taken+rollback-failed-3"), "Couldn't finish — putting desks back");
            compare(sc.failureWords("busy"), "Couldn't move it — nothing changed");
        }

        // Design review: the last op's pill must not be up while he lifts the next thing.
        function test_a_new_drag_hides_the_last_result() {
            openAndFocus();
            sc.selectedId = "0xa2"; sc.showSelection = true;
            keyClick(Qt.Key_At, Qt.ControlModifier | Qt.ShiftModifier);     // Ctrl+Shift+2: move to desk 2
            tryVerify(function () { return sc.pillState() !== null && sc.pillState().text === "Moved"; }, 1500);
            tryVerify(function () { return !sc.opBusy; }, 1500);
            sc.viewDesk(2); waitSettled();
            sc.selectedId = "0xa1"; sc.showSelection = true;
            keyClick(Qt.Key_Space);                                         // keyboard lift
            compare(sc.dragController.kind, "window");
            compare(sc.pillState(), null, "the 'Moved' pill went away when the next lift began");
            keyClick(Qt.Key_Escape);
        }

        // The open key during a stroke whose end never came settles it open; Esc then closes as usual.
        function test_open_request_settles_a_live_stroke_open() {
            sc.strokeBegin(3, "UP", 0, Date.now());
            sc.strokeUpdate(5, Date.now());
            wait(40);
            sc.open();
            verify(!sc.tracking, "the stroke is over");
            compare(sc.committedOpen, true);
            waitSettled();
            compare(sc.t, 1);
            sc.strokeEnd(5, Date.now(), false);                            // a late end changes nothing
            wait(60);
            verify(sc.isOpen && !sc.closing);
        }

        // A close request mid-stroke ignores the rest of that stroke's events (they cannot re-open it).
        function test_events_after_a_close_request_are_ignored_until_the_next_stroke() {
            sc.strokeBegin(3, "UP", 0, Date.now());
            sc.strokeUpdate(10, Date.now());
            wait(40);
            sc.close("back");
            sc.strokeUpdate(20, Date.now());
            verify(!sc.tracking, "a late update does not start a stroke");
            tryVerify(function () { return !sc.isOpen; }, 1500);
            sc.strokeBegin(3, "UP", 0, Date.now());                       // the next stroke works
            verify(sc.tracking);
            sc.strokeEnd(30, Date.now(), false);
            waitSettled();
            compare(sc.t, 1);
            sc.close("back");
        }
    }
}
