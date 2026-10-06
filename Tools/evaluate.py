#!/usr/bin/env python3
"""Compare a --dump from `--analyze` with make-test-video's truth JSON."""
import json, math, sys

dump = json.load(open(sys.argv[1]))
truth = json.load(open(sys.argv[2]))
frames, gt = dump["frames"], truth["frames"]
kinds = ["arrow", "pointingHand", "iBeam", "openHand", "closedHand", "crosshair", "resizeLeftRight", "resizeUpDown", "notAllowed"]
print(f"scale: detected {dump['scale']:.4g}, truth {truth['scale']}")
errs, miss, false_pos, wrong_shape = [], 0, 0, 0
segments = {}
for f, g in zip(frames, gt):
    seg = "hidden" if not g["visible"] else g["shape"]
    s = segments.setdefault(seg, {"n": 0, "found": 0, "err": []})
    s["n"] += 1
    if g["visible"]:
        if f["visible"]:
            s["found"] += 1
            e = math.hypot(f["x"] - g["x"], f["y"] - g["y"])
            errs.append(e); s["err"].append(e)
            if kinds[f["kind"]] != g["shape"]: wrong_shape += 1
        else:
            miss += 1
    elif f["visible"]:
        false_pos += 1; s["found"] += 1
errs.sort()
pct = lambda a, p: a[min(len(a) - 1, int(len(a) * p))] if a else float("nan")
print(f"visible frames: {sum(g['visible'] for g in gt)}, missed {miss}, false positives while hidden {false_pos}, wrong shape {wrong_shape}")
print(f"position error px: median {pct(errs, .5):.1f}, p95 {pct(errs, .95):.1f}, max {errs[-1] if errs else float('nan'):.1f}, >10px: {sum(e > 10 for e in errs)}")
for k, s in segments.items():
    print(f"  {k:13s} frames {s['n']:4d} detected {s['found']:4d} median err {pct(sorted(s['err']), .5):.1f}")
clicks = dump["inferred"]["clicks"]
print("clicks truth:", truth["clicks"])
print("clicks found:", [round(c["time"], 2) for c in clicks])
print("typing found:", len(dump["inferred"]["typing"]), "key presses between",
      round(min(dump["inferred"]["typing"], default=0), 2), "and", round(max(dump["inferred"]["typing"], default=0), 2))
