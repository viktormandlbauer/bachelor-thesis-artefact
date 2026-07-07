#!/usr/bin/env python3
"""Aggregate the measurement harness' raw.csv into the thesis report format.

Protocol §6 (SRQ3 - Measurement Protocol): per metric report all raw runs,
median and IQR; the comparison view places the three platforms side by
side. Emits GitHub-flavoured markdown on stdout.

    python3 measure/stats.py docs/reports/measurements/<id>/raw.csv
"""
import csv
import statistics
import sys
from collections import defaultdict

PLATFORM_ORDER = ["compose", "podman", "k3s"]
PLATFORM_LABEL = {
    "compose": "docker compose",
    "podman": "podman kube play",
    "k3s": "k3s (PoC)",
}

# metric id -> (protocol id, section) for the SRQ3 mapping
PROTOCOL_IDS = {
    "platform_rss_total": ("M-PF-01", "D1 platform footprint"),
    "platform_rss_core": ("M-PF-01a", "D1 platform footprint"),
    "platform_rss_kube_system": ("M-PF-01b", "D1 platform footprint"),
    "platform_rss_argocd": ("M-PF-01c", "D1 platform footprint"),
    "platform_rss_argocd_with_controller": ("M-PF-01d", "D1 platform footprint"),
    "platform_cpu_idle": ("M-PF-02", "D1 platform footprint"),
    "platform_disk_binaries": ("M-PF-03a", "D1 platform footprint"),
    "platform_disk_state": ("M-PF-03b", "D1 platform footprint"),
    "image_store": ("M-PF-03c", "D1 platform footprint"),
    "cold_start": ("M-PF-04", "D1 platform footprint"),
    "install_time": ("M-LC-01", "D2 lifecycle timing"),
    "upgrade_time": ("M-LC-02", "D2 lifecycle timing"),
    "rollback_time": ("M-LC-03", "D2 lifecycle timing"),
    "http_throughput": ("M-WP-01", "D3 workload performance"),
    "http_p50": ("M-WP-02", "D3 workload performance"),
    "http_p95": ("M-WP-03", "D3 workload performance"),
    "http_p99": ("M-WP-03+", "D3 workload performance"),
    "http_error_rate": ("M-WP-04", "D3 workload performance"),
    "startup_time": ("M-WP-05", "D3 workload performance"),
    "workload_rss_total": ("M-WP-06*", "D3 workload performance"),
}

SECTION_ORDER = [
    "D1 platform footprint",
    "D2 lifecycle timing",
    "D3 workload performance",
    "other",
]


def fmt(v: float) -> str:
    if v == int(v) and abs(v) >= 1:
        return str(int(v))
    return f"{v:.2f}".rstrip("0").rstrip(".")


def main(path: str) -> None:
    data = defaultdict(list)  # (metric, platform) -> [(run, value, unit, notes)]
    versions = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            m, p = row["metric"], row["platform"]
            if m in ("version", "os"):
                versions.setdefault(p, []).append(f'{row["value"]} {row["notes"]}'.strip())
                continue
            try:
                v = float(row["value"])
            except ValueError:
                continue
            data[(m, p)].append((row["run"], v, row["unit"], row["notes"]))

    metrics = sorted({m for m, _ in data}, key=lambda m: (
        SECTION_ORDER.index(PROTOCOL_IDS.get(m, ("", "other"))[1]),
        PROTOCOL_IDS.get(m, ("Z", ""))[0],
        m,
    ))

    print("# Measurement report — platform comparison")
    print()
    print(f"Source: `{path}` — medians with IQR over the raw runs "
          "(SRQ3 measurement protocol, §6 reporting format).")
    print()
    if versions:
        print("## Component versions")
        print()
        for p in PLATFORM_ORDER:
            if p in versions:
                print(f"- **{PLATFORM_LABEL[p]}**: " + "; ".join(versions[p]))
        print()

    current_section = None
    for m in metrics:
        section = PROTOCOL_IDS.get(m, ("", "other"))[1]
        proto = PROTOCOL_IDS.get(m, ("—",))[0]
        if section != current_section:
            print(f"## {section}")
            print()
            current_section = section

        unit = next(
            (u for p in PLATFORM_ORDER for _, _, u, _ in data.get((m, p), []) if u),
            "",
        )
        print(f"### `{m}` ({proto}, {unit})")
        print()
        print("| platform | runs | median | IQR | min | max | raw |")
        print("|---|---|---|---|---|---|---|")
        for p in PLATFORM_ORDER:
            rows = data.get((m, p))
            if not rows:
                continue
            vals = [v for _, v, _, _ in rows]
            med = statistics.median(vals)
            if len(vals) >= 2:
                q = statistics.quantiles(vals, n=4, method="inclusive")
                iqr = q[2] - q[0]
            else:
                iqr = 0.0
            raw = " ".join(fmt(v) for _, v, _, _ in sorted(rows, key=lambda r: r[0]))
            print(
                f"| {PLATFORM_LABEL[p]} | {len(vals)} | {fmt(med)} | {fmt(iqr)} "
                f"| {fmt(min(vals))} | {fmt(max(vals))} | {raw} |"
            )
        notes = {n for p in PLATFORM_ORDER for _, _, _, n in data.get((m, p), []) if n}
        if notes:
            print()
            for n in sorted(notes):
                print(f"- {n}")
        print()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
