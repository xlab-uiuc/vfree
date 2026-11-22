#!/usr/bin/env python3
"""Throughput, zero-copy fraction and CPU cost of zc_tput runs.

  collect-zc-tput.py run <exp>-RUN-<j> recv_zc|send_zc
  collect-zc-tput.py summary <exp> <num_runs>

`run` reads the guest's per-flow zc_tput logs and the interval over which
record-host-metrics.sh sampled guest CPU (cpu_util.window), so throughput and
CPU cost cover the same seconds. It writes two files to the run's report
directory:

  iperf.bw.rpt  "Avg_iperf_tput: <Gbit/s>", so vm-collect-tput-stats.py and
                vm-tx-collect-tput-stats.py work unchanged
  zc.rpt        throughput, zero-copy fraction, guest CPU per GiB, validity

It exits 1 when the run is invalid: a flow's log does not cover the window,
flows are missing, or less than MIN_ZC_FRACTION of the data went zero-copy.

`summary` averages zc.rpt over the runs into <exp>/zc_metrics.dat.

Run from the scripts/ directory, like the other collectors.
"""
import glob
import json
import os
import statistics
import sys

REPORTS = "../utils/reports"
LOGS = "../utils/logs"
MIN_ZC_FRACTION = 0.99


def read_log(path):
    """Rows of (seconds, bytes, a, b); see zc_tput.c for a and b."""
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            t, nbytes, a, b = (int(x) for x in line.split())
            rows.append((t / 1e9, nbytes, a, b))
    return rows


def counters_at(rows, t):
    """Cumulative counters at time t, linearly interpolated between samples."""
    if not rows or t < rows[0][0] or t > rows[-1][0]:
        raise ValueError
    for (t0, *v0), (t1, *v1) in zip(rows, rows[1:]):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return [x0 + f * (x1 - x0) for x0, x1 in zip(v0, v1)]
    return list(rows[-1][1:])


def read_key(path, key):
    with open(path) as f:
        for line in f:
            if line.startswith(key):
                return float(line.split()[-1])
    raise KeyError(f"{key} not in {path}")


def run(run_name, op):
    rdir = os.path.join(REPORTS, run_name)
    with open(os.path.join(rdir, "cpu_util.window")) as f:
        start, end = (float(x) for x in f.read().split())
    with open(os.path.join(rdir, "config.json")) as f:
        guest = json.load(f)["guest"]
    expected_flows = int(guest["num_servers"])
    num_cores = len([c for c in guest["cpu_mask"].split(",") if c])

    logs = sorted(glob.glob(os.path.join(LOGS, run_name, f"zc_tput.{op}.port*.log")))
    problems = []
    if len(logs) != expected_flows:
        problems.append(f"found {len(logs)} flow logs, expected {expected_flows}")

    nbytes = a = b = 0.0
    for path in logs:
        rows = read_log(path)
        try:
            s, e = counters_at(rows, start), counters_at(rows, end)
        except ValueError:
            problems.append(f"{os.path.basename(path)} does not cover the window")
            continue
        nbytes += e[0] - s[0]
        a += e[1] - s[1]
        b += e[2] - s[2]

    seconds = end - start
    gbps = nbytes * 8 / seconds / 1e9 if seconds > 0 else 0.0
    if op == "recv_zc":
        zc_fraction = a / nbytes if nbytes else 0.0  # bytes mapped / bytes received
    else:
        zc_fraction = 1 - b / a if a else 0.0  # sends completed without a copy
    if zc_fraction < MIN_ZC_FRACTION:
        problems.append(f"zero-copy fraction {zc_fraction:.4f} < {MIN_ZC_FRACTION}")

    # sar's mean busy % over the flow cores, turned into cores busy per GiB/s.
    cpu_util = read_key(os.path.join(rdir, "cpu_util.rpt"), "avg_cpu_util:")
    gib_per_s = nbytes / seconds / 2**30 if seconds > 0 else 0.0
    cpu_s_per_gib = cpu_util / 100 * num_cores / gib_per_s if gib_per_s else 0.0

    valid = not problems
    with open(os.path.join(rdir, "iperf.bw.rpt"), "w") as f:
        f.write(f"Avg_iperf_tput: {gbps:.3f}\n")
    with open(os.path.join(rdir, "zc.rpt"), "w") as f:
        f.write(f"ZC_op: {op}\n")
        f.write(f"ZC_window_s: {seconds:.3f}\n")
        f.write(f"ZC_flows: {len(logs)}\n")
        f.write(f"ZC_tput_gbps: {gbps:.3f}\n")
        f.write(f"ZC_fraction: {zc_fraction:.6f}\n")
        f.write(f"ZC_guest_cpu_s_per_gib: {cpu_s_per_gib:.6f}\n")
        f.write(f"ZC_valid: {int(valid)}\n")
        for p in problems:
            f.write(f"ZC_problem: {p}\n")

    print(f"{run_name}: {gbps:.2f} Gbit/s, zero-copy {zc_fraction:.2%}, "
          f"{cpu_s_per_gib:.3f} guest CPU-s/GiB over {seconds:.1f} s")
    for p in problems:
        print(f"ERROR: {run_name}: {p}", file=sys.stderr)
    return 0 if valid else 1


def summary(exp, num_runs):
    keys = ["ZC_tput_gbps", "ZC_fraction", "ZC_guest_cpu_s_per_gib", "ZC_valid"]
    values = {k: [] for k in keys}
    for j in range(num_runs):
        path = os.path.join(REPORTS, f"{exp}-RUN-{j}", "zc.rpt")
        for k in keys:
            values[k].append(read_key(path, k + ":"))

    def stats(xs):
        return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)

    out = []
    for k in keys[:-1]:
        mean, std = stats(values[k])
        out += [(k.lower() + "_mean", mean), (k.lower() + "_stddev", std)]
    out.append(("zc_valid_runs", sum(values["ZC_valid"])))
    out.append(("zc_runs", num_runs))

    os.makedirs(os.path.join(REPORTS, exp), exist_ok=True)
    with open(os.path.join(REPORTS, exp, "zc_metrics.dat"), "w") as f:
        f.write(",".join(k for k, _ in out) + "\n")
        f.write(",".join(f"{v:.10f}" for _, v in out) + "\n")
    for k, v in out:
        print(f"{k}: {v:.6g}")
    return 0 if sum(values["ZC_valid"]) == num_runs else 1


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "run" and sys.argv[3] in ("recv_zc", "send_zc"):
        sys.exit(run(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 4 and sys.argv[1] == "summary":
        sys.exit(summary(sys.argv[2], int(sys.argv[3])))
    sys.exit(__doc__)
