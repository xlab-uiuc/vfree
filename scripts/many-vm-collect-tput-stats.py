import math
from pathlib import Path
import statistics
import sys

import numpy as np

EXP_NAME = sys.argv[1]
NUM_RUNS = int(sys.argv[2])
report = Path('../utils/reports') / EXP_NAME
report.mkdir(parents=True, exist_ok=True)
metrics_file = report / 'tput_metrics.dat'
metrics_file.unlink(missing_ok=True)
if NUM_RUNS < 1:
    raise SystemExit('Expected at least one run')


def required_value(path, label):
    entries = [line.split() for line in path.read_text().splitlines()
               if line.split() and line.split()[0] == label]
    if len(entries) != 1 or len(entries[0]) != 2:
        raise ValueError(f'{path}: expected one {label} value')
    value = float(entries[0][1])
    if not math.isfinite(value) or value < 0 or (label == 'avg_cpu_util:' and value > 100):
        raise ValueError(f'{path}: invalid {label} value')
    return value


net_tputs, cpu_utils = [], []
try:
    for index in range(NUM_RUNS):
        run = report.with_name(report.name + '-RUN-' + str(index))
        net_tputs.append(required_value(run / 'iperf.bw.rpt', 'Avg_iperf_tput:'))
        cpu_utils.append(required_value(run / 'cpu_util.rpt', 'avg_cpu_util:'))
except (OSError, ValueError) as exc:
    raise SystemExit(str(exc))

values = [statistics.mean(cpu_utils), statistics.stdev(cpu_utils) if NUM_RUNS > 1 else 0,
          statistics.mean(net_tputs), statistics.stdev(net_tputs) if NUM_RUNS > 1 else 0]
np.savetxt(metrics_file, [values], delimiter=',',
           header='cpu_utils_mean,cpu_utils_stddev,net_tput_mean,net_tput_stddev',
           comments='', fmt='%.10f')
