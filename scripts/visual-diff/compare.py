#!/usr/bin/env -S python3 -I
"""Maps accessibility elements between a reference app and Open Arc and reports frame deltas.

Usage:
  python3 -I compare.py --ref ref.json --ours ours.json --mapping mapping.json \
      --out-dir DIR [--ref-side arc|openarc] [--ours-side openarc] [--threshold 1.0]

Inputs are dumps from axdump.swift (already redacted for the reference app). Writes
DIR/report.json and DIR/report.md and prints the Markdown report. Exit code 0 always when the
comparison ran (use the JSON 'flagged' count to gate); 2 on bad input.

Stdlib only; run with `python3 -I` so nothing is imported from the current directory.
"""

import argparse
import json
import os
import re
import sys

FIELDS = ("x", "y", "w", "h", "cx", "cy")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def frame_values(frame):
    """Adds centers to an {x, y, w, h} frame."""
    out = dict(frame)
    out["cx"] = round(frame["x"] + frame["w"] / 2, 2)
    out["cy"] = round(frame["y"] + frame["h"] / 2, 2)
    return out


class Tree:
    """Index over one axdump element list."""

    def __init__(self, dump):
        self.elements = dump["elements"]
        self.by_index = {e["index"]: e for e in self.elements}
        self.children = {}
        for e in self.elements:
            self.children.setdefault(e["parent"], []).append(e["index"])

    def descendants(self, index):
        stack = list(self.children.get(index, []))
        while stack:
            i = stack.pop()
            yield self.by_index[i]
            stack.extend(self.children.get(i, []))

    def is_descendant(self, index, ancestor):
        e = self.by_index.get(index)
        while e is not None and e["parent"] >= 0:
            if e["parent"] == ancestor:
                return True
            e = self.by_index.get(e["parent"])
        return False


def matches(tree, e, m, resolved):
    """True if element e satisfies matcher m. `resolved` maps entry names to matched elements
    on the same side (for 'within', 'above', 'below', 'inside', 'relativeTo')."""
    if m.get("visible", True) and not e.get("visible", False):
        return False
    if "frame" not in e:
        return False
    if not matches_local(e, m):
        return False
    if "depth" in m:
        lo, hi = m["depth"]
        if not lo <= e["depth"] <= hi:
            return False
    if "frame" in m:
        fv = frame_values(e["frame"])
        for key, (lo, hi) in m["frame"].items():
            if not lo <= fv[key] <= hi:
                return False
    if "within" in m:
        anchor = resolved.get(m["within"])
        if anchor is None or not tree.is_descendant(e["index"], anchor["index"]):
            return False
    for key, test in (("above", lambda fv, a: fv["cy"] < a["y"]),
                      ("below", lambda fv, a: fv["cy"] > a["y"] + a["h"]),
                      ("inside", lambda fv, a: a["x"] - 0.5 <= fv["x"] and fv["x"] + fv["w"] <= a["x"] + a["w"] + 0.5
                       and a["y"] - 0.5 <= fv["y"] and fv["y"] + fv["h"] <= a["y"] + a["h"] + 0.5)):
        if key in m:
            anchor = resolved.get(m[key])
            if anchor is None or not test(frame_values(e["frame"]), anchor["frame"]):
                return False
    if "relativeTo" in m:
        rel = m["relativeTo"]
        anchor = resolved.get(rel["entry"])
        if anchor is None:
            return False
        fv, av = frame_values(e["frame"]), frame_values(anchor["frame"])
        for key in ("cx", "cy"):
            if key in rel and not rel[key][0] <= fv[key] - av[key] <= rel[key][1]:
                return False
    if "contains" in m:
        pattern = m["contains"]
        if not any(re.search(pattern, d.get("identifier", "")) for d in tree.descendants(e["index"])):
            return False
    if "has" in m and not any(matches_local(d, m["has"]) for d in tree.descendants(e["index"])):
        return False
    if "lacks" in m and any(matches_local(d, m["lacks"]) for d in tree.descendants(e["index"])):
        return False
    return True


def matches_local(e, m):
    """The attribute-only part of a matcher (role, subrole, identifier and text patterns)."""
    for key in ("role", "subrole"):
        if key in m and not re.fullmatch(m[key], e.get(key, "")):
            return False
    for key in ("identifier", "title", "description", "value"):
        if key in m and not re.search(m[key], e.get(key, "")):
            return False
    return True


def find(tree, m, resolved):
    found = [e for e in tree.elements if matches(tree, e, m, resolved)]
    pick = m.get("pick", "first")
    if pick == "all":
        return sorted(found, key=lambda e: (e["frame"]["y"], e["frame"]["x"]))
    if not found:
        return []
    if pick == "smallest":
        return [min(found, key=lambda e: e["frame"]["w"] * e["frame"]["h"])]
    if pick == "largest":
        return [max(found, key=lambda e: e["frame"]["w"] * e["frame"]["h"])]
    return [found[0]]


def describe(e):
    """Structure-only description of a matched element (no text content)."""
    if e is None:
        return None
    out = {"role": e.get("role", ""), "frame": e["frame"]}
    for key in ("subrole", "identifier"):
        if key in e:
            out[key] = e[key]
    return out


def compare(ref_dump, ours_dump, mapping, ref_side, ours_side, threshold):
    trees = {"ref": Tree(ref_dump), "ours": Tree(ours_dump)}
    sides = {"ref": ref_side, "ours": ours_side}
    resolved = {"ref": {}, "ours": {}}
    rows = []
    for entry in mapping["entries"]:
        name = entry["name"]
        found = {}
        for who in ("ref", "ours"):
            matcher = entry.get(sides[who])
            # A null matcher means that side does not expose the element in its AX tree.
            found[who] = find(trees[who], matcher, resolved[who]) if matcher else []
            if found[who] and entry.get("kind") != "sequence":
                resolved[who][name] = found[who][0]
        if entry.get("anchorOnly") or (not entry.get(sides["ref"]) and not entry.get(sides["ours"])):
            continue
        fields = entry.get("compare", ["x", "y", "w", "h"])
        if entry.get("kind") == "sequence":
            # Pair the i-th elements on both sides up to the shorter list; a count mismatch is
            # reported once (the windows may hold different numbers of tabs or Spaces).
            count = min(len(found["ref"]), len(found["ours"]))
            if len(found["ref"]) != len(found["ours"]) and (found["ref"] or found["ours"]):
                rows.append({"name": f"{name}[count]", "group": entry.get("group", ""), "fields": [],
                             "status": "count-mismatch", "severity": None, "ref": None, "ours": None,
                             "counts": {"ref": len(found["ref"]), "ours": len(found["ours"])}})
            pairs = [(f"{name}[{i}]",
                      found["ref"][i] if i < len(found["ref"]) else None,
                      found["ours"][i] if i < len(found["ours"]) else None) for i in range(count)]
            if count == 0 and not (found["ref"] or found["ours"]):
                pairs = [(f"{name}[*]", None, None)]
        else:
            pairs = [(name, found["ref"][0] if found["ref"] else None,
                      found["ours"][0] if found["ours"] else None)]
        for label, r, o in pairs:
            row = {"name": label, "group": entry.get("group", ""), "fields": fields,
                   "ref": describe(r), "ours": describe(o)}
            if entry.get("note"):
                row["note"] = entry["note"]
            if r is None or o is None:
                if r is None and o is None and entry.get("optional"):
                    continue
                row["status"] = "missing-ref" if r is None and o is not None else (
                    "missing-ours" if o is None and r is not None else "missing-both")
                row["severity"] = None
            elif entry.get("origin") and (resolved["ref"].get(entry["origin"]) is None
                                          or resolved["ours"].get(entry["origin"]) is None):
                row["status"] = "missing-origin"
                row["severity"] = None
            else:
                rf, of = r["frame"], o["frame"]
                if entry.get("origin"):
                    # Compare positions relative to the origin entry's top-left on each side.
                    ra, oa = resolved["ref"][entry["origin"]]["frame"], resolved["ours"][entry["origin"]]["frame"]
                    rf = dict(rf, x=rf["x"] - ra["x"], y=rf["y"] - ra["y"])
                    of = dict(of, x=of["x"] - oa["x"], y=of["y"] - oa["y"])
                    row["origin"] = entry["origin"]
                rv, ov = frame_values(rf), frame_values(of)
                deltas = {k: round(ov[k] - rv[k], 2) for k in FIELDS}
                row["delta"] = deltas
                row["severity"] = max(abs(deltas[k]) for k in fields)
                row["status"] = "over" if row["severity"] > threshold else "ok"
            rows.append(row)
    order = {"over": 0, "missing-ours": 1, "missing-ref": 2, "missing-both": 3, "missing-origin": 4, "count-mismatch": 5, "ok": 6}
    rows.sort(key=lambda r: (order[r["status"]], -(r["severity"] or 0), r["name"]))
    return rows


def fmt(v):
    if v is None:
        return ""
    s = f"{v:+.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("+0", "-0") else s


def markdown(rows, meta, threshold):
    lines = [
        "# Visual diff",
        "",
        f"Reference: `{meta['ref_bundle']}` window {meta['ref_window']['w']}×{meta['ref_window']['h']} pt; "
        f"ours: `{meta['ours_bundle']}` window {meta['ours_window']['w']}×{meta['ours_window']['h']} pt. "
        f"Δ = ours − reference, points, frames relative to each window's top-left. "
        f"Flag: |Δ| > {threshold:g} pt on the compared fields.",
        "",
    ]
    if meta["ref_window"]["w"] != meta["ours_window"]["w"] or meta["ref_window"]["h"] != meta["ours_window"]["h"]:
        lines += ["**Warning: window sizes differ; right/bottom-anchored elements will show size-driven deltas.**", ""]
    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    lines += ["Summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())), ""]
    lines += ["| | element | Δx | Δy | Δw | Δh | Δcx | Δcy | ref x,y w×h | ours x,y w×h |",
              "|---|---|---|---|---|---|---|---|---|---|"]

    def box(d):
        if d is None:
            return "—"
        f = d["frame"]
        return f"{f['x']:g},{f['y']:g} {f['w']:g}×{f['h']:g}"

    for r in rows:
        flag = {"over": "⚠", "ok": "✓"}.get(r["status"], "∅")
        d = r.get("delta", {})
        cells = []
        for k in FIELDS:
            v = fmt(d.get(k)) if d else ""
            if d and k not in r["fields"]:
                v = f"({v})"
            cells.append(v)
        name = r["name"] + ("" if r["status"] in ("ok", "over") else f" ({r['status']})")
        if r.get("counts"):
            name += f": ref {r['counts']['ref']}, ours {r['counts']['ours']}"
        if r.get("origin"):
            name += f" (rel. to {r['origin']})"
        lines.append(f"| {flag} | {name} | " + " | ".join(cells) + f" | {box(r['ref'])} | {box(r['ours'])} |")
    notes = sorted({(r["name"].split("[")[0], r["note"]) for r in rows if r.get("note")})
    if notes:
        lines += ["", "Notes:"] + [f"- `{n}`: {t}" for n, t in notes]
    lines += ["", "Values in parentheses are not compared for that element (see mapping.json `compare`)."]
    return "\n".join(lines) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ref", required=True)
    p.add_argument("--ours", required=True)
    p.add_argument("--mapping", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--ref-side", default="arc", choices=("arc", "openarc"))
    p.add_argument("--ours-side", default="openarc", choices=("arc", "openarc"))
    p.add_argument("--threshold", type=float, default=1.0)
    a = p.parse_args()
    try:
        ref, ours, mapping = load(a.ref), load(a.ours), load(a.mapping)
    except (OSError, ValueError) as err:
        print(f"compare: {err}", file=sys.stderr)
        return 2
    rows = compare(ref, ours, mapping, a.ref_side, a.ours_side, a.threshold)
    meta = {"ref_bundle": ref["bundle"], "ours_bundle": ours["bundle"],
            "ref_window": ref["window"], "ours_window": ours["window"],
            "ref_redacted": ref.get("redacted", False), "threshold": a.threshold}
    flagged = sum(1 for r in rows if r["status"] == "over")
    missing = sum(1 for r in rows if r["status"].startswith("missing"))
    report = {"meta": meta, "flagged": flagged, "missing": missing, "rows": rows}
    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    md = markdown(rows, meta, a.threshold)
    with open(os.path.join(a.out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write(md)
    sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
