import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "Layout.js" as L
import "Gesture.js" as G

// The overview: one full-screen picture of everything that is open.
//
// Desks along the top as live miniatures; the windows of the desk he is
// viewing fill the rest as large thumbnails, laid out in justified rows;
// typing searches every desk. Pure QML: it reads only the properties below
// and says what it wants through the signals, so it draws the same whether
// it is fed by Hyprland or by the mock back end.
//
// Motion (SPEC 2.1, addendum §0): one number t (0 = the desktop, 1 = the
// overview). While fingers are on the pad, t is a pure function of how far
// they have travelled (Gesture.progress + rubber), sampled once per drawn
// frame; nothing eases it. At lift-off the finger's own speed is handed to
// one analytic critically damped spring (Gesture.spring), so the motion
// carries on without a seam. A new stroke may grab that spring anywhere.
// Desk paging uses the same spring (omega 18) on a second number, pagePos.
Item {
    id: ov

    // ---- what the host hands in -------------------------------------------
    property var windows: []        // [{ id, desk, x, y, w, h, title, label, app, icon, agent: ""|"waiting"|"working", focusRank }] in this surface's coordinates
    property var desks: []          // [{ id, name, isNew, waiting, count }]
    property int activeDesk: 1
    property int fleetWaiting: -1   // the "claude agents" window's own count, -1 when it is not open
    property url wallpaper: ""
    property Component pictureSource: null  // the back end's picture: root has winId, capturing; exposes ready, pending, refresh()
    property real homeRadius: 12            // the corner radius windows have on the desktop
    property bool surfaceReady: true        // the surface has its full size (the host keeps it at one pixel while closed)
    onSurfaceReadyChanged: pictureArrived()
    property color background: "#101014"
    property color foreground: "#eeeeee"
    property color accentColor: "#4f6ceb"
    property bool lightMode: false

    signal activateWindow(string id)
    signal activateDesk(int id)
    signal closeWindow(string id)
    signal operate(var op)          // the host runs op on the back end and answers at once with opSent(op.tag, seq) (SPEC 3.4)
    signal finished()               // the closing motion is over; the host may unmap
    signal shown(bool byStroke)     // something is about to be drawn: the host maps the surface (byStroke: a stroke's event opened it)

    // ---- palette: derived from the theme, never hard-coded per theme -------
    readonly property string uiFont: "Inter Display"
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property color ink: lightMode ? Qt.darker(foreground, 1.15) : Qt.lighter(foreground, 1.02)
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, lightMode ? 0.88 : 0.74)
    readonly property color accent: accentColor
    readonly property color accentSoft: Qt.rgba(accent.r, accent.g, accent.b, 0.22)
    readonly property color accentGlow: Qt.rgba(accent.r, accent.g, accent.b, 0.35)
    // Ink that reads on a filled accent pill, whatever the theme's accent is.
    readonly property color accentInk: (0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b) > 0.6 ? "#14151c" : "#ffffff"
    readonly property color dimColor: lightMode ? Qt.rgba(background.r, background.g, background.b, 0.55)
                                                : Qt.rgba(background.r * 0.35, background.g * 0.35, background.b * 0.35, 0.50)
    readonly property color surfaceColor: lightMode ? Qt.darker(background, 1.04) : Qt.lighter(Qt.rgba(background.r, background.g, background.b, 1), 1.6)
    readonly property color glass: lightMode ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(1, 1, 1, 0.06)
    readonly property color hairline: lightMode ? Qt.rgba(0, 0, 0, 0.10) : Qt.rgba(1, 1, 1, 0.12)
    readonly property color shadowColor: lightMode ? Qt.rgba(0.05, 0.07, 0.15, 0.22) : Qt.rgba(0, 0, 0, 0.62)
    readonly property color contactColor: lightMode ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(0, 0, 0, 0.45)
    readonly property color chipColor: lightMode ? Qt.rgba(1, 1, 1, 0.92) : Qt.rgba(0.09, 0.09, 0.11, 0.86)
    readonly property color chipInk: lightMode ? "#2b2d3a" : "#f2f2f2"
    readonly property color closeHot: "#e5484d"
    readonly property color amber: lightMode ? "#e8930c" : "#ffb224"
    readonly property color amberInk: "#2a1800"

    // ---- geometry: designed at 1500 logical pixels high --------------------
    readonly property real u: height / 1500
    readonly property real margin: 104 * u
    // The strip stays centred; when the agents line is up, both sides keep its width free.
    readonly property real stripMargin: waitingCount > 0 ? Math.max(150 * u, summary.width + 76 * u) : 150 * u
    readonly property var strip: L.deskStrip(desks.length, width, stripMargin, 30 * u, 272 * u, width / Math.max(1, height))
    readonly property real stripTop: 44 * u
    readonly property real tileH: strip.length ? strip[0].h : 150 * u
    readonly property real stripBottom: stripTop + tileH + 46 * u
    readonly property var gridBox: ({ x: margin, y: stripBottom + 70 * u, w: width - 2 * margin, h: height - stripBottom - 70 * u - 84 * u })

    // ---- state ---------------------------------------------------------------
    property real t: 0                  // 0 = windows where they are, 1 = overview laid out (what is drawn this frame)
    property bool isOpen: false         // anything of the overview is up (a stroke, a spring, or open)
    property bool closing: false        // heading to the desktop after a decision to close
    property bool committedOpen: false  // decided open: the host may take the keyboard (SPEC 2.1 Focus)
    property bool tracking: false       // fingers on the pad: t follows them
    property bool springing: false
    property real target: 0             // where the spring is taking t
    property bool arming: false         // keyboard/IPC open waiting (<= 150 ms) for the pictures
    readonly property bool paging: pageDesks.length > 0
    readonly property bool settled: isOpen && !closing && !tracking && !springing && !arming && !paging && t > 0.999
    readonly property bool capturing: isOpen
    readonly property string mode: !isOpen ? "closed" : tracking ? "tracking" : closing ? "closing"
                                   : arming || (springing && target === 1) ? "opening" : paging ? "paging" : "open"
    property bool flip: true            // closing by going back (windows fly home) or by leaving (they fade)
    property int viewedDesk: 1
    property string query: ""
    property string selectedId: ""
    property bool showSelection: false
    property alias dragId: dragCtl.dragId
    property alias dragPos: dragCtl.dragPos
    property alias dropDesk: dragCtl.dropDesk

    // ---- the model ----------------------------------------------------------
    // Delegates must survive every refresh (a title change must not restart a
    // live capture), so the views use a keyed ListModel synced by id.
    property var byId: ({})
    ListModel { id: winList }
    property alias winModel: winList
    onWindowsChanged: {
        var map = {}, seen = {};
        for (var i = 0; i < windows.length; i++) map[windows[i].id] = windows[i];
        byId = map;
        for (i = winList.count - 1; i >= 0; i--) {
            var id = winList.get(i).wid;
            if (!map[id]) winList.remove(i); else seen[id] = true;
        }
        for (i = 0; i < windows.length; i++) if (!seen[windows[i].id]) winList.append({ wid: windows[i].id });
        // A window that appears while the overview is open may capture too (still inside the 24 budget).
        if (isOpen) planCaptures();
        if (awaitSnap && modelMoved(awaitSnap)) awaitSnap = null;
        // gridOrder re-evaluates after this handler, so pick the new selection once it has.
        if (selectedId && (!map[selectedId] || map[selectedId].desk !== viewedDesk) && !query) Qt.callLater(function () {
            if (selectedId && (!byId[selectedId] || !gridLayout[selectedId])) { selectedId = gridOrder.length ? gridOrder[0].id : ""; showSelection = showSelection && selectedId !== ""; }
        });
    }

    // Search: every word must appear in the title, the app or "desk N".
    function matches(w, words) {
        var hay = (w.title + " " + w.app + " desk " + w.desk).toLowerCase();
        for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) < 0) return 0;
        var q = words.join(" "), title = w.title.toLowerCase(), app = w.app.toLowerCase();
        if (app.indexOf(q) === 0) return 4;
        if (title.indexOf(q) === 0) return 3;
        if (new RegExp("(^|[^a-z0-9])" + q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(title)) return 2;
        return 1;
    }
    function windowsOn(desk) {
        var here = [];
        for (var i = 0; i < windows.length; i++) if (windows[i].desk === desk) here.push(windows[i]);
        return L.order(here, height);
    }
    readonly property var gridOrder: {
        if (query.length > 0) {
            var words = query.toLowerCase().split(/\s+/).filter(function (s) { return s.length > 0; }), hits = [];
            for (var i = 0; i < windows.length; i++) {
                var s = matches(windows[i], words);
                if (s > 0) hits.push({ w: windows[i], s: s });
            }
            hits.sort(function (a, b) {
                if (a.s !== b.s) return b.s - a.s;
                var wa = a.w.agent === "waiting" ? 0 : 1, wb = b.w.agent === "waiting" ? 0 : 1;
                if (wa !== wb) return wa - wb;
                return a.w.focusRank - b.w.focusRank;
            });
            return hits.map(function (h) { return h.w; });
        }
        return windowsOn(viewedDesk);
    }
    function justifyIn(list, dx) {
        var box = { x: gridBox.x + dx, y: gridBox.y, w: gridBox.w, h: gridBox.h };
        return L.justify(list.map(function (w) { return { id: w.id, w: w.w, h: w.h }; }), box, 46 * u, 58 * u, 1.5);
    }
    // While paging, the desks passed on the way sit side by side, one screen
    // width apart; the cards layer slides by pagePos screen widths. The rects
    // change only when that set changes, never per frame.
    readonly property var gridLayout: justifyIn(gridOrder, 0)
    readonly property var layout: {
        if (!paging) return gridLayout;
        var out = {};
        for (var i = 0; i < pageDesks.length; i++) {
            var r = justifyIn(windowsOn(pageDesks[i].id), pageDesks[i].at * width);
            for (var k in r) out[k] = r[k];
        }
        return out;
    }
    readonly property int waitingCount: {
        var n = 0;
        for (var i = 0; i < windows.length; i++) if (windows[i].agent === "waiting") n++;
        return Math.max(n, fleetWaiting);
    }
    // Desks in strip order: the real ones, then the "New desk" (virtual until a window lands on it).
    readonly property var deskOrder: desks.map(function (d) { return d.id; })
    readonly property var realDesks: desks.filter(function (d) { return !d.isNew; }).map(function (d) { return d.id; })
    readonly property int newDeskId: { for (var i = 0; i < desks.length; i++) if (desks[i].isNew) return desks[i].id; return -1; }
    // The screen's own desks (the bar's run, empty ones included): positions for a reorder. Guests come after.
    readonly property var ownDesks: desks.filter(function (d) { return !d.isNew && !d.guest; }).map(function (d) { return d.id; })
    function deskExists(id) { for (var i = 0; i < desks.length; i++) if (desks[i].id === id) return !desks[i].isNew && desks[i].exists !== false; return false; }

    // ---- the clock: one FrameAnimation, running only while something moves ----
    // It samples the finger (or the spring) once per drawn frame, so t changes
    // exactly once per frame and never fights an animation. Closed: stopped.
    property real clockMs: 0
    FrameAnimation {
        id: clock
        running: ov.tracking || ov.springing || ov.arming || ov.pageSpringing || ov.gateBlending
        onTriggered: ov.tick(Math.min(0.05, Math.max(0, frameTime)))
    }
    function tick(dt) {
        clockMs += dt * 1000;
        var x = t, ph = "";
        if (arming) {
            if (pictureGateOpen()) { arming = false; gateHeld = false; gateOpenedAt = -1; gateWaitedMs = Date.now() - gateSince; startSpring(1, 0, G.OMEGA); }
            else { recordFrame(dt, "A"); return; }
        }
        if (tracking) {
            // t follows the finger; a frame that comes late catches up over a few frames instead of in one jump
            // (at most maxStep of travel per frame on screen; the release then starts from what is drawn).
            x = Math.max(0, G.rubber(liveP)); ph = "T";
            var lag = x - t;
            if (Math.abs(lag) > maxStep) { x = t + (lag > 0 ? maxStep : -maxStep); ph = "L"; }
            lagging = ph === "L";
        }
        else if (springing) {
            sTau += dt;
            var r = G.spring(sX0, sV0, target, sTau, sOmega);
            x = r.x; sVel = r.v; ph = "S";
            // Never past the target: an overshoot would grow the windows past their real size.
            if ((sX0 - target) * (x - target) < 0 || G.springSettled(x, r.v, target)) { x = target; sVel = 0; springing = false; }
        }
        var gx = applyGate(x);
        if (gx !== x && ph) ph = ph === "T" ? "G" : "g";        // the picture gate held this frame back
        x = gx;
        if (pageSpringing) tickPage(dt);
        t = Math.max(0, x);
        recordFrame(dt, ph || (pageSpringing ? "P" : ""));
        if (!tracking && !springing && !arming && t === 0 && isOpen && target === 0) finishClose();
    }

    // ---- the picture gate (SPEC 2.1): pictures are asked for on the first event ----
    // Until every card of this desk has its picture, or 150 ms pass, t stays
    // at or under 0.20; then it catches up with the finger over 80 ms.
    property bool gateHeld: false
    property double gateSince: 0
    property double gateOpenedAt: -1
    readonly property bool gateBlending: gateOpenedAt >= 0
    function picturesReady() {
        for (var i = 0; i < cardRep.count; i++) { var c = cardRep.itemAt(i); if (c && c.awaited && c.picturePending) return false; }
        return true;
    }
    function pictureGateOpen() { return surfaceReady && (picturesReady() || Date.now() - gateSince >= 150); }
    property bool gateClamped: false
    function applyGate(x) {
        if (gateHeld) {
            if (!pictureGateOpen()) { if (x > 0.2) gateClamped = true; return Math.min(x, 0.2); }
            gateHeld = false; gateWaitedMs = Date.now() - gateSince;
            // Only a gate that actually held t back needs the catch-up; otherwise t is simply the finger's.
            gateOpenedAt = gateClamped ? Date.now() : -1;
        }
        if (gateOpenedAt >= 0) {
            var k = (Date.now() - gateOpenedAt) / 80;
            if (k >= 1) { gateOpenedAt = -1; return x; }
            var c = Math.min(x, 0.2);
            return c + (x - c) * k;
        }
        return x;
    }
    property double gateWaitedMs: 0
    function pictureArrived() { /* the gate is checked every frame; kept for the cards and tiles */ }

    // ---- the spring ------------------------------------------------------------
    property real sX0: 0
    property real sV0: 0
    property real sTau: 0
    property real sOmega: G.OMEGA
    property real sVel: 0                // the spring's speed now (progress/s), handed on if it is reversed
    // x0: where the motion is now (default t; at a release, the finger's own last position, which may be
    // one event ahead of the last drawn frame).
    function startSpring(to, v0, omega, x0) {
        sX0 = x0 === undefined ? t : x0; sV0 = v0; sTau = 0; sOmega = omega; sVel = v0;
        target = to;
        springing = Math.abs(sX0 - to) >= G.EPS_X || Math.abs(v0) >= G.EPS_V;
        if (!springing) { t = to; if (to === 0 && !tracking && isOpen) finishClose(); }
    }

    // ---- strokes (called by the host for every ovg line) -------------------------
    property bool strokeIgnored: false   // a down stroke on a closed overview does nothing at all
    property bool strokeClosing: false   // the stroke began on an overview that was open (or opening)
    property real strokeP0: 0
    readonly property int strokeSign: 1  // the stream's millimetres are positive for fingers up (overview.lua, addendum L6)
    property string strokeDir: "UP"
    property real strokeOrigin: 0
    property real liveP: 0               // progress before the rubber band
    readonly property real maxStep: 0.34 // most t may move in one drawn frame (≈ 570 mm/s at 60 Hz) while the finger leads
    property bool lagging: false         // the last tracking frame was held to maxStep behind the finger
    property var samples: []             // [{ t: ms, acc: mm }] of the live stroke (velocity fit)
    // per-stroke numbers for status() and the journal (SPEC 4.1, §8): no titles, numbers only
    property var stats: ({ strokes: 0, eventsLastStroke: 0, maxGapMsLastStroke: 0, decisionLast: "", framesLastStroke: 0,
                            longFramesLastStroke: 0, mmLastStroke: 0, gateWaitedMs: 0 })
    property double lastEventAt: 0
    property var trace: []               // the last stroke: [ms since it began, t, phase] per frame (T tracking, S spring,
                                         // A waiting for pictures, P paging) and [ms, finger t, "E"] per event received
    property bool tracingFrames: false
    property double traceStart: 0

    function strokeBegin(fingers, dir, acc, tMs) {
        if (tracking) settleStroke("new stroke");
        var down = String(dir).toUpperCase() === "DOWN";
        if (!isOpen && down) { strokeIgnored = true; return false; }
        strokeIgnored = false;
        var wasOpen = isOpen && !closing && (committedOpen || target === 1);
        if (!isOpen) beginShow(true);
        else if (closing) { closing = false; flip = true; }
        arming = false;
        springing = false;
        strokeClosing = wasOpen;
        strokeP0 = t;
        strokeDir = down ? "DOWN" : "UP";
        strokeOrigin = acc || 0;
        liveP = t;
        samples = [{ t: tMs, acc: 0 }];
        tracking = true;
        lagging = false;
        var s = stats;
        s.strokes++; s.eventsLastStroke = 1; s.maxGapMsLastStroke = 0; s.decisionLast = ""; s.framesLastStroke = 0;
        s.longFramesLastStroke = 0; s.mmLastStroke = 0; s.gateWaitedMs = 0;
        lastEventAt = Date.now();
        trace = []; traceStart = Date.now(); tracingFrames = true;
        return true;
    }
    function strokeUpdate(acc, tMs) {
        if (strokeIgnored) return;
        if (!tracking) {
            // An update with no live stroke starts one from where t is, its value the origin (SPEC §0 L4).
            if (!strokeBegin(0, strokeDir, acc, tMs)) return;
            return;
        }
        noteEvent();
        var rel = acc - strokeOrigin;
        var last = samples[samples.length - 1];
        if (tMs >= last.t) {
            samples.push({ t: tMs, acc: rel });
            if (samples.length > 64) samples.splice(0, samples.length - 64);
        }
        liveP = G.progress(rel, strokeSign, strokeP0, strokeClosing);
        stats.mmLastStroke = rel;
        if (trace.length < 1500) trace.push([Date.now() - traceStart, Math.round(Math.max(0, G.rubber(liveP)) * 10000) / 10000, "E"]);
    }
    function strokeEnd(acc, tMs, cancelled) {
        if (strokeIgnored) { strokeIgnored = false; return; }
        if (!tracking) return;
        noteEvent();
        var rel = acc - strokeOrigin;
        var last = samples[samples.length - 1];
        if (tMs > last.t) samples.push({ t: tMs, acc: rel });
        liveP = G.progress(rel, strokeSign || 1, strokeP0, strokeClosing);
        if (trace.length < 1500) trace.push([Date.now() - traceStart, Math.round(Math.max(0, G.rubber(liveP)) * 10000) / 10000, "E"]);
        var v = G.velocity(samples) * strokeSign;                  // mm/ms toward "open"
        var d = G.decide(liveP, v, cancelled, strokeClosing);
        var reason = cancelled ? "cancelled" : Math.abs(v) >= G.V_COMMIT ? "speed" : "position";
        release(d, liveP <= 0 && d === 0 ? 0 : G.releaseVelocity(v, 1, liveP), reason);
    }
    // A stroke that ends without its own "e" (a reload, a new stroke, the socket gone): by position, v = 0.
    function settleStroke(why) {
        if (!tracking) return;
        release(G.decide(liveP, 0, false, strokeClosing), 0, why);
    }
    function release(d, v0, reason) {
        tracking = false;
        // The spring takes over from the finger's last position (not the last drawn frame) with its speed.
        var gated = gateHeld || gateOpenedAt >= 0 || lagging;
        var x0 = gated ? t : Math.max(0, G.rubber(liveP));
        if (trace.length < 1500) trace.push([Date.now() - traceStart, Math.round(x0 * 10000) / 10000, "R", Math.round(v0 * 1000) / 1000]);
        stats.decisionLast = (d === 1 ? "open" : "close") + ":" + reason;
        stats.gateWaitedMs = Math.round(gateWaitedMs);
        if (d === 1) { committedOpen = true; closing = false; startSpring(1, v0, G.OMEGA, x0); }
        else {
            var switchToViewed = strokeClosing && reason !== "cancelled" && viewedDesk !== activeDesk;
            if (switchToViewed) activateDesk(viewedDesk);
            committedOpen = false;
            closing = true; flip = !switchToViewed;
            cancelDrag();
            startSpring(0, v0, switchToViewed ? G.OMEGA_LEAVE : G.OMEGA, x0);
        }
    }
    function noteEvent() {
        var now = Date.now();
        stats.eventsLastStroke++;
        stats.maxGapMsLastStroke = Math.max(stats.maxGapMsLastStroke, now - lastEventAt);
        lastEventAt = now;
    }
    function recordFrame(dt, ph) {
        if (!tracingFrames) return;
        stats.framesLastStroke++;
        if (dt > 0.020) stats.longFramesLastStroke++;
        if (trace.length < 1500) trace.push([Date.now() - traceStart, Math.round(t * 10000) / 10000, ph]);
        if (!tracking && !springing && !arming) tracingFrames = false;
    }

    // ---- open and close (keyboard, IPC, clicks) ----------------------------------
    function beginShow(byStroke) {
        query = "";
        viewedDesk = activeDesk;
        pageDesks = []; pagePos = 0; pageSpringing = false;
        cancelDrag();
        flip = true;
        showSelection = false;
        // Select the window he was last in, so Enter simply goes back.
        var best = "", rank = 1e9;
        for (var i = 0; i < windows.length; i++)
            if (windows[i].desk === activeDesk && windows[i].focusRank < rank) { rank = windows[i].focusRank; best = windows[i].id; }
        selectedId = best;
        closing = false;
        isOpen = true;
        undoStack = [];
        pill.hide();
        capturedIds = ({}); captureCount = 0; refreshCount = 0;
        planCaptures();
        gateHeld = true; gateSince = Date.now(); gateOpenedAt = -1; gateWaitedMs = 0; gateClamped = false;
        forceActiveFocus();
        shown(!!byStroke);
    }
    function open() {
        // The open key (or IPC) during a stroke settles that stroke as open: a stroke whose end was lost can
        // never leave a half-open overview that ignores the key (review, interaction).
        if (tracking) { release(1, 0, "open request"); return; }
        if (isOpen && !closing && target === 1) return;
        committedOpen = true;
        if (!isOpen) {
            beginShow();
            // The windows leave the desktop only once their pictures are in hand (or 150 ms pass).
            arming = true;
            trace = []; traceStart = Date.now(); tracingFrames = true; stats.framesLastStroke = 0; stats.longFramesLastStroke = 0;
            return;
        }
        closing = false; flip = true;
        forceActiveFocus();
        startSpring(1, springing ? sVel : 0, G.OMEGA);           // reopened mid-flight: carry on from here
    }
    // mode "back": windows fly home. mode "leave": everything fades in place
    // (used when going to another desk, where home would be the wrong place).
    function close(mode) {
        // Esc, the toggle key, a backdrop click, IPC and the 10-minute auto-close all end a live stroke first:
        // its remaining events are ignored until the next stroke begins.
        if (tracking) { tracking = false; committedOpen = false; strokeIgnored = true; }
        if (!isOpen || closing) return;
        committedOpen = false;
        flip = mode !== "leave";
        closing = true;
        cancelDrag();
        if (arming || t <= 0.001) { arming = false; springing = false; t = 0; finishClose(); return; }   // closed before anything moved
        startSpring(0, springing ? sVel : 0, mode === "leave" ? G.OMEGA_LEAVE : G.OMEGA);
    }
    function finishClose() {
        springing = false; arming = false; tracking = false; gateHeld = false; gateOpenedAt = -1;
        pageDesks = []; pagePos = 0; pageSpringing = false;
        isOpen = false; closing = false; committedOpen = false; target = 0; t = 0;
        cancelDrag();
        finished();
    }
    function snapShut() {
        springing = false; arming = false; tracking = false; strokeIgnored = false; gateHeld = false; gateOpenedAt = -1;
        pageDesks = []; pagePos = 0; pageSpringing = false;
        t = 0; target = 0; isOpen = false; closing = false; committedOpen = false;
        cancelDrag();
    }

    // ---- desk paging (SPEC 2.4, 2.6) ---------------------------------------------
    property var pageDesks: []           // [{ id, at }] laid out side by side while paging (at = screen widths)
    property real pagePos: 0             // the cards layer is at x = -pagePos * width
    property bool pageSpringing: false
    property real pX0: 0
    property real pV0: 0
    property real pTau: 0
    property real pVel: 0
    function pageIndex(id) { return deskOrder.indexOf(id); }
    // Page the grid to desk id; v0 in screen widths per second toward the new desk.
    function pageTo(id, v0) {
        var L2 = deskOrder, ti = L2.indexOf(id);
        if (ti < 0 || id === viewedDesk && !paging) return;
        if (query.length) { viewedDesk = id; return; }
        var from = pageIndex(viewedDesk);
        var P = paging ? anchorIdx + pagePos : (from < 0 ? ti : from);
        var r = Math.round(P), set = [];
        if (Math.abs(ti - r) > 1) {
            // A far desk slides in from one grid width away, not past every desk between.
            var dir = ti > r ? 1 : -1;
            set = [{ id: L2[Math.max(0, Math.min(L2.length - 1, r))], at: -dir }, { id: id, at: 0 }];
            pagePos = -dir + (P - r);
        } else {
            var lo = Math.max(0, Math.min(Math.floor(P), ti)), hi = Math.min(L2.length - 1, Math.max(Math.ceil(P), ti));
            for (var k = lo; k <= hi; k++) set.push({ id: L2[k], at: k - ti });
            pagePos = P - ti;
        }
        anchorIdx = ti;
        pageDesks = set;
        viewedDesk = id;
        if (selectedId && byId[selectedId] && byId[selectedId].desk !== id) {
            var keep = showSelection;
            selectedId = "";
            Qt.callLater(function () { if (!selectedId && gridOrder.length) { selectedId = gridOrder[0].id; showSelection = keep; } });
        }
        pX0 = pagePos; pV0 = v0 === undefined ? (paging && pageSpringing ? pVel : 0) : v0; pTau = 0; pVel = pV0;
        pageSpringing = true;
        planCaptures();
    }
    property int anchorIdx: 0
    function tickPage(dt) {
        pTau += dt;
        var r = G.spring(pX0, pV0, 0, pTau, G.OMEGA_PAGE);
        var x = r.x;
        pVel = r.v;
        if (pX0 * x < 0 || G.springSettled(x, r.v, 0)) { x = 0; endPaging(); return; }
        pagePos = x;
    }
    function endPaging() { pageSpringing = false; pagePos = 0; pageDesks = []; }

    // 2-finger sideways scroll pages desks under the fingers: half a grid width of
    // scroll is one desk (SPEC 2.6). On ScrollEnd (or 90 ms of quiet) it snaps with
    // the paging spring, using the scroll's own speed.
    property bool scrolling: false
    property real scrollStart: 0
    property real scrollPos: 0
    property var scrollSamples: []
    function scrollBy(dx) {
        if (!isOpen || closing || tracking || query.length || dragId !== "" || deskOrder.length < 2) return;
        var L2 = deskOrder, now = Date.now();
        if (!scrolling) {
            var from = pageIndex(viewedDesk);
            scrollStart = paging ? anchorIdx + pagePos : from;
            scrollPos = 0; scrollSamples = [];
            pageSpringing = false;
            scrolling = true;
        }
        scrollPos += -dx / Math.max(1, width / 2);
        var hiIdx = L2.length - 1;
        var raw = scrollStart + scrollPos, P = raw;
        if (raw < 0) P = -0.15 * (1 - Math.exp(raw * 3));
        else if (raw > hiIdx) P = hiIdx + 0.15 * (1 - Math.exp(-(raw - hiIdx) * 3));
        scrollSamples.push({ t: now, acc: P });
        if (scrollSamples.length > 32) scrollSamples.splice(0, scrollSamples.length - 32);
        var lo = Math.max(0, Math.floor(P)), hi = Math.min(L2.length - 1, Math.ceil(P));
        var a = Math.max(0, Math.min(L2.length - 1, Math.round(P)));
        var set = [];
        for (var k = lo; k <= hi; k++) set.push({ id: L2[k], at: k - a });
        if (!paging || anchorIdx !== a || pageDesks.length !== set.length || pageDesks[0].id !== set[0].id) { anchorIdx = a; pageDesks = set; }
        pagePos = P - a;
        if (viewedDesk !== L2[a]) { viewedDesk = L2[a]; planCaptures(); }
        scrollQuiet.restart();
    }
    function scrollRelease() {
        if (!scrolling) return;
        scrolling = false;
        scrollQuiet.stop();
        var L2 = deskOrder, P = anchorIdx + pagePos, v = G.velocity(scrollSamples);     // desks per ms
        var hiIdx = L2.length - 1;
        var ti = Math.round(P + v * G.PROJECT_MS);
        ti = Math.max(0, Math.min(hiIdx, Math.max(Math.floor(P), Math.min(Math.ceil(P), ti))));
        var lo = Math.max(0, Math.min(Math.floor(P), ti)), hi = Math.min(L2.length - 1, Math.max(Math.ceil(P), ti)), set = [];
        for (var k = lo; k <= hi; k++) set.push({ id: L2[k], at: k - ti });
        anchorIdx = ti; pageDesks = set; pagePos = P - ti;
        if (viewedDesk !== L2[ti]) { viewedDesk = L2[ti]; planCaptures(); }
        // pagePos runs toward 0 as P runs toward ti: d(pagePos)/dt = dP/dt, handed on as is.
        pX0 = pagePos; pV0 = Math.max(-8, Math.min(8, v * 1000)); pTau = 0; pVel = pV0;
        pageSpringing = true;
    }
    Timer { id: scrollQuiet; interval: 90; onTriggered: ov.scrollRelease() }

    // The native 3-finger sideways swipe stays his; while the overview is open the
    // grid follows the desk it lands on, starting at one grid width per 250 ms.
    onActiveDeskChanged: {
        // (An op renumbers desks, the active one too: that is not a swipe. The renumbering lands with the model,
        // after the answer, so an op on its way and the half second after one count as "not a swipe".)
        if (!isOpen || closing || tracking || query.length || dragActive() || opBusy || Date.now() - lastOpDoneAt < 500
            || activeDesk === viewedDesk) return;
        var a = pageIndex(activeDesk), b = pageIndex(viewedDesk);
        pageTo(activeDesk, a >= 0 && b >= 0 ? (a > b ? 4 : -4) : 0);
    }

    // ---- pictures: one capture per window, at most 24 per opening (SPEC 2.2) ----------
    // Cards and miniatures get their picture through this wrapper around the back
    // end's: it lets a window be captured only inside the budget (the viewed desk's
    // windows first, then the nearest desks'), counts captures, and allows a
    // settled refresh only when nothing has moved for 300 ms.
    readonly property int captureBudget: 24
    property var captureAllowed: ({})
    property var capturedIds: ({})
    property int captureCount: 0
    property int refreshCount: 0
    function planCaptures() {
        var allowed = {}, n = 0, k;
        for (k in capturedIds) { allowed[k] = true; n++; }
        var vi = pageIndex(viewedDesk), list = windows.slice();
        list.sort(function (a, b) {
            var da = Math.abs(pageIndex(a.desk) - vi), db = Math.abs(pageIndex(b.desk) - vi);
            if (a.desk === viewedDesk) da = -1;
            if (b.desk === viewedDesk) db = -1;
            return da !== db ? da - db : a.focusRank - b.focusRank;
        });
        for (var i = 0; i < list.length && n < captureBudget; i++) if (!allowed[list[i].id]) { allowed[list[i].id] = true; n++; }
        captureAllowed = allowed;
    }
    function noteCapture(id) { if (!capturedIds[id]) { capturedIds[id] = true; captureCount++; } }
    property Component thumbnail: Component {
        Item {
            id: pic
            property string winId: ""
            property bool capturing: false
            readonly property bool allowed: ov.captureAllowed[winId] === true
            readonly property bool live: capturing && allowed
            onLiveChanged: if (live) ov.noteCapture(winId)
            readonly property bool ready: inner.item ? inner.item.ready === true : false
            readonly property bool pending: inner.item ? inner.item.pending === true : false
            function refresh() { if (inner.item && live) { ov.refreshCount++; inner.item.refresh(); } }
            Loader {
                id: inner
                anchors.fill: parent
                sourceComponent: ov.pictureSource
                onLoaded: {
                    item.winId = Qt.binding(function () { return pic.winId; });
                    item.capturing = Qt.binding(function () { return pic.live; });
                }
            }
        }
    }
    // Settled, the pictures are refreshed one window at a time instead of
    // streamed: a 4K panel on integrated graphics cannot afford a live stream
    // per window, and one capture every 150 ms keeps a single window close to
    // live and a full desk fresh within a second. None while anything moves,
    // and none for 300 ms after.
    property bool calm: false
    readonly property bool quietNow: settled && !dragActive() && !scrolling
    onQuietNowChanged: { calm = false; if (quietNow) calmTimer.restart(); else calmTimer.stop(); }
    Timer { id: calmTimer; interval: 300; onTriggered: ov.calm = true }
    property int refreshAt: 0
    Timer {
        interval: 150; repeat: true
        running: ov.quietNow && ov.calm
        onTriggered: {
            var n = ov.gridOrder.length;
            if (!n) return;
            ov.refreshAt = (ov.refreshAt + 1) % n;
            var id = ov.gridOrder[ov.refreshAt].id;
            for (var i = 0; i < cardRep.count; i++) { var c = cardRep.itemAt(i); if (c && c.wid === id) { c.refreshPicture(); break; } }
        }
    }
    // Working agents share one twelve-step turn (1.3 s a revolution). Stepped,
    // not animated: the scene redraws nine times a second for it, not sixty.
    property int spin: 0
    readonly property bool anyWorking: {
        for (var i = 0; i < gridOrder.length; i++) if (gridOrder[i].agent === "working") return true;
        return false;
    }
    Timer { interval: 110; repeat: true; running: ov.settled && ov.anyWorking; onTriggered: ov.spin = (ov.spin + 1) % 12 }

    // ---- intents ---------------------------------------------------------------
    function choose(id) {
        var w = byId[id];
        if (!w || closing) return;
        activateWindow(id);
        close(w.desk === activeDesk ? "back" : "leave");
    }
    function chooseDesk(id) {
        if (closing) return;
        if (id === activeDesk) { close("back"); return; }
        activateDesk(id);
        close("leave");
    }
    function requestCloseWindow(id) { closeWindow(id); }
    function hoverSelect(id) { selectedId = id; showSelection = false; }
    function firstWaiting() {
        for (var i = 0; i < windows.length; i++) if (windows[i].agent === "waiting") return windows[i].id;
        return "";
    }
    function selectedWindow() {
        var id = gridLayout[selectedId] && byId[selectedId] ? selectedId : (gridOrder.length ? gridOrder[0].id : "");
        return id ? byId[id] : null;
    }
    function selectFirstLater() {
        Qt.callLater(function () {
            if (!gridLayout[selectedId]) { selectedId = gridOrder.length ? gridOrder[0].id : ""; showSelection = selectedId !== ""; }
        });
    }

    // ---- operations, results and undo (SPEC 2.4, 2.5 Undo, 3.4) -------------------
    // An op is sent once; the overview waits for the back end's answer (no
    // optimistic state). No answer within 600 ms: re-read, and say it failed.
    property var undoStack: []           // inverse ops of this opening, newest last
    property var pendingOps: ({})        // seq -> { op, inverse, undoable, isUndo, at, viewAfter }
    property int pendingCount: 0
    property var timedOut: ({})          // seqs given up on after 600 ms (a late answer may still come)
    property var lastOp: null            // { op, seq, ok, why, ms } (no titles)
    property double lastOpDoneAt: 0
    signal rereadRequested()
    property int sentTag: 0
    property int sentSeq: -1
    // The host's answer to operate(): the back end's seq, -2 = an older back end that reports nothing, -1 = not sent.
    function opSent(tag, seq) { if (tag === sentTag) sentSeq = (typeof seq === "number") ? seq : -2; }
    function inverseOf(op) {
        var w = op.win ? byId[op.win] : null;
        if (op.op === "move" || op.op === "newdesk") return w ? { op: "move", win: op.win, desk: w.desk } : null;
        if (op.op === "reorder") {
            var S = (op.positions || realDesks).slice(), inv = [];
            for (var j = 0; j < S.length; j++) { var i = op.order.indexOf(S[j]); if (i < 0) return null; inv.push(S[i]); }
            return op.positions ? { op: "reorder", order: inv, positions: S } : { op: "reorder", order: inv };
        }
        return null;                      // insert: undo is disabled (SPEC 2.5)
    }
    function requestOp(op, opts) {
        if (!op || !op.op) return -1;
        opts = opts || {};
        // "New desk" is the number its tile showed: the first after the desks the bar shows, not after the existing ones.
        if (op.op === "newdesk" && !op.desk && newDeskId > 0) op.desk = newDeskId;
        var inverse = opts.isUndo ? null : inverseOf(op);
        sentTag++;
        op.tag = sentTag;
        sentSeq = -1;
        operate(op);                       // the host answers synchronously through opSent(tag, seq)
        var seq = sentSeq;
        var viewAfter = opts.viewAfter;
        if (viewAfter === undefined && op.op === "reorder") {
            // The viewed desk keeps being viewed under its new number.
            var S = op.positions || realDesks, i = op.order.indexOf(viewedDesk);
            if (i >= 0 && i < S.length) viewAfter = S[i];
        }
        var entry = { op: op, inverse: inverse, undoable: inverse !== null, isUndo: !!opts.isUndo, at: Date.now(), viewAfter: viewAfter,
                      snapshot: deskSnapshot() };
        if (seq === -2) { opDone(-2, true, "", entry); return seq; }
        if (seq < 0) { opDone(seq, false, "not sent", entry); return seq; }
        var p = pendingOps; p[seq] = entry; pendingOps = p; pendingCount++;
        opTimeout.restart();
        return seq;
    }
    function opDone(seq, ok, why, direct) {
        var e = direct || pendingOps[seq];
        if (!direct) {
            if (!e) {
                // A late answer to an op this scene gave up on (600 ms) says it did happen after all. Any other
                // answer (the back end's own heal after a re-read) is not ours: it must not cover a failure pill.
                if (timedOut[seq]) { delete timedOut[seq]; if (ok) pill.show("ok", "Moved", false); }
                return;
            }
            delete pendingOps[seq]; pendingCount = Math.max(0, pendingCount - 1);
        }
        lastOpDoneAt = Date.now();
        lastOp = { op: e.op.op, seq: seq, ok: ok, why: ok ? "" : String(why || "").slice(0, 60), ms: Date.now() - e.at };
        console.log("overview: op " + e.op.op + " " + (ok ? "ok" : "fail " + lastOp.why) + " " + lastOp.ms + " ms");
        if (!ok) { queued = null; awaitSnap = null; rereadRequested(); pill.show("fail", failureWords(lastOp.why), false); return; }
        // The next queued key waits until the model shows this op (no second op built on a stale model).
        if (!modelMoved(e.snapshot)) { awaitSnap = e.snapshot; awaitTimer.restart(); }
        if (e.viewAfter !== undefined && e.viewAfter !== null) viewedDesk = e.viewAfter;
        if (e.isUndo) { pill.show("ok", "Moved back", false); return; }
        if (e.op.op === "insert") { undoStack = []; pill.show("ok", "Moved", false); return; }
        if (e.undoable) { var s = undoStack.slice(); s.push(e.inverse); undoStack = s; }
        pill.show("ok", "Moved", e.undoable);
        selectFirstLater();
    }
    Timer {
        id: opTimeout
        interval: 600
        onTriggered: {
            var now = Date.now(), any = false;
            for (var k in ov.pendingOps) {
                var e = ov.pendingOps[k];
                if (now - e.at >= 590) { ov.timedOut[k] = true; delete ov.pendingOps[k]; ov.pendingCount = Math.max(0, ov.pendingCount - 1); ov.opDone(Number(k), false, "no answer in 600 ms", e); }
                else any = true;
            }
            if (any) opTimeout.restart();
        }
    }
    // What a failure means, in his words (A4). why is the op reply's short reason.
    function failureWords(why) {
        var own = /^desk-layout-([0-9]+)$/.exec(why || "");
        if (own) return "Couldn't move it — Desk " + own[1] + " has its own layout";
        if (/rollback-failed/.test(why || "")) return "Couldn't finish — putting desks back";
        return "Couldn't move it — nothing changed";
    }

    // ---- one op at a time (review: two quick Alt+Shift+Right sent the same swap twice) ----------------
    // While an op is on its way, and until the model shows what it did, the next move key waits and is then
    // built from the fresh model: one-place moves add up (two quick Alt+Shift+Right = two places), any other
    // move or Ctrl+Z replaces what waits.
    property var awaitSnap: null          // the desk of every window when the last op was sent, until the model moves
    Timer { id: awaitTimer; interval: 400; onTriggered: ov.awaitSnap = null }
    property bool hostBusy: false         // the back end still settling the last op (it refuses a new one meanwhile)
    readonly property bool opBusy: pendingCount > 0 || dragCtl.commit !== null || awaitSnap !== null || hostBusy
    property var queued: null             // { kind: "desk" | "window", d: steps } or { kind: "other", run: fn }
    onOpBusyChanged: if (!opBusy && queued) Qt.callLater(flushQueued)
    function deskSnapshot() {
        var m = { active: activeDesk };
        for (var i = 0; i < windows.length; i++) m[windows[i].id] = windows[i].desk;
        return m;
    }
    function modelMoved(snap) {
        if (!snap) return true;
        if (snap.active !== activeDesk) return true;
        for (var i = 0; i < windows.length; i++) if (snap[windows[i].id] !== undefined && snap[windows[i].id] !== windows[i].desk) return true;
        return false;
    }
    function queueMove(kind, d) {
        queued = { kind: kind, d: (queued && queued.kind === kind ? queued.d : 0) + d };
    }
    function queueRun(fn) { queued = { kind: "other", run: fn }; }
    function flushQueued() {
        var q = queued;
        queued = null;
        if (!q || opBusy || !isOpen || closing) return;
        if (q.run) q.run();
        else if (q.d && q.kind === "desk") moveViewedDeskBy(q.d);
        else if (q.d) moveSelectedBy(q.d);
    }
    function hideResult() { pill.hide(); }

    function undo() {
        if (opBusy) { if (undoStack.length) queueRun(undo); return undoStack.length > 0; }
        if (!undoStack.length) return false;
        var s = undoStack.slice(), inv = s.pop();
        undoStack = s;
        requestOp(inv, { isUndo: true });
        return true;
    }
    function moveWindow(id, desk) { if (id && desk > 0) requestOp({ op: "move", win: id, desk: desk }); }   // used by the drag (DragController)
    function moveSelectedTo(n) {
        if (opBusy) { queueRun(function () { moveSelectedTo(n); }); return; }
        var w = selectedWindow();
        if (!w || n < 1 || n === w.desk) return;
        requestOp({ op: "move", win: w.id, desk: n });
    }
    function moveSelectedToNew() { if (opBusy) { queueRun(moveSelectedToNew); return; } var w = selectedWindow(); if (w) requestOp({ op: "newdesk", win: w.id }); }
    function moveSelectedBy(d) {
        if (opBusy) { queueMove("window", d); return; }
        var w = selectedWindow();
        if (!w) return;
        var S = realDesks, i = S.indexOf(w.desk), j = Math.max(0, i + d);
        if (i < 0 || j === i) return;
        if (j >= S.length) requestOp({ op: "newdesk", win: w.id });
        else requestOp({ op: "move", win: w.id, desk: S[j] });
    }
    function moveViewedDeskBy(d) {
        if (opBusy || dragActive()) { if (!dragActive()) queueMove("desk", d); return; }
        // Through the drag machine: the strip shows the new order (pills relabelled) at once and lands it
        // without a wrong frame when the compositor confirms (one op, same path as a desk drag). Several
        // queued steps go as one move, as far as the strip reaches.
        var S = ownDesks, i = S.indexOf(viewedDesk);
        if (S.length < 2 || i < 0) return;
        var j = Math.max(0, Math.min(S.length - 1, i + d));
        if (j !== i) dragCtl.moveDesk(viewedDesk, j - i);
    }
    function newEmptyDesk() { if (newDeskId > 0) pageTo(newDeskId); }
    function viewDesk(n) { if (deskOrder.indexOf(n) >= 0) pageTo(n); }

    // Dragging (DragController.qml, lane 3). Its op requests come here, so drops,
    // keys and undo share one path, one result pill and one undo stack.
    DragController { id: dragCtl; scene: ov; bar: stripLayer }
    Connections {
        target: dragCtl
        ignoreUnknownSignals: true
        function onOpRequested(op) { ov.requestOp(op); }
    }
    readonly property var dragController: dragCtl
    function beginDrag(id, p) { dragCtl.beginDrag(id, p); }
    function dragTo(p) { dragCtl.dragTo(p); }
    function endDrag() { dragCtl.endDrag(); }
    function dragActive() { return dragCtl.kind !== undefined ? dragCtl.kind !== "" : dragCtl.dragId !== ""; }
    // Test hook (shell IPC "drag"): the same methods a pointer drives, without a pointer (SPEC E5).
    function dragHook(kind, id, x, y, phase) {
        var p = Qt.point(x, y), dc = dragCtl;
        if (!isOpen || closing) return "closed";
        // DragController.drive: begin pick move drop cancel lift aim step movedesk state; answers its state as JSON.
        if (typeof dc.drive === "function") return dc.drive(kind, id, x, y, phase);
        if (typeof dc.begin === "function") {
            if (phase === "begin") dc.begin(kind, kind === "desk" ? Number(id) : id, p);
            else if (phase === "move") dc.move(p);
            else if (phase === "drop") dc.drop();
            else if (phase === "cancel") dc.cancel();
            else return "bad phase";
        } else {
            if (kind !== "window") return "unsupported";
            if (phase === "begin") dc.beginDrag(id, p);
            else if (phase === "move") dc.dragTo(p);
            else if (phase === "drop") dc.endDrag();
            else if (phase === "cancel") { dc.dragId = ""; dc.dropDesk = -1; }
            else return "bad phase";
        }
        return JSON.stringify({ kind: dc.kind !== undefined ? dc.kind : (dc.dragId ? "window" : ""),
                                target: dc.target !== undefined ? dc.target : dc.dropDesk });
    }
    // Where the strip really draws each desk (scene coordinates), for status() and scripted drops.
    function tileRects() {
        var out = [], ids = stripLayer.ids.concat([stripLayer.plusId]);
        for (var i = 0; i < ids.length; i++) {
            var r = stripLayer.tileRect(i === ids.length - 1 ? "plus" : ids[i]);
            out.push({ id: ids[i], x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), plus: i === ids.length - 1 });
        }
        return out;
    }
    // The viewed grid's cards (ids and rects only, never a title), for status() and scripted drags.
    function cardRects() {
        var out = [];
        for (var i = 0; i < gridOrder.length; i++) {
            var r = gridLayout[gridOrder[i].id];
            if (r) out.push({ id: gridOrder[i].id, x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h) });
        }
        return out;
    }
    function pillState() { return pill.up ? { kind: pill.shownKind, text: pill.shownText, undo: pill.undoable, undoRect: pill.undoRect() } : null; }
    function cancelDrag() {
        if (typeof dragCtl.cancel === "function") { if (dragActive()) dragCtl.cancel(); }
        else { dragCtl.dragId = ""; dragCtl.dropDesk = -1; }
    }

    // ---- keyboard (SPEC 2.7) -----------------------------------------------------------
    function digitOf(e) {
        var k = e.key;
        if (k >= Qt.Key_1 && k <= Qt.Key_9) return k - Qt.Key_0;
        // With Shift held the number row reports its symbol (US layout).
        var sym = [Qt.Key_Exclam, Qt.Key_At, Qt.Key_NumberSign, Qt.Key_Dollar, Qt.Key_Percent, Qt.Key_AsciiCircum, Qt.Key_Ampersand, Qt.Key_Asterisk, Qt.Key_ParenLeft];
        var i = sym.indexOf(k);
        return i >= 0 ? i + 1 : 0;
    }
    focus: true
    Keys.onPressed: function (e) {
        if (tracking && e.key === Qt.Key_Escape) { close("back"); e.accepted = true; return; }
        if (!isOpen || closing || tracking) { e.accepted = true; return; }
        var k = e.key, m = e.modifiers;
        var ctrl = (m & Qt.ControlModifier) !== 0, alt = (m & Qt.AltModifier) !== 0, shift = (m & Qt.ShiftModifier) !== 0;
        var n = digitOf(e), lr = k === Qt.Key_Left ? -1 : k === Qt.Key_Right ? 1 : 0;
        var dragging = dragActive();
        if (k === Qt.Key_Escape) {
            if (dragging) cancelDrag();
            else if (query.length) { query = ""; selectedId = ""; showSelection = false; }
            else close("back");
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (dragging && typeof dragCtl.drop === "function") dragCtl.drop();
            else {
                var target = gridLayout[selectedId] ? selectedId : (gridOrder.length ? gridOrder[0].id : "");
                if (target) choose(target);
                else if (viewedDesk !== activeDesk) chooseDesk(viewedDesk);
                else close("back");
            }
        } else if (ctrl && shift && n) {
            moveSelectedTo(n);
        } else if (ctrl && shift && k === Qt.Key_N) {
            moveSelectedToNew();
        } else if (ctrl && shift && lr) {
            moveSelectedBy(lr);
        } else if (alt && shift && lr) {
            moveViewedDeskBy(lr);
        } else if (ctrl && !shift && k === Qt.Key_N) {
            newEmptyDesk();
        } else if (ctrl && !shift && k === Qt.Key_Z) {
            undo();
        } else if ((ctrl || alt) && !shift && n) {
            // Ctrl or Alt with a number views that desk (it stays open); a bare
            // number is the first letter of a search ("1Password").
            viewDesk(n);
        } else if (dragging && lr && typeof dragCtl.aim === "function") {
            var cur = dragCtl.target && dragCtl.target.id ? dragCtl.target.id : viewedDesk;
            var i = deskOrder.indexOf(cur) + lr;
            if (i >= 0 && i < deskOrder.length) dragCtl.aim(deskOrder[i]);
        } else if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down) {
            var dir = k === Qt.Key_Left ? "left" : k === Qt.Key_Right ? "right" : k === Qt.Key_Up ? "up" : "down";
            if (!gridLayout[selectedId]) selectedId = gridOrder.length ? gridOrder[0].id : "";
            else if (showSelection) selectedId = L.neighbour(gridLayout, selectedId, dir);
            showSelection = selectedId !== "";
        } else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            var real = realDesks;
            if (!real.length) { e.accepted = true; return; }
            query = "";
            var idx = Math.max(0, real.indexOf(viewedDesk));
            var step = (k === Qt.Key_Backtab || shift) ? -1 : 1;
            pageTo(real[(idx + step + real.length) % real.length]);
            selectedId = ""; showSelection = false;
            Qt.callLater(function () { if (gridOrder.length) { selectedId = gridOrder[0].id; showSelection = true; } });
        } else if ((ctrl && k === Qt.Key_W) || k === Qt.Key_Delete) {
            if (selectedId && gridLayout[selectedId]) closeWindow(selectedId);
        } else if (k === Qt.Key_Backspace) {
            if (query.length) query = ctrl ? "" : query.slice(0, -1);
            afterQuery();
        } else if (k === Qt.Key_Space && !query.length && !ctrl && !alt) {
            // Space lifts the selected window for a keyboard drag (arrows aim, Enter drops, Esc cancels).
            if (typeof dragCtl.liftSelected === "function") dragCtl.liftSelected();
        } else if (e.text.length === 1 && e.text >= " " && !ctrl && !alt) {
            if (query.length || e.text !== " ") { endPaging(); query += e.text; afterQuery(); }
        }
        e.accepted = true;
    }
    function afterQuery() {
        if (query.length) { selectedId = gridOrder.length ? gridOrder[0].id : ""; showSelection = selectedId !== ""; }
        else { selectedId = ""; showSelection = false; }
    }

    // ---- the picture ----------------------------------------------------------------
    // Nothing of the overview is drawn at t = 0: a stroke that has begun but
    // not yet moved leaves the frame exactly the desktop (the never-cuts test).
    // Nothing is drawn into the one-pixel surface either: when it grows, Hyprland
    // stretches that pixel over the whole screen for a frame or two.
    opacity: t > 0 && surfaceReady ? 1 : 0

    // The ground: his wallpaper, softened. It is opaque on purpose. The real
    // windows stay hidden behind it, so each window is on screen exactly once
    // (its card) and the overview looks the same over a white browser as over
    // a black terminal; and the compositor has nothing to blur, which on this
    // laptop is the difference between a smooth flight and a dropped one.
    // It is there from the first frame of the flight and goes only as the
    // windows land.
    Item {
        id: ground
        anchors.fill: parent
        opacity: Math.min(1, ov.t * 25)
        visible: opacity > 0
        Rectangle { anchors.fill: parent; color: Qt.rgba(ov.background.r, ov.background.g, ov.background.b, 1) }
        // Blurred small and scaled up: softer, and a fraction of the work of blurring 4K.
        Item {
            id: groundSmall
            width: Math.ceil(ground.width / 5)
            height: Math.ceil(ground.height / 5)
            transform: Scale { xScale: ground.width / groundSmall.width; yScale: ground.height / groundSmall.height }
            layer.enabled: true
            layer.smooth: true
            Image {
                id: groundImage
                anchors.fill: parent
                source: ov.wallpaper
                sourceSize: Qt.size(960, 600)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                retainWhileLoading: true
                smooth: true
                visible: false
            }
            MultiEffect {
                anchors.fill: parent
                source: groundImage
                blurEnabled: true
                blur: 1
                blurMax: 32
                autoPaddingEnabled: false
                visible: groundImage.status === Image.Ready
            }
        }
    }
    // Dim over the ground; slightly deeper at the top so the strip reads on
    // any wallpaper. It arrives ahead of the windows, so the ground they
    // uncover is already quiet.
    readonly property real dimIn: Math.min(1, t * 2.4)
    Rectangle {
        anchors.fill: parent
        color: ov.dimColor
        opacity: ov.dimIn
    }
    Rectangle {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: ov.stripBottom + 120 * ov.u
        opacity: ov.dimIn
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(ov.dimColor.r, ov.dimColor.g, ov.dimColor.b, ov.lightMode ? 0.35 : 0.45) }
            GradientStop { position: 1; color: "transparent" }
        }
    }

    // A click on the backdrop enters the viewed desk if he switched to one, or goes back; a 2-finger sideways scroll pages desks.
    MouseArea {
        anchors.fill: parent
        enabled: ov.isOpen && !ov.closing
        acceptedButtons: Qt.AllButtons
        onClicked: if (ov.viewedDesk !== ov.activeDesk) ov.chooseDesk(ov.viewedDesk); else ov.close("back")
    }
    WheelHandler {
        enabled: ov.isOpen && !ov.closing && !ov.tracking
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function (ev) {
            var px = ev.pixelDelta.x, ax = ev.angleDelta.x;
            if (ev.phase === Qt.ScrollEnd) { ov.scrollRelease(); return; }
            if (px !== 0) ov.scrollBy(px);
            else if (ax !== 0 && ev.phase === Qt.NoScrollPhase) {
                // A mouse's sideways wheel: one desk per notch (including "+ New desk").
                var i = ov.pageIndex(ov.viewedDesk) + (ax < 0 ? 1 : -1);
                if (i >= 0 && i < ov.deskOrder.length) ov.pageTo(ov.deskOrder[i]);
            }
        }
    }

    // Desks along the top (SpacesBar.qml): they come down after the windows
    // start to shrink, over t 0.25 -> 1 (the windows lead, the strip follows).
    readonly property real stripIn: Math.max(0, Math.min(1, (t - 0.25) / 0.75))
    SpacesBar {
        id: stripLayer
        scene: ov
        drag: dragCtl
        desks: ov.desks
        activeDesk: ov.activeDesk
        viewedDesk: ov.viewedDesk
        width: parent.width
        height: parent.height
        y: -258 * ov.u * (1 - ov.stripIn)
        opacity: ov.stripIn
        visible: opacity > 0
        onTileTapped: function (id) { if (id === ov.viewedDesk) ov.chooseDesk(id); else ov.pageTo(id); }
        onTileDoubleTapped: function (id) { ov.chooseDesk(id); }
        onPlusTapped: { if (ov.viewedDesk === ov.newDeskId) ov.chooseDesk(ov.newDeskId); else ov.newEmptyDesk(); }
        onHoverOpen: function (id) { ov.pageTo(id); }
    }

    // Agents: one line, top right, only when it is true. A click goes to the first.
    Item {
        id: summary
        visible: ov.waitingCount > 0
        anchors.right: parent.right
        anchors.rightMargin: 40 * ov.u
        y: 16 * ov.u + stripLayer.y
        width: sumRow.implicitWidth + 34 * ov.u
        height: 40 * ov.u
        opacity: ov.stripIn
        Rectangle {
            id: summaryPill
            anchors.fill: parent
            radius: height / 2
            color: sumMouse.containsMouse ? Qt.rgba(ov.amber.r, ov.amber.g, ov.amber.b, 0.28) : Qt.rgba(ov.amber.r, ov.amber.g, ov.amber.b, 0.16)
            border.width: 1
            border.color: Qt.rgba(ov.amber.r, ov.amber.g, ov.amber.b, 0.55)
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Math.max(1, ov.u)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: summaryPill.radius * 0.85
                anchors.rightMargin: summaryPill.radius * 0.85
                height: Math.max(1, ov.u)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.55 : 0.22) }
                    GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.55 : 0.22) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }
        Row {
            id: sumRow
            anchors.centerIn: parent
            spacing: 10 * ov.u
            Rectangle {
                width: 9 * ov.u; height: width; radius: width / 2; color: ov.amber
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: ov.waitingCount === 1 ? "1 agent is waiting for you" : ov.waitingCount + " agents are waiting for you"
                color: ov.lightMode ? "#6a4000" : "#ffd58a"
                font.family: ov.uiFont
                font.pixelSize: 15 * ov.u
                font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: sumMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { var id = ov.firstWaiting(); if (id) ov.choose(id); }
        }
    }

    // The search field appears only when he types.
    Item {
        id: search
        anchors.horizontalCenter: parent.horizontalCenter
        y: ov.stripBottom + 8 * ov.u
        width: Math.max(420 * ov.u, searchRow.implicitWidth + 56 * ov.u)
        height: 50 * ov.u
        opacity: ov.query.length && ov.isOpen ? ov.t : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 130 } }
        scale: ov.query.length ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        RectangularShadow {
            anchors.fill: parent; radius: height / 2; blur: 30 * ov.u; offset: Qt.vector2d(0, 10 * ov.u)
            color: ov.shadowColor
        }
        Rectangle {
            id: searchCapsule
            anchors.fill: parent
            radius: height / 2
            color: ov.chipColor
            border.width: Math.max(1, ov.u)
            border.color: ov.lightMode ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.18)
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Math.max(1, ov.u)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: searchCapsule.radius * 0.85
                anchors.rightMargin: searchCapsule.radius * 0.85
                height: Math.max(1, ov.u)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.80 : 0.24) }
                    GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.80 : 0.24) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }
        Row {
            id: searchRow
            anchors.verticalCenter: parent.verticalCenter
            x: 22 * ov.u
            spacing: 12 * ov.u
            // magnifier
            Shape {
                width: 18 * ov.u; height: width
                anchors.verticalCenter: parent.verticalCenter
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: ov.chipInk; strokeWidth: 2.2 * ov.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 7.5 * ov.u; centerY: 7.5 * ov.u; radiusX: 6.5 * ov.u; radiusY: 6.5 * ov.u; startAngle: 0; sweepAngle: 360 }
                    PathMove { x: 12.5 * ov.u; y: 12.5 * ov.u }
                    PathLine { x: 17.5 * ov.u; y: 17.5 * ov.u }
                }
            }
            Text {
                id: queryText
                text: ov.query
                color: ov.chipInk
                font.family: ov.uiFont
                font.pixelSize: 20 * ov.u
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {          // caret
                    x: parent.implicitWidth + 2 * ov.u
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2 * ov.u; height: 24 * ov.u; radius: 1
                    color: ov.accent
                }
            }
        }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 22 * ov.u
            anchors.verticalCenter: parent.verticalCenter
            text: ov.gridOrder.length === 0 ? "no match" : ov.gridOrder.length === 1 ? "1 window" : ov.gridOrder.length + " windows"
            color: Qt.rgba(ov.chipInk.r, ov.chipInk.g, ov.chipInk.b, 0.55)
            font.family: ov.uiFont
            font.pixelSize: 14 * ov.u
            font.features: ({ "tnum": 1 })
            visible: search.width > queryText.implicitWidth + 200 * ov.u
        }
    }

    // When the grid has nothing to show, say so plainly and say what works.
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: ov.gridBox.y + ov.gridBox.h * 0.36
        spacing: 12 * ov.u
        opacity: ov.gridOrder.length === 0 && ov.isOpen && !ov.paging ? ov.t : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ov.query.length ? "Nothing open matches “" + ov.query + "”"
                  : (ov.viewedDesk === ov.newDeskId ? "New Desk " + ov.viewedDesk : "Desk " + ov.viewedDesk + " is empty")
            color: Qt.rgba(ov.ink.r, ov.ink.g, ov.ink.b, ov.lightMode ? 0.84 : 0.82)
            font.family: ov.uiFont
            font.pixelSize: 34 * ov.u
            font.weight: Font.DemiBold
            font.letterSpacing: -0.3 * ov.u
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ov.query.length ? "Esc clears the search" : "Click anywhere, swipe down, or press Enter to switch here — or drag a window in"
            color: ov.inkSoft
            font.family: ov.uiFont
            font.pixelSize: 18 * ov.u
        }
    }

    // Before he types: a quiet frosted glass pill where the search field will appear.
    Item {
        id: idleSearch
        anchors.horizontalCenter: parent.horizontalCenter
        y: ov.stripBottom + 10 * ov.u
        height: 36 * ov.u
        width: idleSearchRow.implicitWidth + 30 * ov.u
        // Last in, under the cards (declared before them): it can never draw over a picture in flight.
        opacity: (ov.query.length || ov.dragId || ov.gridOrder.length === 0 ? 0 : 1) * Math.max(0, Math.min(1, (ov.t - 0.85) / 0.15))
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 130 } }
        RectangularShadow {
            anchors.fill: parent
            radius: height / 2
            blur: 14 * ov.u
            offset: Qt.vector2d(0, 3 * ov.u)
            color: ov.lightMode ? Qt.rgba(0.05, 0.07, 0.15, 0.10) : Qt.rgba(0, 0, 0, 0.28)
        }
        Rectangle {
            id: idleSearchPill
            anchors.fill: parent
            radius: height / 2
            color: ov.lightMode ? Qt.rgba(1, 1, 1, 0.68) : Qt.rgba(1, 1, 1, 0.08)
            border.width: Math.max(1, ov.u)
            border.color: ov.lightMode ? Qt.rgba(0, 0, 0, 0.13) : Qt.rgba(1, 1, 1, 0.16)
            Rectangle {
                anchors.top: parent.top
                anchors.topMargin: Math.max(1, ov.u)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: idleSearchPill.radius * 0.85
                anchors.rightMargin: idleSearchPill.radius * 0.85
                height: Math.max(1, ov.u)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.72 : 0.22) }
                    GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, ov.lightMode ? 0.72 : 0.22) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }
        Row {
            id: idleSearchRow
            anchors.centerIn: parent
            spacing: 9 * ov.u
            Shape {
                width: 14 * ov.u; height: width
                anchors.verticalCenter: parent.verticalCenter
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: Qt.rgba(ov.ink.r, ov.ink.g, ov.ink.b, ov.lightMode ? 0.78 : 0.76)
                    strokeWidth: 1.8 * ov.u; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 5.8 * ov.u; centerY: 5.8 * ov.u; radiusX: 5.0 * ov.u; radiusY: 5.0 * ov.u; startAngle: 0; sweepAngle: 360 }
                    PathMove { x: 9.7 * ov.u; y: 9.7 * ov.u }
                    PathLine { x: 13.5 * ov.u; y: 13.5 * ov.u }
                }
            }
            Text {
                text: "Type to search every desk"
                color: Qt.rgba(ov.ink.r, ov.ink.g, ov.ink.b, ov.lightMode ? 0.78 : 0.76)
                font.family: ov.uiFont
                font.pixelSize: 14 * ov.u
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // Windows. Every window of every desk has one card; the card decides
    // whether it is in the grid. While paging, the whole layer slides.
    Item {
        id: cards
        width: parent.width
        height: parent.height
        x: ov.paging ? -ov.pagePos * ov.width : 0
        Repeater {
            id: cardRep
            model: winList
            delegate: WindowCard {
                scene: ov
            }
        }
    }

    // What an operation did, bottom centre: "Moved · Undo" or "Couldn't move it — nothing changed".
    ResultPill {
        id: pill
        scene: ov
        onUndoRequested: ov.undo()
    }
}
