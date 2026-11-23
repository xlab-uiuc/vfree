#!/usr/bin/env python3
"""Throughput, zero-copy fraction and CPU cost of zc_tput runs.

  collect-zc-tput.py run <exp>-RUN-<j> recv_zc|send_zc
  collect-zc-tput.py summary <exp> <num_runs>

`run` reads the guest's per-flow zc_tput logs (cumulative counters, one line
a second, first line when the connection comes up) and reports two
measurements:

  period  Throughput over PERIOD_S seconds after each flow's own start,
          summed over flows. This is the number collect-period-tput.sh takes
          for the iperf runs (the 120-150 s interval iperf prints per flow),
          and it falls after the eBPF/ftrace tracing that runs during the CPU
          window, so it is the throughput the figures use.
  window  Throughput over the interval in which record-host-metrics.sh sampled
          guest CPU (cpu_util.window). CPU cost per GiB uses this one, so CPU
          and bytes cover the same seconds.

The flows are still running when the runner calls this (they are killed in
the next run's cleanup), so `run` waits up to WAIT_TIMEOUT_S for every flow's
log to cover the period.

It writes two files to the run's report directory:

  iperf.bw.rpt  "Avg_iperf_tput: <period Gbit/s>", so vm-collect-tput-stats.py
                and vm-tx-collect-tput-stats.py work unchanged
  zc.rpt        both measurements, zero-copy fractions, guest CPU per GiB,
                validity

It exits 1 when the run is invalid: a flow's log does not cover the period or
the window, flows are missing, or less than MIN_ZC_FRACTION of the data went
zero-copy in either measurement.

`summary` averages zc.rpt over the runs into <exp>/zc_metrics.dat.

Run from the scripts/ directory, like the other collectors.
"""
import glob
import json
import os
import statistics
import sys
import time

REPORTS = "../utils/reports"
LOGS = "../utils/logs"
MIN_ZC_FRACTION = 0.99
PERIOD_S = (120.0, 150.0)  # seconds after each flow's start, as in collect-period-tput.sh
WAIT_TIMEOUT_S = 120


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


def wait_for_period(logs):
    """Wait until every log reaches PERIOD_S[1] seconds past its first sample."""
    deadline = time.monotonic() + WAIT_TIMEOUT_S
    announced = False
    while True:
        short = []
        for path in logs:
            rows = read_log(path)
            if not rows or rows[-1][0] - rows[0][0] < PERIOD_S[1]:
                short.append(path)
        if not short or time.monotonic() > deadline:
            return
        if not announced:
            print(f"waiting for {len(short)} flow log(s) to reach {PERIOD_S[1]:.0f} s")
            announced = True
        time.sleep(1)


def measure(logs, span_of):
    """Bytes, a and b summed over flows, each between the times span_of(rows) gives.

    Returns (bytes, a, b, total flow-seconds, names of logs that do not cover
    their span).
    """
    nbytes = a = b = seconds = 0.0
    short = []
    for path in logs:
        rows = read_log(path)
        try:
            start, end = span_of(rows)
            s, e = counters_at(rows, start), counters_at(rows, end)
        except (ValueError, IndexError):
            short.append(os.path.basename(path))
            continue
        nbytes += e[0] - s[0]
        a += e[1] - s[1]
        b += e[2] - s[2]
        seconds += end - start
    return nbytes, a, b, seconds, short


def zc_fraction(op, nbytes, a, b):
    if op == "recv_zc":
        return a / nbytes if nbytes else 0.0  # bytes mapped / bytes received
    return 1 - b / a if a else 0.0  # sends completed without a copy


def read_key(path, key):
    with open(path) as f:
        for line in f:
            if line.startswith(key):
                return float(line.split()[-1])
    raise KeyError(f"{key} not in {path}")


def run(run_name, op):
    rdir = os.path.join(REPORTS, run_name)
    with open(os.path.join(rdir, "cpu_util.window")) as f:
        win_start, win_end = (float(x) for x in f.read().split())
    with open(os.path.join(rdir, "config.json")) as f:
        guest = json.load(f)["guest"]
    expected_flows = int(guest["num_servers"])
    num_cores = len([c for c in guest["cpu_mask"].split(",") if c])

    logs = sorted(glob.glob(os.path.join(LOGS, run_name, f"zc_tput.{op}.port*.log")))
    problems = []
    if len(logs) != expected_flows:
        problems.append(f"found {len(logs)} flow logs, expected {expected_flows}")
    wait_for_period(logs)

    # Period: each flow over its own [start + 120 s, start + 150 s], summed
    # over flows like the per-flow iperf intervals.
    p_bytes, p_a, p_b, p_flow_s, short = measure(
        logs, lambda rows: (rows[0][0] + PERIOD_S[0], rows[0][0] + PERIOD_S[1]))
    for name in short:
        problems.append(f"{name} does not cover {PERIOD_S[0]:.0f}-{PERIOD_S[1]:.0f} s")
    covered = len(logs) - len(short)
    period_s = p_flow_s / covered if covered else 0.0
    period_gbps = p_bytes * 8 / period_s / 1e9 if period_s > 0 else 0.0
    period_fraction = zc_fraction(op, p_bytes, p_a, p_b)

    # Window: the CPU sampling interval, the same seconds for every flow.
    w_bytes, w_a, w_b, _, short = measure(logs, lambda rows: (win_start, win_end))
    for name in short:
        problems.append(f"{name} does not cover the CPU window")
    window_s = win_end - win_start
    window_gbps = w_bytes * 8 / window_s / 1e9 if window_s > 0 else 0.0
    window_fraction = zc_fraction(op, w_bytes, w_a, w_b)

    for label, frac in (("period", period_fraction), ("window", window_fraction)):
        if frac < MIN_ZC_FRACTION:
            problems.append(f"{label} zero-copy fraction {frac:.4f} < {MIN_ZC_FRACTION}")

    # sar's mean busy % over the flow cores, turned into cores busy per GiB/s.
    cpu_util = read_key(os.path.join(rdir, "cpu_util.rpt"), "avg_cpu_util:")
    gib_per_s = w_bytes / window_s / 2**30 if window_s > 0 else 0.0
    cpu_s_per_gib = cpu_util / 100 * num_cores / gib_per_s if gib_per_s else 0.0

    valid = not problems
    with open(os.path.join(rdir, "iperf.bw.rpt"), "w") as f:
        f.write(f"Period {PERIOD_S[0]:.0f}-{PERIOD_S[1]:.0f} tput: {period_gbps:.3f}\n")
        f.write(f"Avg_iperf_tput: {period_gbps:.3f}\n")
    with open(os.path.join(rdir, "zc.rpt"), "w") as f:
        f.write(f"ZC_op: {op}\n")
        f.write(f"ZC_flows: {len(logs)}\n")
        f.write(f"ZC_period: {PERIOD_S[0]:.0f}-{PERIOD_S[1]:.0f}\n")
        f.write(f"ZC_tput_gbps: {period_gbps:.3f}\n")
        f.write(f"ZC_fraction: {period_fraction:.6f}\n")
        f.write(f"ZC_window_s: {window_s:.3f}\n")
        f.write(f"ZC_window_tput_gbps: {window_gbps:.3f}\n")
        f.write(f"ZC_window_fraction: {window_fraction:.6f}\n")
        f.write(f"ZC_guest_cpu_s_per_gib: {cpu_s_per_gib:.6f}\n")
        f.write(f"ZC_valid: {int(valid)}\n")
        for p in problems:
            f.write(f"ZC_problem: {p}\n")

    print(f"{run_name}: {period_gbps:.2f} Gbit/s over {PERIOD_S[0]:.0f}-{PERIOD_S[1]:.0f} s "
          f"(zero-copy {period_fraction:.2%}); CPU window {window_gbps:.2f} Gbit/s, "
          f"{cpu_s_per_gib:.3f} guest CPU-s/GiB over {window_s:.1f} s")
    for p in problems:
        print(f"ERROR: {run_name}: {p}", file=sys.stderr)
    return 0 if valid else 1


def summary(exp, num_runs):
    keys = ["ZC_tput_gbps", "ZC_fraction", "ZC_window_tput_gbps", "ZC_window_fraction",
            "ZC_guest_cpu_s_per_gib", "ZC_valid"]
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
