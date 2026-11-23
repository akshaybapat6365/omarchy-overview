// A fixed, realistic desktop for testing off-screen (OVERVIEW_BACKEND=mock).
// Same interface as HyprlandBackend.qml (SPEC 4.1); actions change the fixed
// desktop the way Hyprland would (desks are numbers, an emptied desk goes
// away, a reorder renumbers), so lanes 2 and 3 can be proven without a compositor.
//   OVERVIEW_MOCK_DIR       folder with fixture.json and pics/
//   OVERVIEW_MOCK_SCENARIO  one | six | nine | thirteen | many | empty | gap (default six)
// Desks shown: deskFacts feeds Desks.forScreen exactly as the real back end does (one screen, block 0).
//
// Stream: feed(line) takes one ovg line (b,… u,… e,… hello ping,…) and emits
// strokeBegin/strokeUpdate/strokeEnd/hello exactly as the real back end does.
// On the stage the same lines also arrive through Hyprland's event socket
// (hl.dsp.event("ovg,…") -> custom>>ovg,…), so tests/stage/feed.py can replay
// strokes at their true timing through the real transport.
//
// Op log (state().ops), one line per op the overview asked for, exactly:
//   move <win>→<desk> · newdesk <win> · reorder [1,3,4,5,2,6] · insert <left>|<right or end> <win> · heal
// Failure injection: failop("all"|"none"|"next"|"<op name>"), delay(ms) of the answer (default 25 ms;
// over 600 ms shows the overview's timeout path), pingfail(true) makes the next ping fail.
//
// Remote control for tests: qs … ipc call overview-mock
//   scenario <name> · fail · state · failop <mode> · delay <ms> · pingfail <true|false>
//   stroke <mm> <ms> <cancelled 0|1> (a synthetic 3-finger stroke at 7 ms frames) · oplog · clearlog · desk <n>
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../Gesture.js" as G

Item {
    id: be
    signal failed(string why)
    signal toggleRequested()
    signal closeRequested()
    // SPEC 4.1 stream and op signals
    signal strokeBegin(int fingers, string dir, real acc, real tMs)
    signal strokeUpdate(real acc, real tMs)
    signal strokeEnd(real acc, real tMs, bool cancelled)
    signal opResult(int seq, bool ok, string why)
    signal hello()
    signal pingResult(bool ok)

    property bool watching: false
    property real rounding: 12
    readonly property int forks: 0      // the mock starts no programs

    property var windows: []
    property int activeDesk: 1
    property string focusedId: ""
    property real monitorWidth: 2400
    property real monitorHeight: 1500
    property string screenName: ""
    property bool ready: false
    function prepare() {}

    readonly property string dir: Quickshell.env("OVERVIEW_MOCK_DIR") || ""
    property string scenario: Quickshell.env("OVERVIEW_MOCK_SCENARIO") || "six"
    property var fixture: null
    property var log: []                // everything the mock was asked (no titles)
    property var ops: []                // the op log (see header)
    function note(s) { var l = log.slice(); l.push(s); if (l.length > 200) l.shift(); log = l; console.log("overview-mock: " + s); }
    function noteOp(s) { var l = ops.slice(); l.push(s); ops = l; note("op " + s); }

    FileView {
        path: be.dir + "/fixture.json"
        onLoaded: {
            try { be.fixture = JSON.parse(text()); be.load(be.scenario); }
            catch (e) { be.failed("mock fixture unreadable (" + e + ")"); }
        }
        onLoadFailed: be.failed("mock fixture missing at " + be.dir)
    }
    function load(name) {
        var sc = fixture && fixture.scenarios[name];
        if (!sc) { note("no scenario " + name); return; }
        scenario = name;
        monitorWidth = fixture.monitor[0];
        monitorHeight = fixture.monitor[1];
        activeDesk = sc.active;
        windows = sc.windows.map(function (w) { return Object.assign({}, w); });
        var best = "", rank = 1e9;
        for (var i = 0; i < windows.length; i++) if (windows[i].desk === activeDesk && windows[i].focusRank < rank) { rank = windows[i].focusRank; best = windows[i].id; }
        focusedId = best;
        ready = true;
    }

    // One screen (the stage's or the test's), block 0 from the shown desk; every existing desk on it.
    readonly property var desks: deskIds()
    readonly property var deskFacts: ({ slots: 10, blocks: {}, screens: [{ name: screenName, shown: activeDesk }],
                                        desks: desks.map(function (d) { return { id: d, screen: be.screenName }; }) })

    // ---- facts helpers ------------------------------------------------------------
    function deskIds() {
        var seen = {}, out = [];
        for (var i = 0; i < windows.length; i++) if (!seen[windows[i].desk]) { seen[windows[i].desk] = true; out.push(windows[i].desk); }
        if (!seen[activeDesk]) out.push(activeDesk);
        return out.sort(function (a, b) { return a - b; });
    }
    function winIndex(id) { for (var i = 0; i < windows.length; i++) if (windows[i].id === id) return i; return -1; }

    // ---- existing actions -------------------------------------------------------------
    function focusWindow(id) {
        var i = winIndex(id);
        if (i >= 0) { activeDesk = windows[i].desk; focusedId = id; }
        note("focus " + id);
    }
    function goToDesk(n) { activeDesk = n; focusedId = ""; note("desk " + n); }
    function closeWindow(id) { windows = windows.filter(function (w) { return w.id !== id; }); note("close " + id); }

    // ---- ops (SPEC 3.4 semantics, all-or-nothing), answered after `delayMs` -------
    property int seqNext: 1
    property string failMode: ""        // "" none · "all" · "next" (one op) · an op name
    property int delayMs: 25
    property var queue: []              // [{ seq, at, apply: fn, why }]
    function enqueue(opName, logLine, apply) {
        var seq = seqNext++;
        noteOp(logLine);
        var fail = failMode === "all" || failMode === "next" || failMode === opName;
        if (failMode === "next") failMode = "";
        var q = queue.slice();
        q.push({ seq: seq, at: Date.now() + delayMs, apply: fail ? null : apply, why: fail ? "injected failure" : "" });
        queue = q;
        answer.interval = Math.max(1, delayMs);
        if (!answer.running) answer.start();
        return seq;
    }
    Timer {
        id: answer
        repeat: true
        onTriggered: {
            var now = Date.now(), keep = [], due = [];
            for (var i = 0; i < be.queue.length; i++) (be.queue[i].at <= now + 1 ? due : keep).push(be.queue[i]);
            be.queue = keep;
            if (!keep.length) answer.stop();
            for (i = 0; i < due.length; i++) {
                var d = due[i], ok = false, why = d.why;
                if (d.apply) { var r = d.apply(); ok = r === true; if (!ok) why = String(r); }
                be.opResult(d.seq, ok, why);
            }
        }
    }
    function moveRaw(id, n) {
        var i = winIndex(id);
        if (i < 0) return "no such window";
        if (n < 1) return "bad desk";
        var c = windows.slice(), w = Object.assign({}, c[i]);
        w.desk = n; c[i] = w; windows = c;
        return true;
    }
    function moveToDesk(id, n) { return enqueue("move", "move " + id + "→" + n, function () { return be.moveRaw(id, n); }); }
    // desk: the number the "New desk" tile showed (default max + 1), as ovops.newdesk.
    function newDesk(id, desk) {
        var d = desk === undefined || desk === null ? null : Number(desk);
        return enqueue("newdesk", "newdesk " + id + (d ? " " + d : ""), function () {
            var S = be.deskIds();
            if (d !== null && S.indexOf(d) >= 0) return "taken";
            return be.moveRaw(id, d !== null ? d : S[S.length - 1] + 1);
        });
    }
    // order[i] = old id that should sit at position i of the sorted positions (default: the existing desks; SPEC 3.4).
    // A position with no desk is a gap that moves like a desk, as in ovops.reorder.
    function reorder(order, positions) {
        var o = Array.prototype.slice.call(order || []).map(Number);
        var P = positions ? Array.prototype.slice.call(positions).map(Number).sort(function (a, b) { return a - b; }) : null;
        return enqueue("reorder", "reorder [" + o.join(",") + "]" + (P ? " of [" + P.join(",") + "]" : ""), function () {
            var S = P || be.deskIds();
            if (o.length !== S.length || o.slice().sort(function (a, b) { return a - b; }).join() !== S.join()) return "invalid";
            var map = {};
            for (var i = 0; i < S.length; i++) map[o[i]] = S[i];
            be.windows = be.windows.map(function (w) { var c = Object.assign({}, w); c.desk = map[w.desk]; return c; });
            be.activeDesk = map[be.activeDesk];
            return true;
        });
    }
    // last: the highest desk the strip shows; with it, every desk from right to last moves up one (ovops.insert).
    function insertDesk(left, right, id, last) {
        var r = right === undefined || right === null || right === "" || right < 0 ? null : Number(right);
        var z = last === undefined || last === null ? Infinity : Number(last);
        return enqueue("insert", "insert " + left + "|" + (r === null ? "end" : r) + " " + id, function () {
            var S = be.deskIds();
            if (r === null) return be.moveRaw(id, S[S.length - 1] + 1);
            for (var k = Number(left) + 1; k < r; k++) if (S.indexOf(k) < 0) return be.moveRaw(id, k);
            // no free number between: shift every id from right (to last) up by one, then move into right
            be.windows = be.windows.map(function (w) { var c = Object.assign({}, w); if (c.desk >= r && c.desk <= z) c.desk++; return c; });
            if (be.activeDesk >= r && be.activeDesk <= z) be.activeDesk++;
            return be.moveRaw(id, r);
        });
    }
    function heal() {
        var S = deskIds(), changed = false;
        for (var i = 0; i < S.length; i++) if (S[i] >= 100000) {
            var free = 1; while (S.indexOf(free) >= 0) free++;
            var from = S[i];
            windows = windows.map(function (w) { var c = Object.assign({}, w); if (c.desk === from) c.desk = free; return c; });
            S = deskIds(); changed = true;
        }
        if (changed) noteOp("heal");
    }

    // ---- stream -----------------------------------------------------------------------
    property bool pingBroken: false
    property int pings: 0
    function ping() {
        pings++;
        var ok = !pingBroken;
        pingBroken = false;
        Qt.callLater(function () { be.pingResult(ok); });
        return true;
    }
    property int fed: 0
    function feed(line) {
        var ev = G.parseLine(line);
        if (!ev) return false;
        fed++;
        if (ev.kind === "b") strokeBegin(ev.fingers, ev.dir, ev.acc, ev.tMs);
        else if (ev.kind === "u") strokeUpdate(ev.acc, ev.tMs);
        else if (ev.kind === "e") strokeEnd(ev.acc, ev.tMs, ev.cancelled);
        else if (ev.kind === "hello") hello();
        return true;
    }
    // On the stage the stream may also come through the compositor's event socket, as in real use.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "custom" && String(event.data).indexOf("ovg,") === 0) be.feed(event.data);
        }
    }
    // A synthetic stroke at the pad's 7 ms frames, coalesced to >= 12 ms like the real Lua side.
    property var synth: null
    function stroke(mm, ms, cancelled) {
        var now = Date.now();
        synth = { mm: Number(mm), ms: Math.max(14, Number(ms)), cancelled: !!cancelled, t0: now, sent: now };
        feed("ovg,b,3," + (mm >= 0 ? "UP" : "DOWN") + ",0.00," + now);
        synthTimer.start();
    }
    Timer {
        id: synthTimer
        interval: 7; repeat: true
        onTriggered: {
            var s = be.synth, now = Date.now(), k = Math.min(1, (now - s.t0) / s.ms);
            if (k >= 1) { synthTimer.stop(); be.feed("ovg,e," + s.mm.toFixed(2) + "," + now + "," + (s.cancelled ? 1 : 0)); be.synth = null; return; }
            if (now - s.sent >= 12) { s.sent = now; be.feed("ovg,u," + (s.mm * k).toFixed(2) + "," + now); }
        }
    }

    readonly property var byId: {
        var m = {};
        for (var i = 0; i < windows.length; i++) m[windows[i].id] = windows[i];
        return m;
    }
    property Component thumbnail: Component {
        Image {
            property string winId: ""
            property bool capturing: false
            readonly property bool ready: status === Image.Ready
            readonly property bool pending: capturing && status === Image.Loading
            function refresh() {}
            readonly property var w: be.byId[winId] || null
            // Decoded once and kept: a real capture arrives within a frame or two, a
            // fresh decode of a 4K PNG would not, and would misrepresent the motion.
            source: w ? "file://" + be.dir + "/pics/" + w.picture : ""
            sourceSize.width: 1600
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
        }
    }

    IpcHandler {
        target: "overview-mock"
        function scenario(name: string): void { be.load(name); }
        function fail(): void { be.failed("simulated back-end failure"); }
        function state(): string {
            return JSON.stringify({ scenario: be.scenario, activeDesk: be.activeDesk, focused: be.focusedId, windows: be.windows.length,
                                    desks: be.deskIds(), where: be.windows.map(function (w) { return w.id + "@" + w.desk; }),
                                    ops: be.ops, log: be.log.slice(-30), pings: be.pings, fed: be.fed });
        }
        function failop(mode: string): void { be.failMode = mode === "none" ? "" : mode; be.note("failop " + mode); }
        function delay(ms: string): void { be.delayMs = Math.max(0, parseInt(ms) || 0); }
        function pingfail(on: string): void { be.pingBroken = on === "true" || on === "1"; }
        function stroke(mm: string, ms: string, cancelled: string): void { be.stroke(Number(mm), Number(ms), cancelled === "1" || cancelled === "true"); }
        function oplog(): string { return JSON.stringify(be.ops); }
        // His native 3-finger sideways swipe (or any desk change from outside the overview).
        function desk(n: string): void { be.goToDesk(parseInt(n)); }
        function clearlog(): void { be.ops = []; be.log = []; }
    }
}
