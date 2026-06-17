#!/usr/bin/env python3
"""
analyze_bench_results.py — Parse benchmark output, print comparison + write CSV.

Usage:  python3 analyze_bench_results.py [results_dir]
Output: bench_results/comparison.csv
"""

import sys, os, re, csv, math
from collections import defaultdict

DIR = sys.argv[1] if len(sys.argv) > 1 else "bench_results"

# ═══════════════════════════════════════════════════════════════════════
def parse_time(fpath):
    d = {}
    with open(fpath) as f:
        for line in f:
            if ':' in line:
                k, _, v = line.partition(':')
                try:    d[k.strip()] = float(v.strip())
                except: pass
    return d

def parse_perf(fpath):
    d = {}
    if not os.path.exists(fpath): return d
    with open(fpath) as f:
        for line in f:
            line = line.strip()
            if not line or '#' in line or 'not counted' in line or 'not supported' in line:
                continue
            parts = line.split()
            try:
                val = float(parts[0].replace(',', ''))
            except: continue
            d[' '.join(parts[1:])] = val
    return d

def parse_rss(fpath):
    if not os.path.exists(fpath): return 0, 0
    vals = []
    with open(fpath) as f:
        for row in csv.DictReader(f):
            try:    vals.append(float(row.get('VmRSS_kB', 0)))
            except: pass
    if not vals: return 0, 0
    return sum(vals) / len(vals), max(vals)

# ═══════════════════════════════════════════════════════════════════════
data = defaultdict(list)

for fname in sorted(os.listdir(DIR)):
    if not fname.endswith('_time.txt'): continue
    algo = fname.split('_')[0]  # ICC / ICC-G
    base = os.path.join(DIR, fname.replace('_time.txt', ''))

    t  = parse_time(fname)
    p  = parse_perf(base + '_perf.txt')
    r  = parse_rss(base + '_rss.csv')

    row = {
        'trial':     fname.replace('_time.txt', ''),
        'user_s':    t.get('User time (seconds)', 0),
        'sys_s':     t.get('System time (seconds)', 0),
        'cpu_pct':   t.get('Percent of CPU this job got', 0),
        'max_rss':   t.get('Maximum resident set size (kbytes)', 0),
        'mean_rss':  r[0],
        'peak_rss':  r[1],
        'vol_cs':    t.get('Voluntary context switches', 0),
        'invol_cs':  t.get('Involuntary context switches', 0),
        'insns':     p.get('instructions', p.get('instructions:u', 0)),
        'cycles':    p.get('cycles', p.get('cycles:u', 0)),
        'branches':  p.get('branches', p.get('branches:u', 0)),
        'br_miss':   p.get('branch-misses', p.get('branch-misses:u', 0)),
        'cache_ref': p.get('cache-references', p.get('cache-references:u', 0)),
        'cache_mis': p.get('cache-misses', p.get('cache-misses:u', 0)),
    }
    if row['insns'] > 0 and row['cycles'] > 0:
        row['IPC'] = row['insns'] / row['cycles']
    data[algo].append(row)

# ═══════════════════════════════════════════════════════════════════════
def stats(vals):
    n = len(vals)
    if n == 0: return 0, 0
    m = sum(vals) / n
    if n == 1: return m, 0
    return m, math.sqrt(sum((x-m)**2 for x in vals) / (n-1))

METRICS = [
    ('user_s',     'User time (s)',            's',   '{:.3f}'),
    ('sys_s',      'System time (s)',          's',   '{:.3f}'),
    ('cpu_pct',    'CPU %',                    '%',   '{:.1f}'),
    ('max_rss',    'Max RSS (kB)',             'kB',  '{:.0f}'),
    ('mean_rss',   'Mean RSS (kB)',            'kB',  '{:.1f}'),
    ('vol_cs',     'Voluntary ctx switches',   '#',   '{:.0f}'),
    ('invol_cs',   'Involuntary ctx switches', '#',   '{:.0f}'),
    ('insns',      'Instructions',             '#',   '{:.2e}'),
    ('cycles',     'Cycles',                   '#',   '{:.2e}'),
    ('IPC',        'IPC',                      '',    '{:.3f}'),
    ('branches',   'Branches',                 '#',   '{:.2e}'),
    ('br_miss',    'Branch misses',            '#',   '{:.2e}'),
    ('cache_ref',  'Cache references',         '#',   '{:.2e}'),
    ('cache_mis',  'Cache misses',             '#',   '{:.2e}'),
]

print()
print(f"{'Metric':<30s}  {'ICC':>18s}  {'ICC-G':>18s}  {'Δ%':>8s}")
print("-" * 80)

with open(os.path.join(DIR, 'comparison.csv'), 'w', newline='') as cf:
    cw = csv.writer(cf)
    cw.writerow(['metric', 'ICC_mean', 'ICC_std', 'ICC-G_mean', 'ICC-G_std', 'delta_pct'])
    for key, name, _, fmt in METRICS:
        a = [r[key] for r in data['ICC']     if r.get(key, 0) > 0]
        b = [r[key] for r in data['ICC-G']   if r.get(key, 0) > 0]
        if not a or not b: continue
        ma, sa = stats(a); mb, sb = stats(b)
        if ma == 0: continue
        dp = (mb - ma) / ma * 100
        flag = " ←" if abs(dp) > 5 else ""
        print(f"  {name:<28s}  {fmt.format(ma):>10s} ±{fmt.format(sa):<8s}  "
              f"{fmt.format(mb):>10s} ±{fmt.format(sb):<8s}  {dp:+7.1f}%{flag}")
        cw.writerow([name, ma, sa, mb, sb, dp])

print()
print(f"comparison.csv → {DIR}/comparison.csv")
