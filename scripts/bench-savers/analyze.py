#!/usr/bin/env python3
"""Compare each setup with base, per task, from bench.sh results.

  analyze.py results/<date>-<model>.jsonl [...]

Tokens are Ullage's own count, stored in each row when the run finished:
every call in the session summed, subagents included, one counter at a
time. `sent` is input + cache_write + cache_read over the session (what was
paid for), `peak` the main thread's largest context.
Cost is Claude Code's own list-price figure, which a subscription spends as
quota rather than money.
"""
import json, statistics as st, sys

rows = {}
for path in sys.argv[1:]:
    for line in open(path):
        r = json.loads(line)
        if not r.get("session") or r.get("is_error"):
            continue
        t = r.get("tokens") or {}
        sent, out, peak = t.get("sent"), t.get("output"), t.get("peak")
        if sent:
            key = (r["model"], r["setup"], r["task"])
            rows.setdefault(key, []).append(dict(sent=sent, out=out, peak=peak, cost=r["cost"] or 0,
                                                 score=r["score"], turns=r["turns"] or 0, secs=r["secs"]))

mean = lambda xs: st.mean(xs) if xs else float("nan")
metrics = ["sent", "peak", "out", "cost"]
for model in sorted({k[0] for k in rows}):
    tasks = sorted({k[2] for k in rows if k[0] == model})
    setups = sorted({k[1] for k in rows if k[0] == model}, key=lambda s: (s != "base", s))
    print(f"\n{model}: mean change vs base, averaged over tasks (negative = less)")
    print(f"  {'setup':30} {'runs':>4} " + " ".join(f"{m:>7}" for m in metrics) + f" {'score':>6} {'secs':>5}")
    for setup in setups:
        deltas = {m: [] for m in metrics}
        runs_all = []
        for task in tasks:
            runs, base = rows.get((model, setup, task), []), rows.get((model, "base", task), [])
            if not runs or not base:
                continue
            runs_all += runs
            for m in metrics:
                b = mean([x[m] for x in base])
                if b:
                    deltas[m].append(mean([x[m] for x in runs]) / b - 1)
        if not runs_all:
            print(f"  {setup:30}  (no base runs to compare with)")
            continue
        print(f"  {setup:30} {len(runs_all):>4} " + " ".join(f"{mean(deltas[m]) * 100:>+6.0f}%" for m in metrics)
              + f" {mean([x['score'] for x in runs_all]):>6.2f} {mean([x['secs'] for x in runs_all]):>5.0f}")
    print(f"\n  per task: mean tokens sent [min-max], cost, score")
    for task in tasks:
        print(f"  {task}")
        for setup in setups:
            runs = rows.get((model, setup, task), [])
            if runs:
                s = [x["sent"] for x in runs]
                print(f"    {setup:28} {mean(s):>11,.0f} [{min(s):,}-{max(s):,}]  ${mean([x['cost'] for x in runs]):.3f}"
                      f"  {mean([x['score'] for x in runs]):.2f}")
