#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Render a before/after markdown report from two forward-sweep results.json files."""

import argparse
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def fmt(value, suffix=""):
    return "-" if value is None else f"{value}{suffix}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--patched", required=True)
    args = parser.parse_args()

    base = load(args.baseline)
    new = load(args.patched)
    out = []

    out.append("## openshell forward service: baseline vs patched")
    out.append("")
    out.append("| | baseline | patched |")
    out.append("|---|---|---|")
    for key, label in [
        ("gateway_image", "gateway image"),
        ("supervisor_image", "supervisor image"),
        ("cli_image", "cli image"),
        ("gateway_version", "gateway --version"),
        ("journal_mode", "SQLite `PRAGMA journal_mode`"),
        ("db_sidecars", "DB sidecar files"),
        ("fsync_mean_ms", "fdatasync 4 KiB mean (ms)"),
        ("dd_dsync", "dd oflag=dsync (200 x 4 KiB)"),
        ("limit_hits", "`connection limit reached` in forward log"),
        ("broken_pipes", "`Broken pipe` in forward log (client closed after 64 bytes)"),
        ("forward_warnings", "forward warnings total"),
        ("slow_statements", "sqlx `slow statement` warnings in gateway log"),
        ("runner", "runner"),
    ]:
        out.append(f"| {label} | {fmt(base.get(key))} | {fmt(new.get(key))} |")
    out.append("")
    out.append(
        "| scenario | baseline completed | baseline wall (s) | baseline mean/conn (ms) "
        "| patched completed | patched wall (s) | patched mean/conn (ms) | wall speedup |"
    )
    out.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    new_rows = {row["scenario"]: row for row in new.get("sweep", [])}
    for b in base.get("sweep", []):
        p = new_rows.get(b["scenario"], {})
        speedup = "-"
        if p.get("wall_s") and b.get("wall_s"):
            speedup = f"{b['wall_s'] / p['wall_s']:.1f}x"
        out.append(
            f"| {b['scenario']} | {b['completed']}/{b['n']} | {b['wall_s']} | {fmt(b['mean_ms'])} "
            f"| {fmt(p.get('completed'))}/{fmt(p.get('n'))} | {fmt(p.get('wall_s'))} | {fmt(p.get('mean_ms'))} "
            f"| {speedup} |"
        )
    out.append("")
    out.append(
        "Each concurrent row opens N TCP connections through the forward at the same instant; "
        "`completed` counts connections that received response bytes within the timeout. "
        "The gateway caps a sandbox at 20 concurrent SSH-session connections, so bursts above "
        "that can be refused by design; what matters is how quickly slots free up."
    )
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
