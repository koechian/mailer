#!/usr/bin/env python3
"""Summarises Mailer's timings: count, median, 90th and 99th percentile and
worst case for each operation, in milliseconds.

Mailer writes one line per measurement to
~/Library/Logs/Postline-performance.jsonl (see Core/Performance.swift).

usage:
  tools/performance_report.py                  every measurement in the file
  tools/performance_report.py --since 30       the last 30 minutes only
  tools/performance_report.py --op reader      operations whose name starts so
  tools/performance_report.py --by remote      split each operation by a detail
                                               (remote, kb, mailbox, ...)
  tools/performance_report.py --slowest 10     the 10 slowest measurements too
"""
import argparse
import json
import math
import os
import time

LOG = os.path.expanduser("~/Library/Logs/Postline-performance.jsonl")


def percentile(sorted_values, fraction):
    """Nearest-rank percentile of an ascending list."""
    rank = max(1, math.ceil(fraction * len(sorted_values)))
    return sorted_values[rank - 1]


def read_entries(since_minutes, op_prefix):
    cutoff = time.time() - since_minutes * 60 if since_minutes else 0
    entries = []
    with open(LOG) as log:
        for line in log:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("at", 0) < cutoff:
                continue
            if op_prefix and not entry["op"].startswith(op_prefix):
                continue
            entries.append(entry)
    return entries


def group(entries, detail_key):
    groups = {}
    for entry in entries:
        name = entry["op"]
        if detail_key:
            name += f" [{detail_key}={entry.get('detail', {}).get(detail_key, '-')}]"
        groups.setdefault(name, []).append(entry["ms"])
    return groups


def print_table(groups):
    header = f"{'operation':<44}{'count':>7}{'median':>10}{'p90':>10}{'p99':>10}{'worst':>10}"
    print(header)
    print("-" * len(header))
    for name in sorted(groups):
        values = sorted(groups[name])
        print(f"{name:<44}{len(values):>7}"
              f"{percentile(values, 0.5):>10.1f}{percentile(values, 0.9):>10.1f}"
              f"{percentile(values, 0.99):>10.1f}{values[-1]:>10.1f}")


def print_slowest(entries, count):
    print(f"\nSlowest {count}:")
    for entry in sorted(entries, key=lambda e: e["ms"], reverse=True)[:count]:
        stamp = time.strftime("%H:%M:%S", time.localtime(entry.get("at", 0)))
        print(f"  {entry['ms']:>9.1f} ms  {stamp}  {entry['op']}  {entry.get('detail', {})}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", type=float, help="only the last N minutes")
    parser.add_argument("--op", help="only operations whose name starts with this")
    parser.add_argument("--by", help="split each operation by this detail key")
    parser.add_argument("--slowest", type=int, default=0, help="also list the N slowest measurements")
    args = parser.parse_args()

    if not os.path.exists(LOG):
        print(f"No timings yet: {LOG} does not exist. Use Mailer for a while first.")
        return
    entries = read_entries(args.since, args.op)
    if not entries:
        print("No measurements match.")
        return
    print_table(group(entries, args.by))
    if args.slowest:
        print_slowest(entries, args.slowest)


if __name__ == "__main__":
    main()
