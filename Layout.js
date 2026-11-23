.pragma library
// Pure geometry for the overview: no Qt types, no state. Every function
// takes plain numbers and returns plain objects, so it is easy to reason
// about and identical in both back ends.

// Justified rows: windows keep their proportions, every row is filled
// edge to edge, and the number of rows is whichever makes the windows
// biggest. Two windows come out huge; twelve still read.
//   items:   [{ id, w, h }] in the order they should appear
//   box:     { x, y, w, h } the area to fill
//   gap:     space between windows (both directions)
//   labelH:  height reserved under every window for its icon and title
//   maxScale: a window is never drawn larger than this fraction of its real size
// returns { id: { x, y, w, h } } (the picture only; the label sits under it)
function justify(items, box, gap, labelH, maxScale) {
    var n = items.length, best = null;
    if (n === 0 || box.w <= 0 || box.h <= 0) return {};
    var asp = items.map(function (it) { return Math.max(0.35, Math.min(3.5, it.w / Math.max(1, it.h))); });
    for (var rows = 1; rows <= n; rows++) {
        var groups = partition(asp, rows);
        var res = place(items, asp, groups, box, gap, labelH, maxScale);
        if (best === null || res.area > best.area * 1.0001) best = res;
    }
    return best.rects;
}

// Splits the aspect list (in order) into `rows` runs whose sums are as even
// as possible: least squares on the deviation from the mean, by dynamic
// programming (n is tiny, so the O(n^2 rows) cost is nothing).
function partition(asp, rows) {
    var n = asp.length, pre = [0];
    for (var i = 0; i < n; i++) pre.push(pre[i] + asp[i]);
    var mean = pre[n] / rows, INF = 1e18, cost = [], cut = [];
    for (var r = 0; r <= rows; r++) { cost.push([]); cut.push([]); for (var j = 0; j <= n; j++) { cost[r].push(INF); cut[r].push(0); } }
    cost[0][0] = 0;
    for (r = 1; r <= rows; r++)
        for (j = r; j <= n; j++)
            for (var k = r - 1; k < j; k++) {
                var s = pre[j] - pre[k], c = cost[r - 1][k] + (s - mean) * (s - mean);
                if (c < cost[r][j]) { cost[r][j] = c; cut[r][j] = k; }
            }
    var groups = [], end = n;
    for (r = rows; r >= 1; r--) { var start = cut[r][end]; groups.unshift([start, end]); end = start; }
    return groups;
}

function place(items, asp, groups, box, gap, labelH, maxScale) {
    var rows = groups.length, heights = [], sumH = 0;
    for (var g = 0; g < rows; g++) {
        var a = 0, k = groups[g][1] - groups[g][0];
        for (var i = groups[g][0]; i < groups[g][1]; i++) a += asp[i];
        var h = (box.w - gap * (k - 1)) / a;                         // fills the width exactly
        var cap = 1e9;
        for (i = groups[g][0]; i < groups[g][1]; i++) cap = Math.min(cap, items[i].h * maxScale);
        heights.push({ h: h, cap: cap, a: a, k: k });
        sumH += h;
    }
    var free = box.h - rows * labelH - gap * (rows - 1);
    var f = Math.min(1, free / sumH), total = 0, area = 0;
    for (g = 0; g < rows; g++) {
        heights[g].h = Math.max(1, Math.min(heights[g].h * f, heights[g].cap));
        total += heights[g].h + labelH;
        area += heights[g].h * heights[g].h * heights[g].a;
    }
    total += gap * (rows - 1);
    var rects = {}, y = box.y + Math.max(0, (box.h - total) / 2);
    for (g = 0; g < rows; g++) {
        var rh = heights[g].h, rowW = rh * heights[g].a + gap * (heights[g].k - 1);
        var x = box.x + (box.w - rowW) / 2;
        for (i = groups[g][0]; i < groups[g][1]; i++) {
            var w = rh * asp[i];
            rects[items[i].id] = { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(rh) };
            x += w + gap;
        }
        y += rh + labelH + gap;
    }
    return { rects: rects, area: area };
}

// Reading order for windows on one desk: waiting agents first (they want
// him), then top-to-bottom, left-to-right by where the window really is, so
// the grid keeps the desk's own arrangement and thumbnails barely cross.
function order(wins, screenH) {
    var band = Math.max(1, screenH / 4);
    return wins.slice().sort(function (a, b) {
        var wa = a.agent === "waiting" ? 0 : 1, wb = b.agent === "waiting" ? 0 : 1;
        if (wa !== wb) return wa - wb;
        var ra = Math.floor((a.y + a.h / 2) / band), rb = Math.floor((b.y + b.h / 2) / band);
        if (ra !== rb) return ra - rb;
        return (a.x + a.w / 2) - (b.x + b.w / 2);
    });
}

// The desk strip: tiles share the screen's proportions and are as large as
// fit, up to a ceiling, centred as a row. They never shrink below minW
// (default: 130/272 of maxW, so 12 desks still fit at 134 u and the row
// scrolls from 13 desks, as SPEC 2.2 asks; its 150 u floor would scroll from
// 11 already); when they would, the row starts at the margin and scrolls: x is then given in the
// row's own coordinates (subtract scrollX to draw it).
//   count   items in the row, the "+" tile included
// returns [{ x, w, h }] with these extras on the array:
//   gap, pitch (w + gap), viewX, viewW (the visible band), contentW,
//   scrolls (bool), maxScroll, scrollX (clamped)
function deskStrip(count, width, margin, gap, maxW, aspect, minW, scrollX) {
    if (minW === undefined || minW === null) minW = maxW * 130 / 272;
    var n = Math.max(1, count), viewW = width - 2 * margin;
    var w = Math.min(maxW, (viewW - gap * (n - 1)) / n);
    var scrolls = w < minW;
    if (scrolls) w = minW;
    var total = w * count + gap * (count - 1);
    var maxScroll = scrolls ? Math.max(0, total - viewW) : 0;
    var sx = Math.max(0, Math.min(maxScroll, scrollX || 0));
    var x0 = scrolls ? margin - sx : (width - total) / 2, out = [];
    for (var i = 0; i < count; i++) out.push({ x: Math.round(x0 + i * (w + gap)), w: Math.round(w), h: Math.round(w / aspect) });
    out.gap = gap; out.pitch = w + gap; out.viewX = margin; out.viewW = viewW; out.contentW = total;
    out.scrolls = scrolls; out.maxScroll = maxScroll; out.scrollX = sx;
    return out;
}

// The scroll that shows slot `index` centred in the visible band (clamped).
function scrollToShow(strip, index) {
    if (!strip.scrolls || index < 0 || index >= strip.length) return strip.scrollX || 0;
    var cx = strip[index].x + (strip.scrollX || 0) + strip[index].w / 2 - strip.viewX;
    return Math.max(0, Math.min(strip.maxScroll, cx - strip.viewW / 2));
}

// Desk drag, insert-and-shift: where the dragged desk would land if it were
// dropped with its centre at x. A neighbour gives way once the dragged
// centre has passed the neighbour's own centre, so nothing flickers at a
// boundary and the order only changes when he has clearly moved past.
//   ids     desk ids in display order (no "+")
//   strip   deskStrip() for the same row (slot j holds ids[j])
//   x       the dragged tile's centre, in the strip's coordinates
// returns the ids in their preview order (the dragged one included)
function previewOrder(ids, dragId, x, strip) {
    var from = ids.indexOf(dragId);
    if (from < 0) return ids.slice();
    var k = 0, out = [];
    for (var j = 0; j < ids.length; j++) {
        if (j === from) continue;
        out.push(ids[j]);
        if (strip[j] && strip[j].x + strip[j].w / 2 < x) k++;
    }
    out.splice(k, 0, dragId);
    return out;
}

// Numbers are positions: the label shown at display slot i is the i-th of
// the sorted set of ids, so a sparse set (1 2 4 7) keeps its numbers.
function labelsFor(order) {
    var s = order.slice().sort(function (a, b) { return a - b; });
    var out = {};
    for (var i = 0; i < order.length; i++) out[order[i]] = s[i];
    return out;
}

// Window drag over the strip: is x inside a gap between two desks? The gap
// is widened by 14/30 of its width into each neighbour (14 u at a 30 u gap).
//   count   real desks in the row (the gap before "+" is not an insert point)
// returns i (the gap between slot i and i + 1) or -1
function insertionGap(strip, x, count) {
    var n = count === undefined ? strip.length - 1 : count;
    var slack = (strip.gap || 0) * 14 / 30;
    for (var i = 0; i + 1 < n && i + 1 < strip.length; i++) {
        var a = strip[i].x + strip[i].w, b = strip[i + 1].x;
        if (x >= a - slack && x <= b + slack) return i;
    }
    return -1;
}

// What a point over the strip is on. Tiles own half the gap on each side so
// there is no dead line between them; a gap zone (insertionGap) is reported
// first and keeps the tile it overlaps, so the caller can light that tile
// while the gap waits for its dwell.
//   top, bottom   the band (y) that counts as "on the strip"
// returns null | { type: "desk", index } | { type: "plus" } | { type: "gap", index, tile }
function stripHit(strip, count, x, y, top, bottom) {
    if (y < top || y > bottom || !strip.length) return null;
    var half = (strip.gap || 0) / 2, tile = -1;
    for (var i = 0; i < strip.length; i++)
        if (x >= strip[i].x - half && x < strip[i].x + strip[i].w + half) { tile = i; break; }
    var g = insertionGap(strip, x, count);
    if (g >= 0) return { type: "gap", index: g, tile: tile >= 0 && tile < count ? tile : -1 };
    if (tile < 0) return null;
    return tile >= count ? { type: "plus" } : { type: "desk", index: tile };
}

// Auto-scroll while dragging near an end of an overflowing strip: signed
// speed in u/s, growing with depth into the band, full speed past the edge.
function autoScrollSpeed(x, viewX, viewW, band, vmax) {
    if (x < viewX + band) return -vmax * Math.min(1, (viewX + band - x) / band);
    if (x > viewX + viewW - band) return vmax * Math.min(1, (x - (viewX + viewW - band)) / band);
    return 0;
}

// A lifted desk follows the pointer's height only a little: 0.3 of it,
// softly limited to +-limit.
function rubberY(dy, k, limit) {
    return limit * Math.tanh(k * dy / Math.max(1e-6, limit));
}

// Where a moved window will appear inside a desk miniature (fractions of
// the miniature): exactly where it floats, or the right half for a tiled
// window (Hyprland's dwindle splits the desk; the preview promises the desk,
// not the cell).
function landingSpot(win, screenW, screenH) {
    if (win && win.floating)
        return { x: win.x / screenW, y: win.y / screenH, w: win.w / screenW, h: win.h / screenH };
    return { x: 0.515, y: 0.04, w: 0.445, h: 0.92 };
}

// Arrow keys: the nearest rectangle whose centre lies in that direction,
// weighting sideways drift double so "right" stays on the same row.
function neighbour(rects, fromId, dir) {
    var from = rects[fromId];
    if (!from) return fromId;
    var cx = from.x + from.w / 2, cy = from.y + from.h / 2, best = fromId, bestScore = 1e18;
    for (var id in rects) {
        if (id === fromId) continue;
        var r = rects[id], dx = r.x + r.w / 2 - cx, dy = r.y + r.h / 2 - cy, main, side;
        if (dir === "left") { main = -dx; side = dy; }
        else if (dir === "right") { main = dx; side = dy; }
        else if (dir === "up") { main = -dy; side = dx; }
        else { main = dy; side = dx; }
        if (main <= 1) continue;
        var score = main + 2 * Math.abs(side);
        if (score < bestScore) { bestScore = score; best = id; }
    }
    return best;
}

function lerp(a, b, t) { return a + (b - a) * t; }
