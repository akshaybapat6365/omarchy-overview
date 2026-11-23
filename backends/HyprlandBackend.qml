pragma ComponentBehavior: Bound
// The real desktop (SPEC 3.2-3.4). Owner: lane 1.
//
// Facts come from Quickshell's own Hyprland model (Hyprland.toplevels / workspaces / monitors and their
// lastIpcObject), refreshed over Quickshell's request socket on changes of structure only: no program is
// started to read the desktop, and a title change costs nothing but a re-sort of what is already here.
// The gesture stream arrives on the same event socket as "custom>>ovg,..." and is handled before anything
// else. Desk and window operations run inside Hyprland, all-or-nothing, through ops/ovops.lua: one
// /usr/bin/hyprctl per drop (Ops.js builds and checks the command).
//
// FROZEN INTERFACE (SPEC 4.1), shared with MockBackend.qml:
//   signals   strokeBegin(fingers, dir, acc, tMs)  strokeUpdate(acc, tMs)  strokeEnd(acc, tMs, cancelled)
//             hello()  opResult(seq, ok, why)  pingResult(ok)  failed(why)  toggleRequested()  closeRequested()
//             (acc = millimetres of finger travel since the stroke began, positive = up; addendum L6)
//   functions reorder(orderIds) -> seq   moveToDesk(winId, desk) -> seq   insertDesk(leftId, rightId, winId) -> seq
//             newDesk(winId) -> seq   heal() -> seq   ping() -> bool (answer: pingResult within 500 ms)
//             feed(line)  (an "ovg,..." line into the same parser, for tests)   prepare()
//             focusWindow(id)  goToDesk(n)  closeWindow(id)
//   facts     windows [{ id, desk, x, y, w, h, title, appClass, focusRank, fullscreen, floating }] relative to their monitor
//             desks [ids]  (sorted ordinary desks that exist, empty visible ones included)
//             deskFacts { slots, blocks: { connector: block }, screens: [{ name, shown }], desks: [{ id, screen }] }
//                         what Desks.forScreen needs to list exactly the bar's desks (the strip shows nothing else)
//             activeDesk  monitorWidth  monitorHeight  screenName  ready  rounding  thumbnail
//   test IPC  qs ipc call overview-backend facts | stats | lastOp | ping | reorder "1,3,2" | move <addr> <desk>
//             | insert <left> <right, 0 = after the last> <addr> | newdesk <addr> | heal
//   privacy   nothing logged or answered over IPC carries a window title (amendment A3)
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../Ops.js" as Ops
import "../Desks.js" as Desks

Item {
    id: be
    signal failed(string why)
    signal toggleRequested()
    signal closeRequested()
    signal strokeBegin(int fingers, string dir, real acc, real tMs)
    signal strokeUpdate(real acc, real tMs)
    signal strokeEnd(real acc, real tMs, bool cancelled)
    signal hello()
    signal opResult(int seq, bool ok, string why)
    signal pingResult(bool ok)

    // ---- the facts the host reads ---------------------------------------------
    property var windows: []
    property var desks: []
    property var deskFacts: ({ slots: 10, blocks: {}, screens: [], desks: [] })
    readonly property int activeDesk: Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id
                                    : (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1)
    property real monitorWidth: 2400    // logical size of the focused monitor
    property real monitorHeight: 1500
    readonly property string screenName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    property bool ready: false
    property bool watching: false       // set by the host while the overview is on screen
    property real rounding: 12          // the desktop's window corner radius, read once at start and after a reload

    // Counters for status and the stage tests (no titles).
    property var counts: ({ hello: 0, strokes: 0, updates: 0, ends: 0, badEvents: 0, refreshes: 0, rebuilds: 0, programs: 0, ops: 0, opsFailed: 0, pings: 0, pingsLost: 0 })
    function bump(k) { counts[k] = (counts[k] || 0) + 1; if (k === "programs") forks++; }
    property int forks: 0               // programs this back end started (status "forks"; SPEC 3.7)

    // The overview is opening: one fresh read, without waiting for it; heal a leftover temporary desk id.
    function prepare() {
        refreshNow();
        var wss = Hyprland.workspaces.values;
        for (var i = 0; i < wss.length; i++) if (deskId(wss[i]) >= 100000) { heal(); break; }
    }

    // Hyprland reaches the overview through these without starting a program
    // (hl.dsp.global("omarchy-overview:toggle"): the key, and the one-shot swipes when the stream is not loaded).
    GlobalShortcut { appid: "omarchy-overview"; name: "toggle"; description: "Open or close the overview"; onPressed: be.toggleRequested() }
    GlobalShortcut { appid: "omarchy-overview"; name: "close"; description: "Close the overview"; onPressed: be.closeRequested() }

    Process {
        id: roundingProc
        command: [Ops.HYPRCTL, "-j", "getoption", "decoration:rounding"]
        onStarted: be.bump("programs")
        stdout: StdioCollector {
            onStreamFinished: { try { var o = JSON.parse(text); if (typeof o.int === "number") be.rounding = o.int; } catch (e) {} }
        }
    }

    // Which block of ten desk numbers each screen owns: Omarchy's own file, read the way its bar reads it.
    property var blocks: ({})
    FileView {
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: be.readBlocks(text())
        onLoadFailed: be.readBlocks("")
    }
    function readBlocks(text) {
        var next = {}, lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length >= 3 && f[1] !== "") next[f[1]] = parseInt(f[0], 10);
        }
        blocks = next;
        rebuildLater();
    }

    // ---- the event socket ------------------------------------------------------------
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            var n = event.name;
            // Any event at all after a ping proves the event socket is alive (it is busiest exactly when opening).
            if (pingTimer.running) be.pingAnswered();
            // The gesture stream first, and nothing else for it: ~71 events a second while the fingers move.
            if (n === "custom") { be.parse(String(event.data)); return; }
            switch (n) {
            case "openwindow": case "closewindow": case "movewindowv2": case "changefloatingmode": case "fullscreen":
            case "createworkspacev2": case "destroyworkspacev2": case "changeworkspaceid": case "moveworkspacev2":
            case "workspacev2": case "focusedmonv2":
                be.refreshSoon(); return;
            case "configreloaded":            // Quickshell reloads its model itself (and monitors coming and going)
                roundingProc.running = true; return;
            case "activewindowv2":
                if (be.watching) be.refreshSoon();   // focus order, for the grid; a socket request, no program
                return;
            case "windowtitlev2":
                if (be.watching) titleTimer.restart();   // Quickshell already holds the new title
                return;
            }
        }
    }

    // ovg,hello | ovg,b,<fingers>,<DIR>,<mm>,<t> | ovg,u,<mm>,<t> | ovg,e,<mm>,<t>,<0|1> | ovg,ping,<n>
    function parse(data) {
        if (data.lastIndexOf("ovg,", 0) !== 0) return;
        var f = data.split(",");
        switch (f[1]) {
        case "u":
            if (f.length === 4) { bump("updates"); strokeUpdate(+f[2], +f[3]); return; }
            break;
        case "b":
            if (f.length === 6) { bump("strokes"); strokeBegin(parseInt(f[2], 10), f[3].toUpperCase(), +f[4], +f[5]); return; }
            break;
        case "e":
            if (f.length === 5) { bump("ends"); strokeEnd(+f[2], +f[3], f[4] === "1"); return; }
            break;
        case "hello":
            bump("hello"); hello(); return;
        case "ping":
            return;                          // answered by any event (pingAnswered), this one included
        }
        bump("badEvents");
    }
    function feed(line) { var s = String(line); parse(s.lastIndexOf("custom>>", 0) === 0 ? s.slice(8) : s); }

    // Self-check (SPEC 3.2): is our event socket still connected? The ping's own event (or any other) must come
    // back on it within 500 ms. A miss is asked again once before it counts: a busy first open can delay the
    // reading of the socket past 500 ms while the socket is fine (review, interaction).
    property int pingSeq: 0
    property int pingTries: 0
    function ping() {
        pingTries = 0;
        sendPing();
        return true;
    }
    function sendPing() {
        pingSeq += 1;
        pingTries += 1;
        bump("pings");
        pingTimer.restart();
        Hyprland.dispatch('hl.dsp.event("ovg,ping,' + pingSeq + '")');
    }
    function pingAnswered() { pingTimer.stop(); pingTries = 0; pingResult(true); }
    Timer {
        id: pingTimer; interval: 500
        onTriggered: {
            be.bump("pingsLost");
            if (be.pingTries < 2) { console.warn("overview: ping " + be.pingSeq + " unanswered; asking once more"); be.sendPing(); return; }
            console.warn("overview: socket2 lost (pings " + (be.pingSeq - 1) + " and " + be.pingSeq + " unanswered)");
            be.pingResult(false);
        }
    }

    // ---- facts without programs (SPEC 3.3) -----------------------------------------
    function refreshNow() {
        bump("refreshes");
        Hyprland.refreshMonitors();
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
    }
    function refreshSoon() { refreshTimer.restart(); }
    Timer { id: refreshTimer; interval: 40; onTriggered: be.refreshNow() }
    Timer { id: titleTimer; interval: 250; onTriggered: be.rebuild() }
    function rebuildLater() { Qt.callLater(be.rebuild); }

    // Every answer of a refresh lands in lastIpcObject; one rebuild per batch.
    Instantiator {
        model: Hyprland.toplevels
        delegate: Connections {
            required property var modelData
            target: modelData
            function onLastIpcObjectChanged() { be.rebuildLater(); }
            function onWorkspaceChanged() { be.rebuildLater(); }
        }
    }
    Instantiator {
        model: Hyprland.monitors
        delegate: Connections {
            required property var modelData
            target: modelData
            function onLastIpcObjectChanged() { be.rebuildLater(); }
        }
    }
    Connections { target: Hyprland.toplevels; function onValuesChanged() { be.rebuildLater(); } }
    Connections { target: Hyprland.workspaces; function onValuesChanged() { be.rebuildLater(); } }

    // One rebuild of windows and desks from Quickshell's model. While an operation is in flight the model passes
    // through temporary desk ids (100000+); nothing is rebuilt then, so the overview never draws one.
    property int opsInFlight: 0
    property bool rebuildPending: false
    property string lastRebuildError: ""
    Timer { id: settleTimer; interval: 60; onTriggered: if (be.rebuildPending) be.rebuild() }
    property var skipped: ({})
    function rebuild() {
        if (opsInFlight > 0 || settleTimer.running) { rebuildPending = true; return; }
        rebuildPending = false;
        bump("rebuilds");
        try { rebuildModel(); } catch (e) {
            lastRebuildError = String(e && e.message || e);
            console.warn("overview: facts not rebuilt: " + lastRebuildError);
        }
    }
    // A desk's number: Hyprland's own answer (lastIpcObject, refreshed after every change of structure) first,
    // Quickshell's live property when no answer has come yet.
    function deskId(ws) {
        var o = ws ? ws.lastIpcObject : null;
        if (o && typeof o.id === "number") return o.id;
        return ws && typeof ws.id === "number" ? ws.id : 0;
    }
    function deskOfWindow(tl, c) {
        if (c && c.workspace && typeof c.workspace.id === "number") return c.workspace.id;
        return tl.workspace ? be.deskId(tl.workspace) : 0;
    }
    function rebuildModel() {
        var skip = { noIpc: 0, unmapped: 0, hidden: 0, special: 0, tempDesk: 0 };
        var mons = Hyprland.monitors.values, byId = {}, i;
        for (i = 0; i < mons.length; i++) {
            var mo = mons[i].lastIpcObject || {};
            byId[mons[i].id] = mons[i];
            if (mons[i] === Hyprland.focusedMonitor) {
                var rot = ((mo.transform || 0) % 2) === 1, sc = mons[i].scale || 1;
                if (mons[i].width > 0) {
                    monitorWidth = (rot ? mons[i].height : mons[i].width) / sc;
                    monitorHeight = (rot ? mons[i].width : mons[i].height) / sc;
                }
            }
        }
        var tls = Hyprland.toplevels.values, out = [];
        for (i = 0; i < tls.length; i++) {
            var tl = tls[i], c = tl.lastIpcObject;
            if (!c || !c.address) { skip.noIpc++; continue; }     // not read yet: the refresh is on its way
            var desk = be.deskOfWindow(tl, c);
            // Ordinary desks only: special workspaces (scratchpads), hidden windows and a desk left on a temporary
            // id (healed on the next open) stay out.
            if (!c.mapped) { skip.unmapped++; continue; }
            if (c.hidden) { skip.hidden++; continue; }
            if (desk < 1) { skip.special++; continue; }
            if (desk >= 100000) { skip.tempDesk++; continue; }
            var m = byId[c.monitor] || { x: 0, y: 0 };
            out.push({ id: c.address, desk: desk, x: c.at[0] - m.x, y: c.at[1] - m.y, w: c.size[0], h: c.size[1],
                       title: tl.title || c["class"] || "", appClass: c["class"] || c.initialClass || "",
                       focusRank: c.focusHistoryID === undefined ? 99 : c.focusHistoryID,
                       fullscreen: (c.fullscreen || 0) > 0, floating: !!c.floating });
        }
        var wss = Hyprland.workspaces.values, ids = [], seen = {}, where = [];
        for (i = 0; i < wss.length; i++) {
            var d = be.deskId(wss[i]), wo = wss[i].lastIpcObject || {};
            var on = typeof wo.monitor === "string" ? wo.monitor : (wss[i].monitor ? wss[i].monitor.name : "");
            if (d > 0 && d < 100000 && !seen[d]) { seen[d] = true; ids.push(d); where.push({ id: d, screen: on }); }
        }
        var screens = [];
        for (i = 0; i < mons.length; i++) {
            var mi = mons[i].lastIpcObject || {};
            var shown = mi.activeWorkspace && typeof mi.activeWorkspace.id === "number" ? mi.activeWorkspace.id
                      : (mons[i].activeWorkspace ? be.deskId(mons[i].activeWorkspace) : -1);
            screens.push({ name: mons[i].name, shown: shown });
        }
        for (i = 0; i < out.length; i++) if (!seen[out[i].desk]) { seen[out[i].desk] = true; ids.push(out[i].desk); }
        ids.sort(function (a, b) { return a - b; });
        windows = out;
        desks = ids;
        deskFacts = { slots: 10, blocks: blocks, screens: screens, desks: where };
        skipped = skip;
        ready = true;
    }
    // No refresh here: Quickshell loads the whole model itself once it has connected, with refreshes that may
    // create monitors and desks. A refresh asked from QML may not create, and while one is in flight Quickshell
    // drops its own: asked this early, it left the stage with no monitor and every desk numbered -1 (run
    // lane-1-20261119-203634).
    Component.onCompleted: roundingProc.running = true

    // Which fields the UI needs are present in Quickshell's copy of each window (experiment E7). Counts only.
    readonly property var neededFields: ["address", "at", "size", "workspace", "floating", "fullscreen", "class", "title", "focusHistoryID", "pinned", "monitor", "mapped", "hidden"]
    function facts() {
        rebuild();
        var tls = Hyprland.toplevels.values, missing = {}, withIpc = 0;
        for (var i = 0; i < tls.length; i++) {
            var c = tls[i].lastIpcObject;
            if (!c || !c.address) continue;
            withIpc++;
            for (var k = 0; k < neededFields.length; k++) if (c[neededFields[k]] === undefined) missing[neededFields[k]] = (missing[neededFields[k]] || 0) + 1;
        }
        return { toplevels: tls.length, withIpc: withIpc, missing: missing, windows: windows.length, desks: desks, activeDesk: activeDesk,
                 monitor: [monitorWidth, monitorHeight], ready: ready, skipped: skipped, rebuildError: lastRebuildError,
                 model: [Hyprland.monitors.values.length, Hyprland.workspaces.values.length, tls.length], probe: probe() };
    }
    // Numbers only (no names, no titles): what Quickshell's objects say against Hyprland's answers.
    function probe() {
        var w = Hyprland.workspaces.values, t = Hyprland.toplevels.values, a = [], b = [], i;
        for (i = 0; i < w.length; i++) a.push([w[i].id, w[i].lastIpcObject ? w[i].lastIpcObject.id : null]);
        for (i = 0; i < Math.min(3, t.length); i++) {
            var c = t[i].lastIpcObject || {};
            b.push([t[i].workspace ? t[i].workspace.id : null, c.workspace ? c.workspace.id : null]);
        }
        return { workspaces: a, toplevels: b, focusedMonitor: !!Hyprland.focusedMonitor };
    }

    // ---- acting --------------------------------------------------------------------
    function dispatch(lua, legacy) { Hyprland.dispatch(Hyprland.usingLua ? lua : legacy); }
    function focusWindow(id) { dispatch("hl.dsp.focus({ window = 'address:" + id + "' })", "focuswindow address:" + id); }
    // A desk of the focused screen's own block goes through Omarchy's helper, exactly as the bar's click does
    // (o.workspaces.focus(slot, screen): it also brings the desk back from another screen); any other desk, or a
    // desktop without that helper, through the plain focus, as the bar does for a guest.
    function goToDesk(n) {
        var name = screenName, plain = "hl.dsp.focus({ workspace = '" + n + "' })";
        if (Hyprland.usingLua && /^[A-Za-z0-9_.-]+$/.test(name) && Desks.blockOf(n) === Desks.screenBlock(deskFacts, name)) {
            Hyprland.dispatch("(o and o.workspaces and o.workspaces.focus and o.workspaces.focus(" + Desks.slotOf(n) + ", '" + name + "')) or " + plain);
            return;
        }
        dispatch(plain, "workspace " + n);
    }
    // The window goes in a table: a bare string is ignored by Hyprland's Lua
    // dispatcher, which then closes whichever window has the focus.
    function closeWindow(id) { dispatch("hl.dsp.window.close({ window = 'address:" + id + "' })", "closewindow address:" + id); }

    // Desk and window operations: one program per drop, all-or-nothing inside Hyprland (ops/ovops.lua).
    readonly property string shellDir: String(Quickshell.shellDir).replace(/^file:\/\//, "")
    property int seq: 0
    property string lastOp: ""
    // positions (optional): the strip's own desks, empty ones included; order is a permutation of them (Ops.js).
    function reorder(orderIds, positions) { return runOp(Ops.reorder(shellDir, orderIds, positions), "reorder [" + orderIds + "]" + (positions ? " of [" + positions + "]" : "")); }
    function moveToDesk(winId, desk) { return runOp(Ops.move(shellDir, winId, desk), "move " + winId + " to " + desk); }
    function insertDesk(leftId, rightId, winId, last) { return runOp(Ops.insert(shellDir, leftId, rightId, winId, last), "insert " + leftId + "|" + rightId + " " + winId + (last ? " to " + last : "")); }
    function newDesk(winId, desk) { return runOp(Ops.newdesk(shellDir, winId, desk), "newdesk " + winId + (desk ? " " + desk : "")); }
    function heal() { return runOp(Ops.heal(shellDir), "heal", true); }

    // One op at a time: while one runs, and for the 60 ms its events take to land, the desk model is stale, and a
    // second op built from it would undo the first (review, compositor: two quick Alt+Shift+Right). The scene waits
    // for the model before it sends the next; anything that does not is refused here, nothing changed. A heal
    // (after a failed op's re-read) is never refused.
    readonly property bool busy: opsInFlight > 0 || settleTimer.running
    function runOp(argv, label, always) {
        seq += 1;
        var s = seq;
        if (!argv) { Qt.callLater(be.finishOp, s, label, Ops.parseReply("fail,0,invalid"), 0, false); return s; }
        if (busy && !always) { Qt.callLater(be.finishOp, s, label, Ops.parseReply("fail,0,busy"), 0, false); return s; }
        opsInFlight += 1;
        opRunner.createObject(be, { opSeq: s, label: label, command: argv, started: Date.now() });
        return s;
    }
    function finishOp(s, label, r, ms, ran) {
        if (ran) opsInFlight = Math.max(0, opsInFlight - 1);
        bump("ops");
        if (!r.ok) bump("opsFailed");
        lastOp = label + " " + (r.ok ? "ok" : "fail " + r.step + " " + r.why) + (r.data && r.data.steps !== undefined ? " steps " + r.data.steps : "") + " " + ms + " ms";
        console.info("overview-op: " + lastOp);
        // Re-read the model once the op is over: what the overview shows must be true. Every event of the op was
        // written before its reply, but may still be on its way through the socket: hold 60 ms, then rebuild.
        refreshNow();
        if (ran) settleTimer.restart();
        opResult(s, r.ok, r.why);
    }
    Component {
        id: opRunner
        Process {
            id: proc
            property int opSeq
            property string label
            property real started
            property string reply: ""
            property bool outDone: false
            property int code: -1
            property bool settled: false
            running: true
            onStarted: be.bump("programs")
            stdout: StdioCollector { onStreamFinished: { proc.reply = text; proc.outDone = true; proc.settle(); } }
            onExited: function (exitCode) { proc.code = exitCode; proc.settle(); }
            function settle() {
                if (settled || code < 0 || !outDone) return;
                settled = true;
                timeout.stop();
                be.finishOp(opSeq, label, Ops.parseReply(reply), Date.now() - started, true);
                destroy();
            }
            property Timer timeout: Timer {
                interval: 2000; running: true
                onTriggered: {
                    if (proc.settled) return;
                    proc.settled = true;
                    proc.running = false;
                    be.finishOp(proc.opSeq, proc.label, Ops.parseReply("fail,0,timeout"), Date.now() - proc.started, true);
                    proc.destroy();
                }
            }
        }
    }

    IpcHandler {
        target: "overview-backend"
        function facts(): string { return JSON.stringify(be.facts()); }
        function stats(): string { return JSON.stringify({ counts: be.counts, lastOp: be.lastOp, seq: be.seq }); }
        function lastOp(): string { return be.lastOp; }
        function ping(): bool { return be.ping(); }
        function reorder(order: string): int { return be.reorder(order.split(",").map(function (x) { return x.trim(); })); }
        function move(addr: string, desk: int): int { return be.moveToDesk(addr, desk); }
        function insert(left: int, right: int, addr: string): int { return be.insertDesk(left, right > 0 ? right : null, addr); }
        function newdesk(addr: string): int { return be.newDesk(addr); }
        function heal(): int { return be.heal(); }
    }

    // ---- pictures: the window's own buffer through the toplevel export -------
    // One frame when the overview opens, then one more each time refresh() is
    // called. Never a live stream: see Scene.qml.
    readonly property var toplevels: {
        var map = {}, all = ToplevelManager.toplevels.values;
        for (var i = 0; i < all.length; i++) {
            var h = all[i].HyprlandToplevel;
            if (h && h.address) map["0x" + h.address] = all[i];
        }
        return map;
    }
    property Component thumbnail: Component {
        ScreencopyView {
            property string winId: ""
            property bool capturing: false
            readonly property bool ready: hasContent
            readonly property bool pending: captureSource !== null && !hasContent
            function refresh() { if (captureSource !== null) captureFrame(); }
            captureSource: capturing ? (be.toplevels[winId] || null) : null
            live: false
            paintCursor: false
        }
    }
}
