// Lane 2 fast tests: the gesture maths (Gesture.js) and the t machine, keys, ops and undo of
// Scene.qml, off-screen, no compositor, no Quickshell.
//   /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_gesture.qml
// Units follow the coordinator's addendum (SPEC §0): the stream carries millimetres; TRAVEL_MM = 28;
// the SPEC 4.2 (a) speeds in old "units/ms" are converted at 350 units = 28 mm (4.5 u/ms = 0.36 mm/ms
// by distance, but the addendum's commit speed replaces 4.0 u/ms with 0.06 mm/ms, so the flick is
// expressed as 4.5/4.0 of the commit speed = 0.0675 mm/ms, and the slow reversal -0.4 u/ms as
// -0.4/350*28 = -0.032 mm/ms).
import QtQuick
import QtTest
import "../.."
import "../../Gesture.js" as G

Item {
    id: root
    width: 1200
    height: 750

    TestCase {
        name: "GestureMaths"

        function test_constants() {
            verify(G.TRAVEL_MM >= 20 && G.TRAVEL_MM <= 36, "TRAVEL_MM in the allowed 20-36 mm");
            compare(G.TRAVEL_MM, 28);
            compare(G.V_COMMIT, 0.06);
            compare(G.OMEGA, 15);
            compare(G.OMEGA_PAGE, 18);
        }

        function test_decide_table_data() {
            var flick = 4.5 / 4.0 * G.V_COMMIT, slowBack = -0.4 / 350 * 28;
            return [
                { tag: "slow release at 0.30 goes back",            p: 0.30, v: 0,      c: false, closing: false, want: 0 },
                { tag: "slow release at 0.40 opens",                 p: 0.40, v: 0,      c: false, closing: false, want: 1 },
                { tag: "flick 4.5 u/ms at 0.10 opens",               p: 0.10, v: flick,  c: false, closing: false, want: 1 },
                { tag: "slow reversal from 0.45 at -0.4 u/ms back",  p: 0.45, v: slowBack, c: false, closing: false, want: 0 },
                { tag: "cancelled at 0.9 goes back",                 p: 0.90, v: 0.2,    c: true,  closing: false, want: 0 },
                { tag: "exactly the commit speed commits",           p: 0.05, v: 0.06,   c: false, closing: false, want: 1 },
                { tag: "closing: slow release at 0.70 stays open",   p: 0.70, v: 0,      c: false, closing: true,  want: 1 },
                { tag: "closing: slow release at 0.60 closes",       p: 0.60, v: 0,      c: false, closing: true,  want: 0 },
                { tag: "closing: flick down at 0.90 closes",         p: 0.90, v: -flick, c: false, closing: true,  want: 0 },
                { tag: "closing: slow reversal from 0.55 stays",     p: 0.55, v: -slowBack, c: false, closing: true, want: 1 },
                { tag: "closing: cancelled at 0.1 stays open",       p: 0.10, v: -0.2,   c: true,  closing: true,  want: 1 }
            ];
        }
        function test_decide_table(d) { compare(G.decide(d.p, d.v, d.c, d.closing), d.want); }

        function test_spring_from_rest() {
            var hit = -1, maxX = 0, prev = 0;
            for (var ms = 0; ms <= 1000; ms++) {
                var r = G.spring(0, 0, 1, ms / 1000, G.OMEGA);
                verify(r.x >= prev - 1e-12, "monotonic at " + ms + " ms");
                prev = r.x;
                maxX = Math.max(maxX, r.x);
                if (hit < 0 && r.x >= 0.99) hit = ms;
            }
            verify(hit >= 400 && hit <= 480, "0.99 reached at " + hit + " ms (400-480)");
            verify(maxX <= 1, "never overshoots (max " + maxX + ")");
            // closing mirror
            var down = G.spring(1, 0, 0, hit / 1000, G.OMEGA);
            verify(down.x <= 0.0101 && down.x >= 0, "closing mirror " + down.x);
        }
        function test_spring_carries_the_finger_speed() {
            for (var v0 = -8; v0 <= 8; v0 += 2) {
                var a = G.spring(0.4, v0, 1, 0, 15), b = G.spring(0.4, v0, 1, 1e-6, 15);
                fuzzyCompare((b.x - a.x) / 1e-6, v0, 1e-3);
                fuzzyCompare(a.v, v0, 1e-9);
            }
            compare(G.spring(0.4, 50, 1, 0, 15).v, 8);   // clamped
        }
        function test_rubber() {
            for (var x = -10; x <= 10; x += 0.05) {
                var r = G.rubber(x);
                verify(r <= 1.06 + 1e-9 && r >= -0.06 - 1e-9, "rubber(" + x + ") = " + r);
            }
            compare(G.rubber(0.5), 0.5);
            compare(G.rubber(1), 1);
            compare(G.rubber(0), 0);
            fuzzyCompare(G.rubber(1.0001), 1, 1e-4);          // continuous at both ends
            fuzzyCompare(G.rubber(-0.0001), 0, 1e-4);
            fuzzyCompare(G.rubberSlope(1 + 1e-12), 0.18, 1e-9);
        }
        function test_sign_calibration() {
            // DIR=UP with a negative first acc: the stream's sign is flipped, so sign = -1 and progress still opens.
            compare(G.calibrateSign("UP", -3.2), -1);
            fuzzyCompare(G.progress(-14, -1, 0, false), 0.5, 1e-9);
            compare(G.calibrateSign("up", 2), 1);
            compare(G.calibrateSign("DOWN", -2), 1);
            compare(G.calibrateSign("down", 2), -1);
            fuzzyCompare(G.progress(-7, 1, 1, true), 0.75, 1e-9);
        }
        function test_velocity() {
            var s = [];
            for (var i = 0; i < 40; i++) s.push({ t: 1000 + i * 7, acc: 0.1 * i * 7 });
            fuzzyCompare(G.velocity(s), 0.1, 1e-9);
            // only the last 100 ms count: a slow start does not drag a fast end
            var s2 = [];
            for (i = 0; i < 30; i++) s2.push({ t: i * 7, acc: 0.01 * i * 7 });
            var base = s2[s2.length - 1];
            for (i = 1; i <= 20; i++) s2.push({ t: base.t + i * 7, acc: base.acc + 0.2 * i * 7 });
            fuzzyCompare(G.velocity(s2), 0.2, 1e-6);
            compare(G.velocity([{ t: 0, acc: 0 }, { t: 10, acc: 1 }]), 0.1);
            compare(G.velocity([{ t: 0, acc: 0 }]), 0);
        }
        function test_parse() {
            compare(G.parseLine("custom>>ovg,b,3,UP,0.00,158725363").kind, "b");
            compare(G.parseLine("ovg,b,4,down,0.00,5").dir, "DOWN");
            compare(G.parseLine("ovg,u,12.34,99").acc, 12.34);
            compare(G.parseLine("ovg,e,-3.5,100,1").cancelled, true);
            compare(G.parseLine("ovg,e,-3.5,100,0").cancelled, false);
            compare(G.parseLine("ovg,hello").kind, "hello");
            compare(G.parseLine("ovg,ping,7").n, 7);
            verify(G.parseLine("ovg,u,abc,1") === null);
            verify(G.parseLine("ovg,b,3,LEFT,0,1") === null);
            verify(G.parseLine("ovg,e,1,2,7") === null);
            verify(G.parseLine("monitoradded>>x") === null);
            verify(G.parseLine("") === null);
        }
    }

    // ---- the t machine and the keys, on a real Scene off-screen ------------------------
    property var fakeWindows: {
        var w = [], id = 0;
        function add(desk, x, y, ww, hh, rank) { w.push({ id: "0xa" + (id++), desk: desk, x: x, y: y, w: ww, h: hh, title: "Test", label: "Test", app: "App", icon: "", agent: "", focusRank: rank }); }
        add(1, 8, 30, 580, 700, 3); add(2, 8, 30, 1180, 700, 2); add(3, 8, 30, 580, 700, 0); add(3, 600, 30, 580, 700, 1); add(4, 8, 30, 1180, 700, 4);
        return w;
    }
    property var fakeDesks: [{ id: 1, name: "App", isNew: false, waiting: 0, count: 1 }, { id: 2, name: "App", isNew: false, waiting: 0, count: 1 },
                             { id: 3, name: "App", isNew: false, waiting: 0, count: 2 }, { id: 4, name: "App", isNew: false, waiting: 0, count: 1 },
                             { id: 5, name: "New desk", isNew: true, waiting: 0, count: 0 }]
    property var sent: []          // ops the scene asked the "host" to run
    property bool autoAnswer: true
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
            delete c.tag; c.seq = n;
            var s = root.sent.slice(); s.push(c); root.sent = s;
            sc.opSent(op.tag, n);
            if (root.autoAnswer) Qt.callLater(function () { sc.opDone(n, true, ""); });
        }
    }
    property int slowMs: 100
    Component {
        id: slowPicture
        Item {
            property string winId: ""
            property bool capturing: false
            property bool ready: false
            property bool done: false
            readonly property bool pending: capturing && !done
            onCapturingChanged: if (!capturing) { done = false; ready = false; }
            function refresh() {}
            Timer { running: parent.capturing && !parent.done; interval: root.slowMs; onTriggered: { parent.done = true; parent.ready = true; } }
        }
    }
    SignalSpy { id: committedSpy; target: sc; signalName: "committedOpenChanged" }
    SignalSpy { id: finishedSpy; target: sc; signalName: "finished" }

    TestCase {
        name: "SceneMotion"
        when: windowShown

        function init() {
            sc.snapShut();
            root.sent = []; root.autoAnswer = true;
            committedSpy.clear(); finishedSpy.clear();
        }
        function now() { return Date.now(); }
        // A stroke at the pad's real cadence: updates every ~12 ms (the Lua side coalesces 7 ms frames to >= 12 ms).
        function stroke(mmTotal, ms, opts) {
            opts = opts || {};
            var t0 = now(), dir = mmTotal >= 0 ? "UP" : "DOWN", sign = opts.flip ? -1 : 1;
            sc.strokeBegin(3, dir, 0, t0);
            var steps = Math.max(1, Math.round(ms / 12)), acc = 0;
            for (var i = 1; i <= steps; i++) {
                wait(12);
                var k = i / steps;
                acc = (opts.profile ? opts.profile(k) : k) * mmTotal;
                sc.strokeUpdate(sign * acc, t0 + i * 12);
                if (opts.onStep) opts.onStep(i, acc);
            }
            if (!opts.noEnd) sc.strokeEnd(sign * acc, t0 + steps * 12, !!opts.cancelled);
            return t0;
        }
        function waitSettled(ms) { tryVerify(function () { return !sc.springing && !sc.tracking && !sc.arming && !sc.paging; }, ms || 1500); }

        function test_never_cuts_stroke_begun_no_motion() {
            sc.strokeBegin(3, "UP", 0, now());
            wait(60);
            compare(sc.t, 0);
            compare(sc.opacity, 0, "nothing of the overview is drawn at t = 0");
            verify(sc.isOpen && sc.tracking);
            sc.strokeEnd(0, now(), false);
            waitSettled();
            compare(sc.isOpen, false);
            compare(committedSpy.count, 0, "a stroke that never moved never touched focus");
        }

        function test_t_follows_the_finger_exactly() {
            // Every drawn frame while tracking: t == rubber(progress(latest travel)), nothing eased in.
            var maxErr = 0;
            stroke(20, 240, { noEnd: true, onStep: function (i, acc) {
                // the next drawn frame shows exactly this travel (no easing, no lag beyond the frame itself)
                var want = Math.max(0, G.rubber(G.progress(acc, 1, 0, false)));
                tryVerify(function () { return Math.abs(sc.t - want) < 1e-9; }, 100, "frame after update " + i);
                maxErr = Math.max(maxErr, Math.abs(sc.t - want));
            } });
            verify(maxErr < 1e-9, "t equals the finger's travel, err " + maxErr);
            verify(sc.tracking);
            sc.strokeEnd(20, now(), false);
            waitSettled();
            compare(sc.t, 1);
        }

        function test_a_late_frame_catches_up_without_a_jump() {
            // Design review: after a stalled frame t jumped 0.47 in one frame. It now moves at most maxStep a frame
            // toward the finger, never past it, and the release starts from what is drawn (no jump there either).
            sc.strokeBegin(3, "UP", 0, now());
            sc.strokeUpdate(25.2, now() + 10);        // the finger is suddenly 0.9 ahead
            tryVerify(function () { return Math.abs(sc.t - 0.9) < 1e-9; }, 500, "t reaches the finger");
            // per drawn frame, from the scene's own frame trace
            var fr = sc.trace.filter(function (f) { return f[2] !== "E"; }), biggest = 0, steps = 0;
            for (var i = 1; i < fr.length; i++) { var d = fr[i][1] - fr[i - 1][1]; if (d > 1e-9) { steps++; biggest = Math.max(biggest, d); } }
            verify(biggest <= sc.maxStep + 1e-9, "largest step per frame " + biggest);
            verify(steps >= 2, "caught up over several frames: " + steps);
            sc.strokeEnd(25.2, now() + 20, false);
            waitSettled();
            compare(sc.t, 1);
        }

        function test_silence_never_ends_a_stroke() {
            // Replaces the SPEC's 300 ms watchdog (addendum L4): resting fingers send nothing, the overview must hold.
            sc.strokeBegin(3, "UP", 0, now());
            sc.strokeUpdate(14, now() + 50);
            // one 14 mm event (no real pad sends one that big): t reaches it within a few frames (Scene.maxStep)
            tryVerify(function () { return Math.abs(sc.t - 0.5) < 1e-9; }, 300, "t reaches the finger");
            var held = sc.t;
            wait(450);
            compare(sc.tracking, true, "still tracking after 450 ms of silence");
            compare(sc.t, held);
            wait(800);
            compare(sc.t, held, "held 1.25 s");
            sc.strokeUpdate(21, now());
            tryVerify(function () { return Math.abs(sc.t - 0.75) < 1e-9; }, 300, "t follows on");
            sc.strokeEnd(21, now(), false);
            waitSettled();
            compare(sc.t, 1);
        }

        function test_reload_and_new_stroke_end_a_live_stroke() {
            sc.strokeBegin(3, "UP", 0, now());
            sc.strokeUpdate(5.6, now());           // p 0.2
            wait(30);
            sc.settleStroke("reload");
            compare(sc.tracking, false);
            compare(sc.stats.decisionLast, "close:reload");
            waitSettled();
            compare(sc.isOpen, false);
            // a new "b" ends the live one by position (0.6 -> open), then tracks the new one
            sc.strokeBegin(3, "UP", 0, now());
            sc.strokeUpdate(16.8, now());
            wait(30);
            sc.strokeBegin(3, "DOWN", 0, now());
            compare(sc.stats.decisionLast, "", "the new stroke's stats");
            verify(sc.tracking);
            verify(sc.strokeClosing, "the first stroke decided open by position, so the second closes");
            sc.strokeEnd(-30, now(), false);
            waitSettled();
            compare(sc.isOpen, false);
        }

        function test_update_without_begin_starts_a_stroke() {
            sc.strokeUpdate(3.0, now());           // origin
            verify(sc.tracking && sc.isOpen);
            sc.strokeUpdate(3.0 + 14, now() + 30);
            tryVerify(function () { return Math.abs(sc.t - 0.5) < 1e-9; }, 300, "t reaches the finger");
            sc.strokeEnd(17, now() + 40, false);
            waitSettled();
            compare(sc.t, 1);
        }

        function test_down_on_closed_does_nothing() {
            sc.strokeBegin(3, "DOWN", 0, now());
            sc.strokeUpdate(-10, now());
            wait(40);
            compare(sc.isOpen, false);
            compare(sc.t, 0);
            sc.strokeEnd(-20, now(), false);
            wait(40);
            compare(sc.isOpen, false);
            compare(finishedSpy.count, 0);
        }

        function test_monotonic_and_no_jump_at_release() {
            // One-way stroke at a steady 90 mm/s, released at 0.55 of the travel while still moving.
            sc.trace = [];
            stroke(15.4, 170);
            waitSettled();
            var tr = sc.trace.filter(function (f) { return f[2] !== "E" && f[2] !== "R"; }), rel = -1;
            verify(tr.length > 10, "frames recorded: " + tr.length);
            for (var i = 1; i < tr.length; i++) verify(tr[i][1] >= tr[i - 1][1] - 1e-9, "monotonic at frame " + i + ": " + JSON.stringify(tr.slice(Math.max(0, i - 2), i + 2)));
            for (i = 1; i < tr.length; i++) if (tr[i - 1][2] === "T" && tr[i][2] === "S") { rel = i; break; }
            verify(rel > 2, "release frame found");
            // The spring takes over at the finger's last position (R) with the finger's speed; jump = how far the
            // first spring frame lands from that hand-over continued at the hand-over speed.
            var R = sc.trace.filter(function (f) { return f[2] === "R"; })[0];
            var evs = sc.trace.filter(function (f) { return f[2] === "E" && f[0] <= R[0]; });
            verify(Math.abs(R[1] - evs[evs.length - 1][1]) < 1e-3, "spring starts where the finger is: " + JSON.stringify([R, evs[evs.length - 1]]));
            var c = tr[rel];
            var jump = Math.abs(c[1] - (R[1] + R[3] * (c[0] - R[0]) / 1000));
            console.log("release: hand-over " + JSON.stringify(R) + " first spring frame " + JSON.stringify(c) + " jump " + jump.toFixed(4));
            verify(jump < 0.03, "no jump over 0.03 at release (" + jump + ")");
            compare(sc.t, 1);
            compare(sc.committedOpen, true);
        }

        function test_grab_a_running_spring_both_ways() {
            // open by a flick, then put fingers down again while it is still flying and pull it closed
            stroke(8, 60);
            compare(sc.target, 1);
            wait(50);
            verify(sc.springing, "still flying");
            var before = sc.t;
            sc.strokeBegin(3, "DOWN", 0, now());
            wait(20);
            verify(Math.abs(sc.t - before) < 0.08, "grabbed where it was: " + before + " -> " + sc.t);
            fuzzyCompare(sc.strokeP0, before, 0.08);
            verify(sc.strokeClosing, "it was heading open, so this stroke closes");
            var t0 = now(), endMm = Math.max(3, (sc.t - 0.2) * 28);   // ends near t 0.2, moving fast
            for (var i = 1; i <= 8; i++) { wait(12); sc.strokeUpdate(-i * endMm / 8, t0 + i * 12); }
            sc.strokeEnd(-endMm, t0 + 96, false);
            compare(sc.target, 0);
            wait(16);
            verify(sc.springing && sc.t > 0, "closing in flight: " + sc.t);
            // ... and the reverse: grab the closing spring and open again
            var mid = sc.t;
            sc.strokeBegin(3, "UP", 0, now());
            wait(20);
            verify(Math.abs(sc.t - mid) < 0.08, "grabbed the close at " + mid + " -> " + sc.t);
            verify(!sc.strokeClosing);
            t0 = now();
            for (i = 1; i <= 8; i++) { wait(12); sc.strokeUpdate(i * 2.5, t0 + i * 12); }
            sc.strokeEnd(20, t0 + 100, false);
            waitSettled();
            compare(sc.t, 1);
            compare(sc.isOpen, true);
        }

        function test_cancelled_stroke_never_touches_focus() {
            stroke(18, 200, { cancelled: true });
            waitSettled();
            compare(sc.isOpen, false);
            compare(committedSpy.count, 0, "committedOpen never changed");
            compare(sc.stats.decisionLast, "close:cancelled");
            // a cancelled closing stroke leaves it open and the keyboard where it was
            sc.open(); waitSettled();
            committedSpy.clear();
            stroke(-18, 200, { cancelled: true });
            waitSettled();
            compare(sc.t, 1);
            compare(committedSpy.count, 0);
        }

        function test_up_while_open_only_rubber_bands() {
            sc.open(); waitSettled();
            var t0 = now();
            sc.strokeBegin(3, "UP", 0, t0);
            sc.strokeUpdate(60, t0 + 100);
            wait(40);
            verify(sc.t > 1 && sc.t <= 1.06, "rubber " + sc.t);
            sc.strokeEnd(60, t0 + 120, false);
            waitSettled();
            compare(sc.t, 1);
        }

        function test_gate_holds_until_pictures_or_150ms() {
            // pictures that take 100 ms: t stays <= 0.20 until they are in, then catches up over 80 ms
            root.slowMs = 100;
            sc.pictureSource = slowPicture;
            var t0 = now();
            sc.strokeBegin(3, "UP", 0, t0);
            sc.strokeUpdate(22, t0 + 20);
            wait(50);
            verify(sc.t <= 0.2 + 1e-9, "held at <= 0.20 while pictures are pending: " + sc.t);
            tryVerify(function () { return Math.abs(sc.t - G.rubber(22 / 28)) < 1e-9; }, 400);
            var waited = now() - t0;
            verify(sc.gateWaitedMs >= 90 && sc.gateWaitedMs <= 140, "gate opened when the pictures came: " + sc.gateWaitedMs + " ms");
            verify(waited >= 170, "caught up over 80 ms after that: " + waited + " ms");
            sc.strokeEnd(22, now(), false);
            waitSettled();
            sc.close("back"); waitSettled();
            // pictures that never come: the gate gives up at 150 ms
            root.slowMs = 100000;
            t0 = now();
            sc.strokeBegin(3, "UP", 0, t0);
            sc.strokeUpdate(22, t0 + 20);
            tryVerify(function () { return Math.abs(sc.t - G.rubber(22 / 28)) < 1e-9; }, 600);
            verify(sc.gateWaitedMs >= 145 && sc.gateWaitedMs <= 200, "gave up at 150 ms: " + sc.gateWaitedMs);
            sc.strokeEnd(22, now(), false);
            waitSettled();
            sc.pictureSource = null;
        }

        function test_keyboard_open_close_and_finish() {
            sc.open();
            verify(sc.isOpen);
            waitSettled();
            compare(sc.t, 1);
            compare(sc.mode, "open");
            sc.close("back");
            compare(sc.committedOpen, false);
            waitSettled();
            compare(sc.isOpen, false);
            compare(finishedSpy.count, 1);
        }

        function openAndFocus() { sc.open(); waitSettled(); sc.forceActiveFocus(); }

        function test_keys() {
            openAndFocus();
            compare(sc.viewedDesk, 3);
            keyClick(Qt.Key_2, Qt.ControlModifier);               // view desk 2, stays open
            waitSettled(); compare(sc.viewedDesk, 2); verify(sc.isOpen && !sc.closing);
            keyClick(Qt.Key_4, Qt.AltModifier);
            waitSettled(); compare(sc.viewedDesk, 4);
            keyClick(Qt.Key_Tab);                                 // Tab pages through real desks
            waitSettled(); compare(sc.viewedDesk, 1);
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            waitSettled(); compare(sc.viewedDesk, 4);
            keyClick(Qt.Key_3, Qt.ControlModifier); waitSettled();
            sc.selectedId = "0xa2"; sc.showSelection = true;
            keyClick(Qt.Key_At, Qt.ControlModifier | Qt.ShiftModifier);        // Ctrl+Shift+2 (US: '@')
            tryVerify(function () { var o = root.sent[0]; return root.sent.length === 1 && o.op === "move" && o.win === "0xa2" && o.desk === 2; }, 1000, "step 1 " + JSON.stringify(root.sent));
            tryVerify(function () { return sc.undoStack.length === 1; }, 1000, "step 2 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            compare(sc.pillState().text, "Moved"); compare(sc.pillState().undo, true);
            keyClick(Qt.Key_1, Qt.ControlModifier | Qt.ShiftModifier);         // Ctrl+Shift+1 (digit form)
            tryVerify(function () { return root.sent.length === 2 && root.sent[1].desk === 1; }, 1000, "step 3 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            sc.selectedId = "0xa3";
            keyClick(Qt.Key_N, Qt.ControlModifier | Qt.ShiftModifier);
            tryVerify(function () { return root.sent.length === 3 && root.sent[2].op === "newdesk" && root.sent[2].win === "0xa3"; }, 1000, "step 4 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            sc.selectedId = "0xa3";
            keyClick(Qt.Key_Right, Qt.ControlModifier | Qt.ShiftModifier);     // one desk right: 3 -> 4
            tryVerify(function () { return root.sent.length === 4 && root.sent[3].op === "move" && root.sent[3].desk === 4; }, 1000, "step 5 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            keyClick(Qt.Key_Left, Qt.AltModifier | Qt.ShiftModifier);          // viewed desk 3 one place left
            tryVerify(function () { return root.sent.length === 5; }, 1000, "step 6 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            compare(JSON.stringify(root.sent[4].order), "[1,3,2,4]");
            tryCompare(sc, "viewedDesk", 2);                                   // it follows its desk to its new number
            compare(sc.undoStack.length, 5);
            keyClick(Qt.Key_Z, Qt.ControlModifier);                             // undo the reorder: its inverse
            tryVerify(function () { return root.sent.length === 6; }, 1000, "step 7 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            compare(JSON.stringify(root.sent[5].order), "[1,3,2,4]");          // a swap is its own inverse
            compare(sc.undoStack.length, 4);
            keyClick(Qt.Key_Z, Qt.ControlModifier);                             // undo the move 3 -> 4: back to 3
            tryVerify(function () { return root.sent.length === 7; }, 1000, "step 8 sent=" + JSON.stringify(root.sent) + " undo=" + sc.undoStack.length);
            compare(root.sent[6].op, "move"); compare(root.sent[6].win, "0xa3"); compare(root.sent[6].desk, 3);
            keyClick(Qt.Key_N, Qt.ControlModifier);                             // new empty desk, viewed, virtual
            waitSettled(); compare(sc.viewedDesk, 5); compare(sc.gridOrder.length, 0);
            keyClick(Qt.Key_T); keyClick(Qt.Key_E);                             // typing searches
            compare(sc.query, "te");
            keyClick(Qt.Key_Escape);                                            // Esc clears the search first
            compare(sc.query, ""); verify(sc.isOpen);
            keyClick(Qt.Key_W, Qt.ControlModifier);                             // nothing selected on an empty desk: nothing
            keyClick(Qt.Key_Escape);                                            // then closes
            verify(sc.closing);
            waitSettled();
            compare(sc.isOpen, false);
        }

        function test_failure_and_timeout_pills() {
            openAndFocus();
            root.autoAnswer = false;
            sc.selectedId = "0xa2"; sc.showSelection = true;
            keyClick(Qt.Key_4, Qt.ControlModifier | Qt.ShiftModifier);
            tryVerify(function () { return root.sent.length === 1; });
            sc.opDone(root.sent[0].seq, false, "change_id refused");
            compare(sc.pillState().kind, "fail");
            compare(sc.pillState().text, "Couldn't move it — nothing changed");
            compare(sc.undoStack.length, 0);
            // An answer to something the scene never asked (the back end's own heal after the re-read) changes nothing.
            sc.opDone(9999, true, "");
            compare(sc.pillState().kind, "fail");
            keyClick(Qt.Key_4, Qt.ControlModifier | Qt.ShiftModifier);
            tryVerify(function () { return root.sent.length === 2; });
            wait(400); compare(sc.pendingCount, 1);
            tryVerify(function () { return sc.pendingCount === 0; }, 800);      // 600 ms without an answer
            compare(sc.pillState().kind, "fail");
            compare(sc.lastOp.why, "no answer in 600 ms");
        }

        function test_insert_disables_undo() {
            openAndFocus();
            sc.requestOp({ op: "move", win: "0xa2", desk: 1 });
            tryVerify(function () { return sc.undoStack.length === 1; });
            sc.requestOp({ op: "insert", win: "0xa2", left: 1, right: 2 });
            tryVerify(function () { return root.sent.length === 2 && sc.pendingCount === 0; });
            compare(sc.undoStack.length, 0);
            compare(sc.pillState().undo, false);
        }

        function test_reorder_inverse_is_exact() {
            openAndFocus();
            // "2 to 5" on 1-4 here: order [1,3,4,2] ; inverse must put every desk back
            var inv = sc.inverseOf({ op: "reorder", order: [1, 3, 4, 2] });
            compare(JSON.stringify(inv.order), "[1,4,2,3]");
            // applying order then inverse returns the identity
            var S = [1, 2, 3, 4], o = [1, 3, 4, 2], map = {}, back = {};
            for (var i = 0; i < 4; i++) map[o[i]] = S[i];              // old id -> new id
            for (i = 0; i < 4; i++) back[inv.order[i]] = S[i];          // new id -> final id
            for (i = 0; i < 4; i++) compare(back[map[S[i]]], S[i]);
        }

        function test_capture_budget_and_priority() {
            var many = [];
            for (var i = 0; i < 30; i++) many.push({ id: "0xc" + i, desk: 1 + (i % 6), x: 0, y: 30, w: 300, h: 200, title: "T", label: "T", app: "A", icon: "", agent: "", focusRank: i });
            sc.windows = many;
            sc.desks = [1, 2, 3, 4, 5, 6].map(function (n) { return { id: n, name: "A", isNew: false, waiting: 0, count: 5 }; });
            sc.activeDesk = 6;
            sc.open(); waitSettled();
            var allowed = Object.keys(sc.captureAllowed);
            compare(allowed.length, 24);
            for (i = 0; i < 30; i++) if (many[i].desk === 6) verify(sc.captureAllowed[many[i].id], "viewed desk first");
            for (i = 0; i < 30; i++) if (many[i].desk === 1) verify(!sc.captureAllowed[many[i].id], "the farthest desk last");
            sc.close("back"); waitSettled();
            sc.windows = root.fakeWindows; sc.desks = root.fakeDesks; sc.activeDesk = 3;
        }

        function test_scroll_pages_under_the_fingers() {
            openAndFocus();
            compare(sc.viewedDesk, 3);
            // fingers move left by a third of a grid width over ~100 ms: the grid follows, then snaps on
            for (var i = 0; i < 10; i++) { sc.scrollBy(-root.width / 30 * 1.1); wait(10); }
            verify(sc.paging);
            verify(sc.pagePos !== 0, "the cards layer moved with the fingers");
            sc.scrollRelease();
            waitSettled();
            compare(sc.viewedDesk, 4);
            compare(sc.pagePos, 0);
            compare(sc.paging, false);
        }

        function test_native_swipe_follow() {
            openAndFocus();
            sc.activeDesk = 4;                 // his own 3-finger sideways swipe changed desk
            verify(sc.paging);
            compare(sc.viewedDesk, 4);
            verify(sc.pV0 > 3.9, "starts at one grid width per 250 ms");
            waitSettled();
            compare(sc.pagePos, 0);
            sc.activeDesk = 3;
            waitSettled();
            compare(sc.viewedDesk, 3);
        }
    }
}
