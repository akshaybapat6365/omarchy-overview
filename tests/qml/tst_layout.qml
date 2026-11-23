import QtQuick
import QtTest
import "../../Layout.js" as L
import "../.."

// Lane 3 fast tests (SPEC 4.2 lane 3 (a)), and the drag logic end to end on the real Scene,
// SpacesBar, DeskTile, WindowCard and DragController with a tiny in-test desktop (ops applied
// the way ops/ovops.lua does), driven through DragController.drive (the IPC test hook's path).
// Run: /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_layout.qml
Item {
    id: root
    width: 2400; height: 1500

    // The strip as the overview builds it at 2400 x 1500 (u = 1): margin 150, gap 30, tiles up to 272.
    function strip(desks, scrollX) { return L.deskStrip(desks + 1, 2400, 150, 30, 272, 2400 / 1500, 130, scrollX || 0); }
    function range(n) { var a = []; for (var i = 1; i <= n; i++) a.push(i); return a; }

    TestCase {
        name: "DeskStrip"

        function test_today_sizes() {
            var s6 = root.strip(6);
            compare(s6.length, 7);
            compare(s6[0].w, 272); compare(s6[0].h, 170);
            verify(!s6.scrolls);
            var s9 = root.strip(9);                 // SPEC 2.2: 9 desks -> 10 items -> 183 x 114
            compare(s9[0].w, 183); compare(s9[0].h, 114);
            verify(!s9.scrolls);
            // centred: equal margins left and right
            var right = 2400 - (s9[9].x + s9[9].w);
            verify(Math.abs(right - s9[0].x) <= 1, "centred " + s9[0].x + " / " + right);
        }
        function test_same_as_today_without_scroll() {
            // The 6-argument call (Scene.qml's) still gives today's numbers for every count that fits.
            for (var n = 1; n <= 12; n++) {
                var a = L.deskStrip(n + 1, 2400, 150, 30, 272, 1.6), b = root.strip(n);
                for (var i = 0; i <= n; i++) { compare(a[i].x, b[i].x); compare(a[i].w, b[i].w); compare(a[i].h, b[i].h); }
                verify(!b.scrolls, n + " desks fit");
                verify(b[0].w >= 130);
            }
        }
        function test_scroll_from_thirteen() {
            // 12 desks + "+" fit at 134 u; 13 desks + "+" would be 122 u: below the 130 floor, so it scrolls.
            verify(!root.strip(12).scrolls);
            compare(L.deskStrip(13, 2400, 150, 30, 272, 1.6)[0].w, 134, "6-argument default floor");
            for (var n = 13; n <= 20; n++) {
                var s = root.strip(n);
                verify(s.scrolls, n + " desks scroll");
                compare(s[0].w, 130);
                compare(s[0].x, 150);                       // starts at the margin
                compare(s.maxScroll, s.contentW - s.viewW);
                verify(s.maxScroll > 0);
            }
            var t = root.strip(13, 1e9);                    // clamped
            compare(t.scrollX, t.maxScroll);
            compare(t[13].x + t[13].w, 2400 - 150);        // "+" ends at the right margin
            compare(root.strip(13, -50).scrollX, 0);
        }
        function test_scroll_to_show() {
            var s = root.strip(13);
            for (var i = 0; i < 14; i++) {
                var sx = L.scrollToShow(s, i), v = root.strip(13, sx);
                verify(v[i].x >= v.viewX - 0.5 && v[i].x + v[i].w <= v.viewX + v.viewW + 0.5, "slot " + i + " visible at " + sx);
            }
            compare(L.scrollToShow(root.strip(6), 3), 0);
        }
        function test_one_desk() {
            var s = root.strip(1);
            compare(s.length, 2);
            compare(s[0].w, 272);
        }
    }

    TestCase {
        name: "PreviewOrder"

        function check(n, from, x) {
            var ids = root.range(n), s = root.strip(n), out = L.previewOrder(ids, from, x, s);
            compare(out.length, n);
            var seen = {};
            for (var i = 0; i < n; i++) { verify(!seen[out[i]]); seen[out[i]] = true; }
            return out;
        }
        function test_every_x_every_desk() {
            for (var n = 1; n <= 9; n++) {
                var s = root.strip(n), ids = root.range(n);
                for (var d = 1; d <= n; d++) {
                    var last = -1, own = s[d - 1].x + s[d - 1].w / 2;
                    for (var x = -100; x <= 2500; x += 1) {
                        var out = check(n, d, x), k = out.indexOf(d);
                        verify(k >= last, "monotonic n=" + n + " d=" + d + " x=" + x);
                        last = k;
                        // others keep their relative order
                        var rest = out.filter(function (v) { return v !== d; });
                        for (var i = 1; i < rest.length; i++) verify(rest[i] > rest[i - 1]);
                        // the dragged desk sits after exactly the neighbours whose centre it has passed
                        var passed = 0;
                        for (var j = 0; j < n; j++) if (j !== d - 1 && s[j].x + s[j].w / 2 < x) passed++;
                        compare(k, passed);
                    }
                    compare(L.previewOrder(ids, d, own, s), ids, "own slot is no change (n=" + n + " d=" + d + ")");
                    compare(check(n, d, -100).indexOf(d), 0);
                    compare(check(n, d, 2500).indexOf(d), n - 1);
                }
            }
        }
        function test_two_to_five() {
            var s = root.strip(6);
            var x = (s[4].x + s[4].w / 2 + s[5].x + s[5].w / 2) / 2;      // between desk 5's and desk 6's centres
            compare(L.previewOrder([1, 2, 3, 4, 5, 6], 2, x, s), [1, 3, 4, 5, 2, 6]);
            var lab = L.labelsFor([1, 3, 4, 5, 2, 6]);
            compare([lab[1], lab[3], lab[4], lab[5], lab[2], lab[6]], [1, 2, 3, 4, 5, 6]);
            compare(lab[2], 5, "the lifted desk already reads 5");
        }
        function test_five_to_two() {
            var s = root.strip(6);
            var x = (s[0].x + s[0].w / 2 + s[1].x + s[1].w / 2) / 2;
            compare(L.previewOrder([1, 2, 3, 4, 5, 6], 5, x, s), [1, 5, 2, 3, 4, 6]);
            compare(L.labelsFor([1, 5, 2, 3, 4, 6])[5], 2);
        }
        function test_one_to_nine() {
            var s = root.strip(9);
            compare(L.previewOrder(root.range(9), 1, 2390, s), [2, 3, 4, 5, 6, 7, 8, 9, 1]);
            compare(L.labelsFor([2, 3, 4, 5, 6, 7, 8, 9, 1])[1], 9);
        }
        function test_sparse_ids_keep_their_set() {
            var s = root.strip(4), x = s[3].x + s[3].w / 2 + 1;
            var out = L.previewOrder([1, 2, 4, 7], 2, x, s);
            compare(out, [1, 4, 7, 2]);
            var lab = L.labelsFor(out);
            compare([lab[1], lab[4], lab[7], lab[2]], [1, 2, 4, 7]);
        }
        function test_thirteen_scrolled() {
            // The preview works in the strip's own coordinates, whatever the scroll.
            var s = root.strip(13), ids = root.range(13);
            var x = s[11].x + s[11].w / 2 + 1;
            compare(L.previewOrder(ids, 2, x, s), [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 2, 13]);
        }
    }

    TestCase {
        name: "Gaps"

        function test_gaps_six() {
            var s = root.strip(6);
            for (var i = 0; i < 5; i++) {
                var a = s[i].x + s[i].w, b = s[i + 1].x, mid = (a + b) / 2;
                compare(L.insertionGap(s, mid, 6), i);
                compare(L.insertionGap(s, a - 14, 6), i, "14 u into the left tile");
                compare(L.insertionGap(s, b + 14, 6), i, "14 u into the right tile");
                compare(L.insertionGap(s, a - 15, 6), -1);
                compare(L.insertionGap(s, b + 15, 6), -1);
                compare(L.insertionGap(s, s[i].x + s[i].w / 2, 6), -1, "tile centre is not a gap");
            }
            var lastGap = (s[5].x + s[5].w + s[6].x) / 2;
            compare(L.insertionGap(s, lastGap, 6), -1, "the gap before + is not an insert point");
            compare(L.insertionGap(root.strip(1), 500, 1), -1);
        }
        function test_strip_hit() {
            var s = root.strip(6), top = 44, bottom = 44 + 170;
            compare(L.stripHit(s, 6, s[2].x + 10 + 15, 100, top, bottom), { type: "desk", index: 2 });
            compare(L.stripHit(s, 6, s[6].x + 50, 100, top, bottom), { type: "plus" });
            var g = L.stripHit(s, 6, s[1].x + s[1].w + 15, 100, top, bottom);
            compare(g.type, "gap"); compare(g.index, 1);
            compare(L.stripHit(s, 6, s[1].x + s[1].w - 10, 100, top, bottom).tile, 1, "a gap zone keeps the tile it overlaps");
            compare(L.stripHit(s, 6, s[2].x + 50, 400, top, bottom), null);
            compare(L.stripHit(s, 6, 20, 100, top, bottom), null);
            // half the gap belongs to each tile: no dead line between the last desk and "+"
            var edge = s[5].x + s[5].w + 15;
            verify(L.stripHit(s, 6, edge - 0.5, 100, top, bottom) !== null);
            verify(L.stripHit(s, 6, edge + 0.5, 100, top, bottom) !== null);
        }
        function test_auto_scroll() {
            compare(L.autoScrollSpeed(1000, 150, 2100, 50, 1500), 0);
            compare(L.autoScrollSpeed(150, 150, 2100, 50, 1500), -1500);
            compare(L.autoScrollSpeed(175, 150, 2100, 50, 1500), -750);
            compare(L.autoScrollSpeed(2250, 150, 2100, 50, 1500), 1500);
            compare(L.autoScrollSpeed(2400, 150, 2100, 50, 1500), 1500);
            compare(L.autoScrollSpeed(2225, 150, 2100, 50, 1500), 750);
        }
        function test_rubber() {
            compare(L.rubberY(0, 0.3, 24), 0);
            verify(Math.abs(L.rubberY(10, 0.3, 24) - 3) < 0.1);
            verify(L.rubberY(1000, 0.3, 24) <= 24);
            verify(L.rubberY(-1000, 0.3, 24) >= -24);
        }
        function test_landing_spot() {
            var t = L.landingSpot({ x: 12, y: 38, w: 1182, h: 1450 }, 2400, 1500);
            verify(t.x > 0.5 && t.x + t.w < 1, "tiled: right half");
            var f = L.landingSpot({ floating: true, x: 600, y: 300, w: 1200, h: 750 }, 2400, 1500);
            compare(f, { x: 0.25, y: 0.2, w: 0.5, h: 0.5 });
        }
    }

    TestCase {
        name: "Grid"

        function test_fourteen_windows_stay_readable() {
            // The "many" fixture: 14 windows of 465 x 475 on one desk. Grid box as Scene builds it at u = 1
            // for a 6-desk strip: strip bottom 44 + 170 + 46 = 260; box y 330, bottom margin 84.
            var items = [];
            for (var i = 0; i < 14; i++) items.push({ id: "w" + i, w: 465, h: 475 });
            var box = { x: 104, y: 330, w: 2192, h: 1500 - 330 - 84 };
            var r = L.justify(items, box, 46, 58, 1.5), n = 0;
            for (var id in r) { n++; verify(r[id].h >= 120, id + " " + r[id].h); verify(r[id].y >= box.y && r[id].y + r[id].h <= box.y + box.h); }
            compare(n, 14);
            for (var m = 15; m <= 24; m++) {
                items.push({ id: "w" + (m - 1), w: 465, h: 475 });
                var rr = L.justify(items, box, 46, 58, 1.5);
                for (id in rr) verify(rr[id].h >= 120, m + " windows: " + rr[id].h);
            }
        }
    }

    // ---- the tiny desktop the integration tests run on ---------------------------------------
    readonly property var fixtures: ({
        six: { active: 3, w: [["0xb000", 1, 12, 38, 2376, 1450], ["0xb001", 2, 12, 38, 2376, 1450], ["0xb002", 3, 12, 38, 1182, 1450], ["0xb003", 3, 1206, 38, 1182, 719], ["0xb004", 3, 1206, 769, 585, 719], ["0xb005", 3, 1803, 769, 585, 353], ["0xb006", 3, 1803, 1134, 585, 354], ["0xb007", 4, 12, 38, 1182, 1450], ["0xb008", 4, 1206, 38, 1182, 1450], ["0xb009", 5, 12, 38, 2376, 1450], ["0xb00a", 6, 12, 38, 2376, 1450]] },
        nine: { active: 5, w: [["0xc000", 1, 12, 38, 2376, 1450], ["0xc001", 2, 12, 38, 1182, 1450], ["0xc002", 2, 1206, 38, 1182, 1450], ["0xc003", 3, 12, 38, 2376, 1450], ["0xc004", 4, 12, 38, 2376, 1450], ["0xc005", 5, 12, 38, 1182, 1450], ["0xc006", 5, 1206, 38, 1182, 719], ["0xc007", 5, 1206, 769, 585, 719], ["0xc008", 5, 1803, 769, 585, 719], ["0xc009", 6, 12, 38, 2376, 1450], ["0xc00a", 7, 12, 38, 2376, 1450], ["0xc00b", 8, 12, 38, 2376, 1450], ["0xc00c", 9, 12, 38, 2376, 1450]] },
        thirteen: { active: 7, w: [["0xd000", 1, 12, 38, 2376, 1450], ["0xd001", 2, 12, 38, 2376, 1450], ["0xd002", 3, 12, 38, 2376, 1450], ["0xd003", 4, 12, 38, 2376, 1450], ["0xd004", 5, 12, 38, 2376, 1450], ["0xd005", 6, 12, 38, 2376, 1450], ["0xd006", 7, 12, 38, 1182, 1450], ["0xd007", 7, 1206, 38, 1182, 719], ["0xd008", 7, 1206, 769, 1182, 719], ["0xd009", 8, 12, 38, 2376, 1450], ["0xd00a", 9, 12, 38, 2376, 1450], ["0xd00b", 10, 12, 38, 2376, 1450], ["0xd00c", 11, 12, 38, 2376, 1450], ["0xd00d", 12, 12, 38, 2376, 1450], ["0xd00e", 13, 12, 38, 2376, 1450]] },
        one: { active: 1, w: [["0xa000", 1, 12, 38, 1182, 1450], ["0xa001", 1, 1206, 38, 1182, 1450]] }
    })
    property var raw: []
    property int active: 1
    property var opLog: []
    property bool deferOps: false             // true: ops wait (like the real back end) until flushOps()
    property var pendingOps: []
    function load(name) {
        var f = fixtures[name];
        raw = f.w.map(function (a) { return { id: a[0], desk: a[1], x: a[2], y: a[3], w: a[4], h: a[5] }; });
        active = f.active;
        opLog = []; pendingOps = []; deferOps = false;
    }
    function deskIds() {
        var s = {};
        for (var i = 0; i < raw.length; i++) s[raw[i].desk] = true;
        s[active] = true;
        return Object.keys(s).map(Number).sort(function (a, b) { return a - b; });
    }
    readonly property var deskList: {
        raw; active;
        var ids = deskIds(), out = [];
        for (var i = 0; i < ids.length; i++) {
            var n = 0;
            for (var j = 0; j < raw.length; j++) if (raw[j].desk === ids[i]) n++;
            out.push({ id: ids[i], name: n ? "Desk content " + ids[i] : "Empty", isNew: false, waiting: 0, count: n });
        }
        out.push({ id: (ids.length ? ids[ids.length - 1] : 0) + 1, name: "New desk", isNew: true, waiting: 0, count: 0 });
        return out;
    }
    function setDesk(map) {
        raw = raw.map(function (w) { var c = Object.assign({}, w); var d = map(c.desk, c.id); if (d !== c.desk) { c.desk = d; c.x = 12; c.y = 38; c.w = 2376; c.h = 1450; } return c; });
    }
    function apply(op) {
        var ids = deskIds(), max = ids[ids.length - 1];
        if (op.op === "move") setDesk(function (d, id) { return id === op.win ? op.desk : d; });
        else if (op.op === "newdesk") setDesk(function (d, id) { return id === op.win ? max + 1 : d; });
        else if (op.op === "reorder") {
            var s = ids.slice(), m = {};
            for (var i = 0; i < op.order.length; i++) m[op.order[i]] = s[i];
            raw = raw.map(function (w) { var c = Object.assign({}, w); c.desk = m[c.desk] !== undefined ? m[c.desk] : c.desk; return c; });
            if (m[active] !== undefined) active = m[active];
        } else if (op.op === "insert") {
            var free = -1;
            for (var k = op.left + 1; k < op.right; k++) if (ids.indexOf(k) < 0) { free = k; break; }
            if (free < 0) {
                raw = raw.map(function (w) { var c = Object.assign({}, w); if (c.desk >= op.right) c.desk++; return c; });
                if (active >= op.right) active++;
                free = op.right;
            }
            setDesk(function (d, id) { return id === op.win ? free : d; });
        }
    }
    function flushOps() { var p = pendingOps; pendingOps = []; for (var i = 0; i < p.length; i++) apply(p[i]); }

    Scene {
        id: scene
        anchors.fill: parent
        windows: root.raw.map(function (w, i) { return { id: w.id, desk: w.desk, x: w.x, y: w.y, w: w.w, h: w.h, title: "Test window", label: "Test window", app: "Test", icon: "", agent: "", focusRank: i }; })
        desks: root.deskList
        activeDesk: root.active
        thumbnail: Component {
            Rectangle {
                property string winId: ""
                property bool capturing: false
                readonly property bool ready: capturing
                readonly property bool pending: false
                function refresh() {}
                color: "#445"
            }
        }
    }

    TestCase {
        id: it
        name: "Drag"
        when: windowShown
        property var ctl: null
        property var bar: null

        function initTestCase() {
            var d = scene.data, c = scene.children;
            for (var i = 0; i < d.length; i++) if (d[i] && d[i].objectName === "overviewDrag") ctl = d[i];
            for (i = 0; i < c.length; i++) if (c[i] && c[i].objectName === "overviewSpacesBar") bar = c[i];
            verify(ctl !== null, "controller found"); verify(bar !== null, "strip found");
            compare(ctl.bar, bar, "the strip registered itself with the controller");
            ctl.opRequested.connect(function (op) {
                root.opLog = root.opLog.concat([ctl.describe(op)]);
                if (root.deferOps) root.pendingOps = root.pendingOps.concat([op]); else root.apply(op);
            });
            bar.hoverOpen.connect(function (id) { scene.viewedDesk = id; });
        }
        function open(name) {
            if (scene.isOpen) { scene.snapShut(); }
            root.load(name);
            wait(20);
            scene.viewedDesk = root.active;
            scene.open();
            tryVerify(function () { return scene.settled; }, 3000, "settled");
            wait(50);
        }
        function drv(kind, id, x, y, phase) { return JSON.parse(ctl.drive(kind, String(id), x, y, phase)); }
        function centre(id) { var r = bar.tileRect(id); return Qt.point(r.x + r.width / 2, r.y + r.height / 2); }
        function slide(kind, id, from, to, steps) {
            var s = null;
            for (var i = 1; i <= steps; i++) s = drv(kind, id, from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps, "move");
            return s;
        }
        function cardCentre(wid) { var g = scene.layout[wid]; return Qt.point(g.x + g.w / 2, g.y + g.h / 2); }

        function test_a_two_to_five_and_back() {
            open("six");
            var c2 = centre(2), c5 = centre(5), c6 = centre(6);
            var s = drv("desk", 2, c2.x, c2.y, "begin");
            verify(s.ok); compare(s.kind, "desk");
            s = slide("desk", 2, c2, Qt.point((c5.x + c6.x) / 2, c2.y + 30), 12);
            compare(s.previewOrder, [1, 3, 4, 5, 2, 6], "reads 1 3 4 5 [2] 6 during the drag");
            compare(s.labels, [1, 2, 3, 4, 5, 6], "pills already show positions");
            compare(bar.labels[2], 5, "the lifted desk reads 5");
            compare(root.opLog, [], "nothing sent before the drop");
            s = drv("desk", 2, 0, 0, "drop");
            compare(root.opLog, ["reorder [1,3,4,5,2,6]"]);
            // the tiny desktop renumbered: old 3 -> 2, old 4 -> 3, old 5 -> 4, old 2 -> 5; 1 and 6 untouched
            var byId = {}; for (var i = 0; i < root.raw.length; i++) byId[root.raw[i].id] = root.raw[i].desk;
            compare([byId["0xb000"], byId["0xb001"], byId["0xb002"], byId["0xb007"], byId["0xb009"], byId["0xb00a"]], [1, 5, 2, 3, 4, 6]);
            compare(root.active, 2, "the desk he is on moved from 3 to 2");
            compare(ctl.commit, null, "the commit landed at once (synchronous back end)");
            compare(ctl.previewOrder, []);
            // five to two, the mirror
            root.opLog = [];
            open("six");
            c5 = centre(5); var c1 = centre(1); c2 = centre(2);
            drv("desk", 5, c5.x, c5.y, "begin");
            s = slide("desk", 5, c5, Qt.point((c1.x + c2.x) / 2, c5.y), 12);
            compare(s.previewOrder, [1, 5, 2, 3, 4, 6]);
            compare(bar.labels[5], 2);
            drv("desk", 5, 0, 0, "drop");
            compare(root.opLog, ["reorder [1,5,2,3,4,6]"]);
        }
        function test_b_one_to_nine() {
            open("nine");
            var c1 = centre(1), c9 = centre(9), p = bar.tileRect("plus");
            drv("desk", 1, c1.x, c1.y, "begin");
            var s = slide("desk", 1, c1, Qt.point(c9.x + 20, c1.y), 20);
            compare(s.previewOrder, [2, 3, 4, 5, 6, 7, 8, 9, 1]);
            compare(bar.labels[1], 9);
            drv("desk", 1, 0, 0, "drop");
            compare(root.opLog, ["reorder [2,3,4,5,6,7,8,9,1]"]);
        }
        function test_c_window_moves() {
            open("six");
            var from = cardCentre("0xb003"), c4 = centre(4);
            var s = drv("window", "0xb003", from.x, from.y, "begin");
            verify(s.ok);
            s = slide("window", "0xb003", from, c4, 10);
            compare(s.target, { type: "desk", id: 4 });
            compare(root.opLog, []);
            drv("window", "0xb003", 0, 0, "drop");
            compare(root.opLog, ["move 0xb003→4"]);
            // "+"
            open("six");
            from = cardCentre("0xb003");
            var p = centre("plus");
            drv("window", "0xb003", from.x, from.y, "begin");
            s = slide("window", "0xb003", from, p, 10);
            compare(s.target, { type: "plus" });
            drv("window", "0xb003", 0, 0, "drop");
            compare(root.opLog, ["newdesk 0xb003"]);
            compare(root.deskIds(), [1, 2, 3, 4, 5, 6, 7]);
        }
        function test_d_insert_into_gap() {
            open("six");
            var from = cardCentre("0xb005"), a = bar.tileRect(1), b = bar.tileRect(2);
            var gap = Qt.point((a.x + a.width + b.x) / 2, a.y + a.height / 2);
            drv("window", "0xb005", from.x, from.y, "begin");
            var s = slide("window", "0xb005", from, gap, 10);
            compare(s.gapIndex, 0);
            verify(!s.gapArmed, "the gap waits 150 ms");
            tryVerify(function () { return ctl.gapArmed; }, 400);
            s = drv("window", "0xb005", gap.x, gap.y, "move");
            compare(s.target, { type: "gap", left: 1, right: 2 });
            compare(bar.partAt, 0, "the tiles part");
            drv("window", "0xb005", 0, 0, "drop");
            compare(root.opLog, ["insert 1|2 0xb005"]);
            compare(root.deskIds(), [1, 2, 3, 4, 5, 6, 7]);
            var w; for (var i = 0; i < root.raw.length; i++) if (root.raw[i].id === "0xb005") w = root.raw[i];
            compare(w.desk, 2, "the window has the new desk 2; the others moved up by one");
        }
        function test_e_cancel_paths_send_nothing() {
            open("six");
            // Esc (a real key, into the overview's focus) during a window drag
            var from = cardCentre("0xb003"), c4 = centre(4);
            drv("window", "0xb003", from.x, from.y, "begin");
            slide("window", "0xb003", from, c4, 6);
            keyClick(Qt.Key_Escape);
            compare(ctl.kind, "", "Esc cancelled the drag");
            verify(scene.isOpen && !scene.closing, "Esc during a drag does not close the overview");
            // dropped on nothing: the backdrop of its own desk
            drv("window", "0xb003", from.x, from.y, "begin");
            var s = slide("window", "0xb003", from, Qt.point(1200, 1450), 6);
            compare(s.target, null);
            drv("window", "0xb003", 0, 0, "drop");
            // dropped on its own desk's tile
            drv("window", "0xb003", from.x, from.y, "begin");
            s = slide("window", "0xb003", from, centre(3), 6);
            compare(s.target, null);
            drv("window", "0xb003", 0, 0, "drop");
            // a desk dropped on its own slot
            var c2 = centre(2);
            drv("desk", 2, c2.x, c2.y, "begin");
            slide("desk", 2, c2, Qt.point(c2.x + 40, c2.y + 10), 4);
            drv("desk", 2, 0, 0, "drop");
            // a desk released 140 u below the strip
            drv("desk", 2, c2.x, c2.y, "begin");
            slide("desk", 2, c2, Qt.point(centre(5).x + 30, c2.y), 6);
            s = slide("desk", 2, Qt.point(centre(5).x + 30, c2.y), Qt.point(centre(5).x + 30, c2.y + bar.tileH / 2 + 150), 6);
            verify(s.cancelZone);
            compare(s.previewOrder, [1, 2, 3, 4, 5, 6], "past 140 u the tiles go home");
            drv("desk", 2, 0, 0, "drop");
            // Esc during a desk drag
            drv("desk", 2, c2.x, c2.y, "begin");
            slide("desk", 2, c2, centre(5), 6);
            keyClick(Qt.Key_Escape);
            compare(ctl.kind, "");
            // the scaffold path: Scene clearing dragId cancels too
            drv("window", "0xb003", from.x, from.y, "begin");
            scene.dragId = "";
            compare(ctl.kind, "");
            compare(root.opLog, [], "no cancel path sent anything");
            compare(bar.previewOrder, []);
            compare(root.deskIds(), [1, 2, 3, 4, 5, 6]);
        }
        function test_f_hover_hold_then_grid() {
            open("six");
            var from = cardCentre("0xb004"), c5 = centre(5);
            drv("window", "0xb004", from.x, from.y, "begin");
            var s = slide("window", "0xb004", from, c5, 8);
            compare(s.holdId, 5);
            tryVerify(function () { return scene.viewedDesk === 5; }, 1200, "750 ms hover-hold pages to desk 5");
            compare(ctl.holdId, -1);
            s = slide("window", "0xb004", c5, Qt.point(1200, 900), 6);
            compare(s.target, { type: "grid", id: 5 });
            drv("window", "0xb004", 0, 0, "drop");
            compare(root.opLog, ["move 0xb004→5"]);
        }
        function test_g_keyboard_drag() {
            open("six");
            var s = drv("window", "0xb003", 0, 0, "lift");
            verify(s.ok); verify(s.keyboard);
            compare(s.target, null, "aims at its own desk first");
            keyClick(Qt.Key_Right);
            compare(ctl.target, { type: "desk", id: 4 });
            keyClick(Qt.Key_Right); keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
            compare(ctl.target, { type: "plus" });
            keyClick(Qt.Key_Left);
            compare(ctl.target, { type: "desk", id: 6 });
            keyClick(Qt.Key_Return);
            compare(root.opLog, ["move 0xb003→6"]);
            // Space-less lift then Esc
            drv("window", "0xb002", 0, 0, "lift");
            keyClick(Qt.Key_Right);
            keyClick(Qt.Key_Escape);
            compare(root.opLog, ["move 0xb003→6"]);
        }
        function test_h_thirteen_auto_scroll() {
            open("thirteen");
            verify(bar.geo.scrolls);
            var r7 = bar.tileRect(7);
            verify(r7.x >= bar.geo.viewX - 1 && r7.x + r7.width <= bar.geo.viewX + bar.geo.viewW + 1, "active desk scrolled into view on open");
            var sx0 = bar.scrollX, c2 = centre(2);
            // carry desk 7 to the right end and hold: the strip scrolls
            var c7 = centre(7);
            drv("desk", 7, c7.x, c7.y, "begin");
            var edge = Qt.point(bar.geo.viewX + bar.geo.viewW - 10, c7.y);
            slide("desk", 7, c7, edge, 10);
            tryVerify(function () { return bar.scrollX >= bar.geo.maxScroll - 0.5; }, 3000, "auto-scroll reaches the end");
            var s = drv("desk", 7, edge.x, edge.y, "move");
            compare(s.previewOrder[12], 7, "carried to the last place");
            compare(s.labels[12], 13);
            drv("desk", 7, 0, 0, "drop");
            compare(root.opLog, ["reorder [1,2,3,4,5,6,8,9,10,11,12,13,7]"]);
        }
        function test_i_deferred_back_end_and_failure() {
            // Like the real back end: the op answers later. The preview holds until the model changes.
            open("six");
            root.deferOps = true;
            var c2 = centre(2), c5 = centre(5), c6 = centre(6);
            drv("desk", 2, c2.x, c2.y, "begin");
            slide("desk", 2, c2, Qt.point((c5.x + c6.x) / 2, c2.y), 10);
            drv("desk", 2, 0, 0, "drop");
            verify(ctl.commit !== null);
            compare(bar.order, [1, 3, 4, 5, 2, 6], "preview held while waiting");
            wait(100);
            root.flushOps();
            compare(ctl.commit, null);
            compare(bar.order, [1, 2, 3, 4, 5, 6]);
            // no answer at all: after 600 ms the tiles go home
            drv("desk", 3, centre(3).x, c2.y, "begin");
            slide("desk", 3, centre(3), centre(1), 6);
            drv("desk", 3, 0, 0, "drop");
            verify(ctl.commit !== null);
            tryVerify(function () { return ctl.commit === null; }, 1000);
            compare(bar.order, [1, 2, 3, 4, 5, 6]);
            root.deferOps = false;
        }
        function test_j_one_desk() {
            open("one");
            var s = drv("desk", 1, centre(1).x, centre(1).y, "begin");
            verify(!s.ok, "desk drag is off with one desk");
            s = drv("window", "0xa000", 0, 0, "pick");
            verify(s.ok, "a window can still be picked from the miniature");
            s = slide("window", "0xa000", Qt.point(0, 0), centre("plus"), 4);
            compare(s.target, { type: "plus" });
            drv("window", "0xa000", 0, 0, "drop");
            compare(root.opLog, ["newdesk 0xa000"]);
        }
        function test_k_one_capture_per_window() {
            open("six");
            wait(100);
            var s = drv("", "", 0, 0, "state");
            compare(s.captures, root.raw.length, "one capture per window");
            var cards = 0, minis = 0;
            for (var k in bar.captures) { if (k.indexOf("|card") > 0) cards++; else minis++; }
            compare(cards, 5, "desk 3's five windows: their cards");
            compare(minis, 6, "the other desks: their miniatures");
        }
        function test_l_pick_from_miniature() {
            open("six");
            var c4 = centre(4), c5 = centre(5);
            var s = drv("window", "0xb007", c4.x - 20, c4.y, "pick");
            verify(s.ok);
            s = slide("window", "0xb007", Qt.point(c4.x - 20, c4.y), c5, 8);
            compare(s.target, { type: "desk", id: 5 });
            drv("window", "0xb007", 0, 0, "drop");
            compare(root.opLog, ["move 0xb007→5"]);
        }
    }
}
