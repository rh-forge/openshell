#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Measure per-connection cost through an `openshell forward service` listener.

For each concurrency level N the script opens N TCP connections at the same
instant (released from a barrier), sends one minimal HTTP/1.1 request, reads
up to 64 bytes of the response and closes. It records the wall time of the
whole burst, how many connections got a response, and the mean/max latency of
the completed ones. Each level runs twice; a 10-connection sequential pass
closes the sweep. Results are written as JSON and a markdown table is printed.
"""

import argparse
import json
import socket
import statistics
import sys
import threading
import time
from collections import Counter

REQUEST = b"GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
LEVELS = [1, 6, 16, 32, 64]
REPEATS = 2
SEQUENTIAL = 10


def one_connection(host, port, timeout):
    start = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.sendall(REQUEST)
            data = b""
            while len(data) < 64:
                chunk = sock.recv(64 - len(data))
                if not chunk:
                    break
                data += chunk
        elapsed = time.perf_counter() - start
        if data:
            return True, elapsed, None
        return False, elapsed, "eof-before-data"
    except socket.timeout:
        return False, time.perf_counter() - start, "timeout"
    except OSError as err:
        return False, time.perf_counter() - start, type(err).__name__


def burst(host, port, count, timeout):
    barrier = threading.Barrier(count + 1)
    results = [None] * count

    def worker(index):
        barrier.wait()
        results[index] = one_connection(host, port, timeout)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(count)]
    for thread in threads:
        thread.start()
    barrier.wait()
    start = time.perf_counter()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - start
    return summarize(count, wall, results)


def sequential(host, port, count, timeout):
    start = time.perf_counter()
    results = [one_connection(host, port, timeout) for _ in range(count)]
    wall = time.perf_counter() - start
    return summarize(count, wall, results)


def summarize(count, wall, results):
    completed = [elapsed for ok, elapsed, _ in results if ok]
    errors = Counter(reason for ok, _, reason in results if not ok)
    return {
        "n": count,
        "completed": len(completed),
        "wall_s": round(wall, 3),
        "mean_ms": round(statistics.fmean(completed) * 1000, 1) if completed else None,
        "max_ms": round(max(completed) * 1000, 1) if completed else None,
        "errors": dict(errors),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--pause", type=float, default=3.0, help="seconds between rounds")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    rows = []
    for level in LEVELS:
        for repeat in range(1, REPEATS + 1):
            row = burst(args.host, args.port, level, args.timeout)
            row["scenario"] = f"{level} concurrent, run {repeat}"
            rows.append(row)
            print(json.dumps(row), flush=True)
            time.sleep(args.pause)
    row = sequential(args.host, args.port, SEQUENTIAL, args.timeout)
    row["scenario"] = f"{SEQUENTIAL} sequential"
    rows.append(row)
    print(json.dumps(row), flush=True)

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=2)

    print()
    print("| scenario | completed | wall (s) | mean per conn (ms) | max (ms) | errors |")
    print("|---|---:|---:|---:|---:|---|")
    for row in rows:
        errors = ", ".join(f"{k}={v}" for k, v in row["errors"].items()) or "-"
        print(
            f"| {row['scenario']} | {row['completed']}/{row['n']} | {row['wall_s']} "
            f"| {row['mean_ms'] if row['mean_ms'] is not None else '-'} "
            f"| {row['max_ms'] if row['max_ms'] is not None else '-'} | {errors} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
