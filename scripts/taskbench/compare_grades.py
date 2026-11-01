#!/usr/bin/env python3
"""Before/after table for two graded live-bench runs (the same scenario ids).

    python3 scripts/taskbench/compare_grades.py build/taskbench/overnight-20261101-hotkey build/taskbench/overnight-20261101-pr86

Reads <before>/grades/all.json (or *.jsonl) and <after>/grades/*.jsonl; prints markdown.
"""
import collections, json, sys
from pathlib import Path


def load(d):
    d = Path(d) / "grades"
    allj = d / "all.json"
    if allj.exists():
        g = json.loads(allj.read_text())
        return {k: v for k, v in (g.items() if isinstance(g, dict) else ((x["id"], x) for x in g))}
    out = {}
    for f in sorted(d.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            if line.strip():
                r = json.loads(line); out[r["id"]] = r
    return out


before, after = load(sys.argv[1]), load(sys.argv[2])
ids = [i for i in after if i in before]
fam = lambda i: i.rsplit("-", 1)[0]
grades = ["pass", "partial", "fail", "invalid"]

def tally(src):
    c = collections.Counter(src[i]["grade"] for i in ids)
    testable = sum(c[g] for g in grades[:3])
    return c, testable

cb, tb = tally(before); ca, ta = tally(after)
print(f"Same {len(ids)} scenarios, first night vs PR #86 build:\n")
print("| | pass | partial | fail | invalid | pass rate (testable) |\n|---|---|---|---|---|---|")
for name, c, t in (("first night (ba3262d)", cb, tb), ("PR #86 (1a4c4a7)", ca, ta)):
    print(f"| {name} | {c['pass']} | {c['partial']} | {c['fail']} | {c['invalid']} | {100 * c['pass'] / max(t, 1):.0f}% of {t} |")

order = {g: n for n, g in enumerate(grades[:3])}
moves = collections.defaultdict(list)
for i in ids:
    b, a = before[i]["grade"], after[i]["grade"]
    if "invalid" in (a, b): moves["invalid either night"].append(i)
    elif order[a] < order[b]: moves["better"].append(i)
    elif order[a] > order[b]: moves["worse"].append(i)
    else: moves["same " + a].append(i)
print("\n| change | n | ids |\n|---|---|---|")
for k in ("better", "worse", "same pass", "same partial", "same fail", "invalid either night"):
    print(f"| {k} | {len(moves[k])} | {', '.join(sorted(moves[k]))} |")

print("\n| family | first night pass | PR #86 pass | of |\n|---|---|---|---|")
for f in sorted({fam(i) for i in ids}):
    fi = [i for i in ids if fam(i) == f]
    print(f"| {f} | {sum(before[i]['grade'] == 'pass' for i in fi)} | {sum(after[i]['grade'] == 'pass' for i in fi)} | {len(fi)} |")

print("\n| failure class (fail+partial) | first night | PR #86 |\n|---|---|---|")
fb = collections.Counter(before[i].get("failure_class") for i in ids if before[i]["grade"] in ("fail", "partial"))
fa = collections.Counter(after[i].get("failure_class") for i in ids if after[i]["grade"] in ("fail", "partial"))
for k in sorted(set(fb) | set(fa), key=lambda k: -(fb[k] + fa[k])):
    print(f"| {k} | {fb[k]} | {fa[k]} |")
