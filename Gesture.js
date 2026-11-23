.pragma library
// Gesture.js — pure maths of the finger-following open/close (SPEC 2.1 + coordinator addendum §0).
// Owner: lane 2. No Qt types, no state: plain numbers in, plain numbers out (tests/qml/tst_gesture.qml).
//
// FROZEN INTERFACE (SPEC 4.1; units per the addendum: the stream carries millimetres of finger travel):
//   progress(acc, sign, p0, closing) -> p      acc = accumulated millimetres since the stroke began (positive = fingers up);
//                                              sign self-calibrated so the first non-zero acc of an UP stroke is positive;
//                                              TRAVEL_MM = 28 for a full 0 -> 1; p0 = t when the stroke began (it may
//                                              grab a running spring); the result is NOT rubber-banded (see rubber)
//   rubber(x) -> t                             beyond 1: 1 + 0.06 * (1 - e^(-3 * excess)), mirrored below 0
//   velocity(samples) -> mm/ms                 least-squares slope over the last 100 ms of [{ t: ms, acc }]; < 3 samples: last difference
//   decide(p, vMmPerMs, cancelled, closing) -> 0 | 1     v signed toward "open"; cancelled -> where the stroke came from;
//                                              |v| >= 0.06 mm/ms -> direction of v; else pProj = p + vp * 150 ms;
//                                              opening commits if pProj >= 0.35, closing commits if pProj <= 0.65
//   spring(x0, v0, T, tau, omega) -> { x, v }  critically damped: x(tau) = T + (x0 - T + (v0 + omega (x0 - T)) tau) e^(-omega tau);
//                                              v0 in progress/s, clamped to +-8 /s; tau in s; omega 15 /s (paging 18)
// Extras (lane 2, used by Scene/MockBackend/shell; not frozen):
//   calibrateSign(dir, acc), rubberSlope(x), springSettled(x, v, T), parseLine(line), releaseVelocity(vMmPerMs, sign, p)

var TRAVEL_MM = 28;          // full open = 28 mm of finger travel (GNOME: ~28 mm); allowed 20-36 (SPEC §0, §8)
var V_COMMIT = 0.06;         // mm/ms (60 mm/s) commits by speed alone
var PROJECT_MS = 150;        // a slow release is judged where it would be 150 ms later
var OPEN_AT = 0.35;          // his own cancel ratio
var CLOSE_AT = 0.65;
var RUBBER = 0.06;           // at most 6 % past either end
var RUBBER_K = 3;
var FIT_MS = 100;            // velocity window
var OMEGA = 15;              // /s, open and close
var OMEGA_PAGE = 18;         // /s, desk paging
var OMEGA_LEAVE = 24;        // /s, "leave" fade (visually done in ~170 ms, today's timing)
var V0_MAX = 8;              // progress/s
var EPS_X = 0.002;           // settled
var EPS_V = 0.01;

function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x); }

// "UP" (any case) means the first non-zero acc of the stroke should read positive.
function calibrateSign(dir, acc) {
    if (!acc) return 1;
    var up = String(dir || "").toUpperCase() !== "DOWN";
    return (acc > 0) === up ? 1 : -1;
}

function progress(acc, sign, p0, closing) {
    // Both directions are the same line through p0: up adds, down takes away.
    // "closing" is kept in the signature (frozen); it does not change the line.
    return (p0 || 0) + (sign || 1) * (acc || 0) / TRAVEL_MM;
}

function rubber(x) {
    if (x > 1) return 1 + RUBBER * (1 - Math.exp(-RUBBER_K * (x - 1)));
    if (x < 0) return -RUBBER * (1 - Math.exp(RUBBER_K * x));
    return x;
}
// d rubber / dx: how much of the finger's speed reaches t.
function rubberSlope(x) {
    if (x > 1) return RUBBER * RUBBER_K * Math.exp(-RUBBER_K * (x - 1));
    if (x < 0) return RUBBER * RUBBER_K * Math.exp(RUBBER_K * x);
    return 1;
}

function velocity(samples) {
    var n = samples ? samples.length : 0;
    if (n < 2) return 0;
    var last = samples[n - 1].t, i0 = n - 1;
    while (i0 > 0 && last - samples[i0 - 1].t <= FIT_MS) i0--;
    var m = n - i0;
    if (m < 3) {
        var a = samples[n - 2], b = samples[n - 1], dt = b.t - a.t;
        return dt > 0 ? (b.acc - a.acc) / dt : 0;
    }
    var st = 0, sa = 0;
    for (var i = i0; i < n; i++) { st += samples[i].t; sa += samples[i].acc; }
    var mt = st / m, ma = sa / m, num = 0, den = 0;
    for (i = i0; i < n; i++) { var d = samples[i].t - mt; num += d * (samples[i].acc - ma); den += d * d; }
    return den > 0 ? num / den : 0;
}

function decide(p, v, cancelled, closing) {
    if (cancelled) return closing ? 1 : 0;
    if (Math.abs(v) >= V_COMMIT) return v > 0 ? 1 : 0;
    var pProj = p + (v / TRAVEL_MM) * PROJECT_MS;
    if (closing) return pProj <= CLOSE_AT ? 0 : 1;
    return pProj >= OPEN_AT ? 1 : 0;
}

// The finger's speed handed to the spring at release, in progress/s, through the rubber band.
function releaseVelocity(v, sign, p) {
    return clamp((sign || 1) * v / TRAVEL_MM * 1000 * rubberSlope(p), -V0_MAX, V0_MAX);
}

function spring(x0, v0, T, tau, omega) {
    var w = omega || OMEGA, v = clamp(v0 || 0, -V0_MAX, V0_MAX);
    var c1 = x0 - T, c2 = v + w * c1, e = Math.exp(-w * tau);
    return { x: T + (c1 + c2 * tau) * e, v: (v - w * c2 * tau) * e };
}
function springSettled(x, v, T) { return Math.abs(x - T) < EPS_X && Math.abs(v) < EPS_V; }

// One line of the stream (with or without "custom>>" and "ovg,"), or null.
//   b,<fingers>,<UP|DOWN>,<acc>,<t_ms> · u,<acc>,<t_ms> · e,<acc>,<t_ms>,<0|1> · hello · ping,<n>
function parseLine(line) {
    var s = String(line || "").trim();
    if (s.indexOf("custom>>") === 0) s = s.slice(8);
    if (s.indexOf("ovg,") === 0) s = s.slice(4);
    var f = s.split(","), k = f[0];
    function num(x) { var n = Number(x); return x !== undefined && x !== "" && isFinite(n) ? n : NaN; }
    if (k === "hello" && f.length === 1) return { kind: "hello" };
    if (k === "ping" && f.length === 2 && /^[0-9]+$/.test(f[1])) return { kind: "ping", n: parseInt(f[1], 10) };
    if (k === "b" && f.length === 5) {
        var fingers = num(f[1]), acc = num(f[3]), tb = num(f[4]), dir = String(f[2]).toUpperCase();
        if (isNaN(fingers) || isNaN(acc) || isNaN(tb) || (dir !== "UP" && dir !== "DOWN")) return null;
        return { kind: "b", fingers: fingers, dir: dir, acc: acc, tMs: tb };
    }
    if (k === "u" && f.length === 3) {
        var au = num(f[1]), tu = num(f[2]);
        if (isNaN(au) || isNaN(tu)) return null;
        return { kind: "u", acc: au, tMs: tu };
    }
    if (k === "e" && f.length === 4) {
        var ae = num(f[1]), te = num(f[2]);
        if (isNaN(ae) || isNaN(te) || (f[3] !== "0" && f[3] !== "1")) return null;
        return { kind: "e", acc: ae, tMs: te, cancelled: f[3] === "1" };
    }
    return null;
}
