// Headless regression tests for MenuData.js's pure logic — no Quickshell, no
// running shell, no keystroke automation needed:
//
//   node tests/menudata.test.js
//
// Each block pins a bug that actually shipped (see CHANGELOG.md).
const M = require("../MenuData.js")
let fail = 0
function t(name, got, want) { const ok = got === want; if (!ok) fail++; console.log((ok ? "PASS" : "FAIL") + "  " + name + "  got=" + got + " want=" + want) }
// Layout A: pinned=2, recent=5, more=8, cols=4  (count 15)
//   pinned: 0 1            recent: 2 3 4 5 / 6        more: 7 8 9 10 / 11 12 13 14
const A = (i, d) => M.tileMove(i, 15, 2, 5, 4, d)
t("A down pinned col0 -> recent col0 (old flat step gave 4)", A(0, 1), 2)
t("A down pinned col1 -> recent col1", A(1, 1), 3)
t("A down recent row0 col3 -> short row clamps to its last tile", A(5, 1), 6)
t("A down recent last row col0 -> more col0", A(6, 1), 7)
t("A down more row0 col2 -> more row1 col2", A(9, 1), 13)
t("A down off the bottom col2 wraps to top, clamped to pinned's last", A(13, 1), 1)
t("A up more col0 -> recent last row col0", A(7, -1), 6)
t("A up more col3 -> recent last row clamps", A(10, -1), 6)
t("A up recent row0 col1 -> pinned col1", A(3, -1), 1)
t("A up recent row0 col3 -> pinned clamps to last", A(5, -1), 1)
t("A up off the top col0 wraps to bottom row col0", A(0, -1), 11)
// Layout B: what's on this machine right now — no pinned, 12 recent, 8 more, cols=4
const B = (i, d) => M.tileMove(i, 20, 0, 12, 4, d)
t("B down within recent", B(1, 1), 5)
t("B down recent last row col1 -> more col1", B(9, 1), 13)
t("B up more row0 col2 -> recent last row col2", B(14, -1), 10)
t("B down off bottom col3 wraps to top col3", B(19, 1), 3)
// Layout C: no sections at all (fresh install) — must behave like a plain grid
const C = (i, d) => M.tileMove(i, 8, 0, 0, 4, d)
t("C down", C(1, 1), 5)
t("C up wraps", C(1, -1), 5)
// Degenerate inputs must not throw or go out of range
t("empty model", M.tileMove(0, 0, 0, 0, 4, 1), 0)
t("single tile down", M.tileMove(0, 1, 1, 0, 4, 1), 0)
t("stale counts larger than model are clamped", M.tileMove(0, 3, 9, 9, 4, 1), 0)
t("index past end is clamped", M.tileMove(99, 15, 2, 5, 4, -1) >= 0 && M.tileMove(99, 15, 2, 5, 4, -1) < 15, true)
t("zero columns treated as 1", M.tileMove(0, 3, 0, 0, 0, 1), 1)
// Categories: display label vs. raw freedesktop identity, and one shared order.
t("label: AudioVideo", M.categoryLabel("AudioVideo"), "Audio & Video")
t("label: Network", M.categoryLabel("Network"), "Internet")
t("label: unknown passes through", M.categoryLabel("Graphics"), "Graphics")
t("order follows the label shown, Other last",
  ["Other", "Utility", "Network", "AudioVideo", "Game", "Development"].sort(M.compareCategories).join(","),
  "AudioVideo,Development,Game,Network,Utility,Other")
const dest = M.homeDestinations(["AudioVideo"])
t("sidebar id keeps the raw name (routes/IPC must not change)", dest[3].id, "category.AudioVideo")
t("sidebar label is the friendly one", dest[3].label, "Audio & Video")
console.log(fail ? fail + " FAILED" : "all passed"); process.exit(fail ? 1 : 0)
