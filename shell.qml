// Overview: what three fingers up shows. Every open window, every desk, one move to anywhere.
//
// The host only: the full-screen layer surface, keyboard focus, the remote
// control, the theme colours and the safety exits. The picture is Scene.qml
// (pure QML); the facts come from a back end:
//   backends/HyprlandBackend.qml   the real desktop (default)
//   backends/MockBackend.qml       a fixed desktop for off-screen tests (OVERVIEW_BACKEND=mock)
//
//   hl.dsp.global("omarchy-overview:toggle" | "omarchy-overview:close")   (the swipe and the key: no program is started)
//   qs -c overview ipc call overview toggle | open | close | status      (the overview command; status is one line of JSON)
//   … status | trace | feed <ovg line> | drag <kind> <id> <x> <y> <phase>     (test hooks, SPEC 4.1; never a window title)
//
// Strokes: the back end turns each socket2 "custom>>ovg,…" line into strokeBegin /
// strokeUpdate / strokeEnd; this host only maps the surface when the scene has
// something to draw and hands the keyboard over once an open is decided (SPEC 2.1
// Focus). While fingers move, the surface takes no keyboard and, opening, no pointer.
//
// Layer namespace "omarchy-overview": looknfeel.lua tells Hyprland not to
// animate it, because the overview draws its own opening and closing.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "Gesture.js" as G
import "Desks.js" as Desks

ShellRoot {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property bool mock: Quickshell.env("OVERVIEW_BACKEND") === "mock"

    // ---- back end ---------------------------------------------------------
    Loader {
        id: backendLoader
        source: root.mock ? "backends/MockBackend.qml" : "backends/HyprlandBackend.qml"
        onStatusChanged: if (status === Loader.Error) console.log("overview: back end failed to load")
    }
    readonly property var backend: backendLoader.item
    Connections {
        target: root.backend
        function onFailed(why) {
            console.log("overview: " + why + (root.mapped ? "; closing" : ""));
            if (root.mapped) root.hardClose();
        }
        function onToggleRequested() { root.toggle(); }
        function onCloseRequested() { root.close(); }
    }
    // The stream and the op answers (SPEC 4.1). Older back ends lack some of these signals.
    Connections {
        target: root.backend
        ignoreUnknownSignals: true
        // A stroke drives the scene of the screen in focus (a scene already on screen keeps it to the end).
        function onStrokeBegin(fingers, dir, acc, tMs) { root.eachMine(function (s) { s.strokeBegin(fingers, dir, acc, tMs); }); }
        function onStrokeUpdate(acc, tMs) { root.eachMine(function (s) { s.strokeUpdate(acc, tMs); }); }
        function onStrokeEnd(acc, tMs, cancelled) { root.strokeEnded(acc, tMs, cancelled); }
        function onHello() { root.hellos++; }
        function onOpResult(seq, ok, why) { root.each(function (s) { s.opDone(seq, ok, why); }); }
        function onPingResult(ok) {
            if (ok) { root.pingOk++; return; }
            // socket2 is gone (two pings in a row unanswered): no stroke can reach us. Exit 75 and systemd's
            // Restart=always brings us back connected, but never from under his hand: while the overview is on
            // screen it stays usable (keys, pointer, IPC) and the exit waits for it to close.
            root.each(function (s) { s.settleStroke("socket lost"); });
            if (root.mapped) { root.exitWhenClosed = true; console.log("overview: socket2 lost; restarting once the overview closes"); return; }
            console.log("overview: socket2 lost; exiting 75 so the service restarts connected");
            Qt.exit(75);
        }
    }
    function strokeEnded(acc, tMs, cancelled) {
        each(function (s) { s.strokeEnd(acc, tMs, cancelled); });
        var s0 = mainScene();
        // One journal line per stroke: numbers only (SPEC 8).
        if (s0 && s0.stats.decisionLast) console.log("overview: stroke " + s0.stats.decisionLast + " events " + s0.stats.eventsLastStroke
                                                    + " maxgap " + s0.stats.maxGapMsLastStroke + " ms, " + s0.stats.mmLastStroke.toFixed(1) + " mm");
    }
    // A reload ends a live stroke where it is (its "finish" may never come).
    Connections {
        target: Hyprland
        function onRawEvent(event) { if (event.name === "configreloaded") root.each(function (s) { s.settleStroke("reload"); }); }
    }
    function each(fn) { for (var i = 0; i < scenes.length; i++) if (scenes[i]) fn(scenes[i]); }
    // The scene of the screen in focus, plus any scene that is already up (it finishes what it started).
    function eachMine(fn) { for (var i = 0; i < scenes.length; i++) if (scenes[i] && (scenes[i].mine || scenes[i].isOpen)) fn(scenes[i]); }
    // The one scene status, trace and the drag hook speak for: the open one, else the focused screen's.
    function mainScene() {
        var i, m = null;
        for (i = 0; i < scenes.length; i++) if (scenes[i] && scenes[i].isOpen) return scenes[i];
        for (i = 0; i < scenes.length; i++) if (scenes[i] && scenes[i].mine) return scenes[i];
        return scenes.length ? scenes[0] : null;
    }
    property bool exitWhenClosed: false
    property int hellos: 0
    property int pingOk: 0
    property int pings: 0
    property int forks: 0

    // ---- open / close -------------------------------------------------------
    property bool mapped: false         // the overview covers the screen (closed, its surface is one idle pixel)
    onMappedChanged: if (backend) backend.watching = mapped
    property bool interactive: false    // it holds the keyboard and the pointer (only after an open is decided)
    property double openedAt: 0

    function open() {
        if (!backend || (mapped && interactive)) return;
        interactive = true;
        eachMine(function (s) { s.open(); });
    }
    function close() {
        if (!mapped) return;
        interactive = false;                // keys and clicks go back to the desktop at once
        closeKind = "back";
        each(function (s) { s.close("back"); });
    }
    function hardClose() {
        interactive = false;
        each(function (s) { s.snapShut(); });
        unmap();
    }
    function toggle() { if (mapped && interactive) close(); else open(); }
    function anyOpen() { for (var i = 0; i < scenes.length; i++) if (scenes[i] && scenes[i].isOpen) return true; return false; }
    property var scenes: []

    // A scene is about to draw: map the surface, read fresh facts, check the event socket.
    // byStroke: the stroke's own first event came over the event socket, which proves it is alive: no ping.
    function show(byStroke) {
        if (mapped) return;
        backend.prepare();
        refreshWallpaper();
        openedAt = Date.now();
        focusAtOpen = focusedAddress();
        closeKind = "";
        mapped = true;
        if (!byStroke && typeof backend.ping === "function") { pings++; backend.ping(); }
    }
    function unmap() {
        interactive = false;
        if (!mapped) return;
        mapped = false;
        focusCheck.restart();
        if (exitWhenClosed) { console.log("overview: socket2 lost; exiting 75 so the service restarts connected"); Qt.exit(75); }
    }

    // ---- focus hand-back (SPEC 3.5, 8): addresses only, never titles -----------
    property string focusAtOpen: ""
    property string focusAfterClose: ""
    property string closeKind: ""        // back | leave | cancel (a stroke that went back)
    property var focusReturnedLast: null // true/false after a close back, null after leaving for another window
    function focusedAddress() {
        if (backend && backend.focusedId !== undefined) return String(backend.focusedId || "");
        var t = Hyprland.activeToplevel;
        // activeToplevel stays empty until the first focus event after the shell starts; the toplevel
        // list knows which window is activated from the start.
        if (!t || !t.address) {
            var all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
            t = null;
            for (var i = 0; i < all.length; i++) {
                var o = all[i].lastIpcObject;
                if (all[i].activated || (o && o.focusHistoryID === 0)) { t = all[i]; break; }
            }
        }
        return t && t.address ? "0x" + String(t.address).replace(/^0x/, "") : "";
    }
    Timer {
        id: focusCheck
        interval: 300
        onTriggered: {
            root.focusAfterClose = root.focusedAddress();
            root.focusReturnedLast = root.closeKind === "leave" ? null
                                   : root.focusAtOpen !== "" && root.focusAfterClose === root.focusAtOpen;
            console.log("overview: closed (" + (root.closeKind || "back") + "); focus " + (root.focusReturnedLast === null ? "moved on purpose"
                        : root.focusReturnedLast ? "returned to " + root.focusAtOpen : "is on " + (root.focusAfterClose || "nothing") + ", was " + (root.focusAtOpen || "nothing")));
        }
    }

    // Left open and forgotten: it goes away by itself after ten minutes.
    // (OVERVIEW_MAX_OPEN_SECONDS shortens it, for tests only.)
    readonly property int maxOpenSeconds: parseInt(Quickshell.env("OVERVIEW_MAX_OPEN_SECONDS") || "600") || 600
    Timer {
        interval: root.maxOpenSeconds * 1000
        running: root.mapped
        onTriggered: { console.log("overview: open for " + root.maxOpenSeconds + " s; closing"); root.close(); }
    }
    // A closing motion that never reports back (it always should) still
    // cannot leave a full-screen surface up.
    // (A stroke held still with the fingers down is not a stuck close: silence never ends a stroke.)
    property bool closingNow: false
    Timer {
        interval: 1500
        running: root.mapped && root.closingNow
        onTriggered: { console.log("overview: close did not finish; unmapping"); root.hardClose(); }
    }

    // ---- theme: the live Omarchy colours, re-read when the theme changes ----
    property color bg: "#101014"
    property color fg: "#eeeeee"
    property color accent: "#4f6ceb"
    property bool light: false
    FileView {
        path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
        watchChanges: true
        printErrors: false
        onFileChanged: { reload(); root.refreshWallpaper(); }
        onLoaded: root.applyColors(text())
    }
    function applyColors(raw) {
        var kv = {}, lines = raw.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var m = /^\s*([a-z_]+)\s*=\s*"([^"]*)"/.exec(lines[i]);
            if (m) kv[m[1]] = m[2];
        }
        if (kv.background) bg = kv.background;
        if (kv.foreground) fg = kv.foreground;
        if (kv.accent) accent = kv.accent;
        light = kv.mode ? kv.mode === "light" : (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) > 0.5;
        refreshWallpaper();
    }

    // The wallpaper is a symlink Omarchy repoints; resolve it so a new one shows.
    property string wallpaper: ""
    function refreshWallpaper() { forks++; wallProc.running = true; }
    Process {
        id: wallProc
        command: ["readlink", "-f", root.home + "/.local/state/omarchy/current/background"]
        stdout: StdioCollector { onStreamFinished: { var p = text.trim(); if (p) root.wallpaper = "file://" + p; } }
    }

    // ---- model: the back end's facts, made ready to draw ---------------------
    // Icons come from the app's desktop entry; agent state from the title glyph
    // Claude Code sets ("✳ " waiting, ◐◓◑◒ or a braille spinner working).
    property var iconCache: ({})
    function appFor(cls) {
        var key = String(cls || "");
        if (iconCache[key]) return iconCache[key];
        var e = DesktopEntries.heuristicLookup(key);
        var name = e && e.name ? e.name : (key.split(".").pop() || "App");
        var raw = e && e.icon ? String(e.icon) : key.toLowerCase();
        var icon = raw.indexOf("/") === 0 ? "file://" + raw : Quickshell.iconPath(raw, true);
        if (!icon) icon = Quickshell.iconPath(key.toLowerCase(), true) || Quickshell.iconPath("application-x-executable", true);
        var v = { name: name.charAt(0).toUpperCase() + name.slice(1), icon: icon || "" };
        if (e) iconCache[key] = v;
        return v;
    }
    function agentOf(title) {
        if (title.length < 3 || title.charAt(1) !== " ") return "";
        var c = title.charCodeAt(0);
        if (c === 0x2733) return "waiting";
        if ((c >= 0x25D0 && c <= 0x25D3) || (c >= 0x2800 && c <= 0x28FF)) return "working";
        return "";
    }
    readonly property var model: {
        DesktopEntries.applications.values;      // re-run once the entries are indexed
        var be = backend, out = { windows: [], info: {}, fleet: -1 };
        if (!be) return out;
        var raw = be.windows || [], perDesk = {};
        for (var i = 0; i < raw.length; i++) {
            var w = raw[i], title = String(w.title || "");
            var fleet = /^(\d+) awaiting input/.exec(title);
            if (fleet && title.indexOf("claude agents") >= 0) out.fleet = Math.max(out.fleet, parseInt(fleet[1]));
            var app = appFor(w.appClass), agent = agentOf(title);
            var label = agent ? title.slice(2) : title.replace(/\s+[–—-]\s+(Chromium|Google Chrome|Brave|Firefox|Mozilla Firefox)$/, "");
            var item = { id: w.id, desk: w.desk, x: w.x, y: w.y, w: w.w, h: w.h, title: title, label: label.length < 3 ? app.name + (label ? " · " + label : "") : label,
                         app: app.name, icon: app.icon, agent: agent, focusRank: w.focusRank, floating: !!w.floating };
            out.windows.push(item);
            (perDesk[w.desk] = perDesk[w.desk] || []).push(item);
        }
        for (var d in perDesk) {
            var list = perDesk[d], main = null, waiting = 0;
            for (var j = 0; j < list.length; j++) {
                if (!main || list[j].w * list[j].h > main.w * main.h) main = list[j];
                if (list[j].agent === "waiting") waiting++;
            }
            // A desk is named after its biggest window: an agent by its task, anything else by its app.
            out.info[d] = { name: main.agent ? main.label : main.app, waiting: waiting, count: list.length };
        }
        return out;
    }
    // The strip of one screen: exactly the desks Omarchy's bar shows on it, in its order, empty ones included,
    // then "New desk" (Desks.strip; nothing else decides which desks are shown).
    function desksFor(screen) {
        var be = backend;
        if (!be) return [];
        var facts = be.deskFacts || { slots: 10, blocks: {}, screens: [{ name: screen, shown: be.activeDesk }],
                                      desks: (be.desks || []).map(function (id) { return { id: id, screen: screen }; }) };
        return Desks.strip(facts, screen, model.info);
    }

    // ---- the surface ---------------------------------------------------------
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property bool mine: !root.backend || !root.backend.screenName || root.backend.screenName === modelData.name
                                         || Quickshell.screens.length === 1
            // The surface is never unmapped. Closed, it is one transparent pixel in
            // the corner that takes no input; open, it covers the screen. An opening
            // then costs a resize instead of a new surface: the shaders, the glyphs
            // and the textures are already there, and the windows' pictures can be
            // asked for at once. Measured on this laptop: the windows start to move
            // 65 ms after the swipe instead of 110.
            readonly property bool up: root.mapped && mine
            visible: true
            anchors { top: true; left: true; bottom: win.up; right: win.up }
            implicitWidth: 1
            implicitHeight: 1
            exclusionMode: ExclusionMode.Ignore
            aboveWindows: true
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "omarchy-overview"
            // The keyboard is taken just after the windows lift off, not before:
            // taking it makes the window underneath draw itself unfocused (its glow
            // goes out), and that must happen behind the ground, not in view.
            // While fingers are on the pad (SPEC 2.1 Focus) and while closing, keys and clicks belong to the desktop.
            readonly property bool takesInput: root.interactive && mine && !scene.tracking
            WlrLayershell.keyboardFocus: takesInput && scene.t > 0.1 ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            mask: takesInput ? null : passThrough
            Region { id: passThrough }

            readonly property real sx: width / Math.max(1, root.backend ? root.backend.monitorWidth : width)
            readonly property real sy: height / Math.max(1, root.backend ? root.backend.monitorHeight : height)

            Scene {
                id: scene
                anchors.fill: parent
                readonly property bool mine: win.mine
                windows: {
                    var src = root.model.windows, out = [];
                    for (var i = 0; i < src.length; i++) {
                        var w = src[i], c = Object.assign({}, w);
                        c.x = w.x * win.sx; c.y = w.y * win.sy; c.w = w.w * win.sx; c.h = w.h * win.sy;
                        out.push(c);
                    }
                    return out;
                }
                desks: root.desksFor(win.modelData.name)
                fleetWaiting: root.model.fleet
                activeDesk: root.backend ? root.backend.activeDesk : 1
                hostBusy: root.backend ? !!root.backend.busy : false
                wallpaper: root.wallpaper
                surfaceReady: win.up && win.width > 1 && win.height > 1
                homeRadius: (root.backend ? root.backend.rounding : 12) * win.sx
                pictureSource: root.backend ? root.backend.thumbnail : null
                background: root.bg
                foreground: root.fg
                accentColor: root.accent
                lightMode: root.light
                onActivateWindow: function (id) { root.closeKind = "leave"; root.backend.focusWindow(id); root.interactive = false; }
                onActivateDesk: function (id) { root.closeKind = "leave"; root.backend.goToDesk(id); root.interactive = false; }
                onCloseWindow: function (id) { root.backend.closeWindow(id); }
                onOperate: function (op) { scene.opSent(op.tag, root.runOp(op)); }
                onRereadRequested: if (root.backend) root.backend.prepare()
                onShown: function (byStroke) { root.show(byStroke); }
                onFinished: { if (!root.closeKind) root.closeKind = "cancel"; if (!root.anyOpen()) root.unmap(); }
                onClosingChanged: { if (closing) root.interactive = false; root.closingNow = closing; }
                onCommittedOpenChanged: root.interactive = committedOpen
                Component.onCompleted: { var s = root.scenes.slice(); s.push(scene); root.scenes = s; }
                Component.onDestruction: root.scenes = root.scenes.filter(function (x) { return x !== scene; })
            }
        }
    }

    // ---- operations: the scene asks, the back end answers through opResult -------
    // Returns the back end's seq, -2 for an older back end that answers nothing, -1 when not sent.
    function runOp(op) {
        var be = backend, r;
        if (!be) return -1;
        if (op.op === "move") r = be.moveToDesk(op.win, op.desk);
        else if (op.op === "newdesk") r = typeof be.newDesk === "function" ? be.newDesk(op.win, op.desk) : -1;
        else if (op.op === "reorder") r = typeof be.reorder === "function" ? be.reorder(op.order, op.positions) : -1;
        else if (op.op === "insert") r = typeof be.insertDesk === "function" ? be.insertDesk(op.left, op.right, op.win, op.last) : -1;
        else return -1;
        return typeof r === "number" ? r : -2;
    }

    // ---- remote control: the same target and functions as before, plus test hooks ----
    IpcHandler {
        target: "overview"
        function toggle(): void { root.toggle(); }
        function open(): void { root.open(); }
        function close(): void { root.close(); }
        function status(): string {
            var s = root.mainScene(), st = s ? s.stats : {};
            var forks = root.forks + (root.backend && typeof root.backend.forks === "number" ? root.backend.forks : 0);
            return JSON.stringify({ mapped: root.mapped, interactive: root.interactive, backend: root.mock ? "mock" : "hyprland",
                                    windows: root.model.windows.length, desks: s ? s.desks.length : 0,
                                    strip: s ? s.desks.map(function (d) { return d.isNew ? "+" + d.id : d.id; }) : [],
                                    activeDesk: root.backend ? root.backend.activeDesk : -1,
                                    viewedDesk: s ? s.viewedDesk : -1, queryLength: s ? s.query.length : 0, selected: s ? s.selectedId : "",
                                    shown: s ? s.gridOrder.length : 0, waiting: s ? s.waitingCount : 0,
                                    t: s ? Math.round(s.t * 10000) / 10000 : 0, mode: s ? s.mode : "closed",
                                    strokes: st.strokes || 0, eventsLastStroke: st.eventsLastStroke || 0,
                                    maxGapMsLastStroke: st.maxGapMsLastStroke || 0, decisionLast: st.decisionLast || "",
                                    framesLastStroke: st.framesLastStroke || 0, longFramesLastStroke: st.longFramesLastStroke || 0,
                                    mmLastStroke: st.mmLastStroke || 0, gateWaitedMs: st.gateWaitedMs || 0,
                                    hello: root.hellos, pings: root.pings, pingOk: root.pingOk,
                                    captures: s ? s.captureCount : 0, refreshes: s ? s.refreshCount : 0, forks: forks,
                                    lastOp: s ? s.lastOp : null, undo: s ? s.undoStack.length : 0, pendingOps: s ? s.pendingCount : 0,
                                    paging: s ? s.paging : false, dragging: s ? s.dragActive() : false,
                                    tiles: s ? s.tileRects() : [], cards: s ? s.cardRects() : [], stripCaptures: s ? s.dragController.bar.captureCount : 0,
                                    pill: s ? s.pillState() : null,
                                    keyboard: root.interactive && s !== null && !s.tracking && s.t > 0.1, exitWhenClosed: root.exitWhenClosed,
                                    focusAtOpen: root.focusAtOpen, focusAfterClose: root.focusAfterClose,
                                    focusReturnedLast: root.focusReturnedLast });
        }
        // The last stroke, one entry per drawn frame: [ms since the stroke began, t, phase T|S|A|P].
        function trace(): string { var s = root.mainScene(); return JSON.stringify(s ? s.trace : []); }
        // One ovg line straight into the back end's parser (as if it came over socket2).
        function feed(line: string): string {
            var be = root.backend;
            if (be && typeof be.feed === "function") return be.feed(line) === false ? "bad" : "ok";
            var ev = G.parseLine(line);
            if (!ev) return "bad";
            if (ev.kind === "b") root.eachMine(function (s) { s.strokeBegin(ev.fingers, ev.dir, ev.acc, ev.tMs); });
            else if (ev.kind === "u") root.eachMine(function (s) { s.strokeUpdate(ev.acc, ev.tMs); });
            else if (ev.kind === "e") root.strokeEnded(ev.acc, ev.tMs, ev.cancelled);
            else if (ev.kind === "hello") root.hellos++;
            return "ok";
        }
        // Drive the drag machine without a pointer (SPEC E5): phase begin | move | drop | cancel; x, y in surface pixels.
        function drag(kind: string, id: string, x: string, y: string, phase: string): string {
            var s = root.mainScene();
            if (!s) return "no scene";
            return s.dragHook(kind, id, Number(x), Number(y), phase);
        }
    }

    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup(); }
    }
    Component.onCompleted: {
        refreshWallpaper();     // decoded before the first swipe, not during it
        if (!root.mock) Hyprland.refreshToplevels();   // which window has focus, before any focus event arrives
        console.log("overview ready (" + (root.mock ? "mock" : "hyprland") + " back end)");
    }
}
