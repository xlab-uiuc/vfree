#!/bin/bash
# Usage: collect-period-tput.sh <exp-name-with-RUN>

if [ $# -eq 0 ]; then
    echo "Usage: $0 <exp-name>"
    exit 1
fi

# With offsets from record-host-metrics.sh, read only newly written one-second
# iperf intervals. Each file is one flow, so sum the per-flow mean rates.
if [[ $# -eq 2 || $# -eq 4 ]]; then
    python3 - "../utils/reports/$1/iperf.bw.rpt" "$2" "${3:-0}" "${4:-0}" <<'IPERF_WINDOW'
import json,math,re,sys
from pathlib import Path
report, offsets = Path(sys.argv[1]), json.loads(sys.argv[2])
report.unlink(missing_ok=True)
expected_duration, expected_flows = float(sys.argv[3]), int(sys.argv[4])
if expected_flows and (len(offsets) != expected_flows or expected_duration <= 0):
    raise SystemExit('Missing expected flow logs or measurement duration')
if not offsets:
    raise SystemExit('No flow logs supplied')
pattern=re.compile(r'(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s+sec\s+[\d.]+\s+\S+\s+([\d.]+)\s+([KMGT]?bits/sec)')
scales={'bits/sec':1e-9,'Kbits/sec':1e-6,'Mbits/sec':1e-3,'Gbits/sec':1,'Tbits/sec':1000}
total=0.0
for name,offset in offsets.items():
    with open(name,'rb') as stream:
        stream.seek(offset)
        lines=stream.read().decode(errors='replace').splitlines()
    weighted=duration=0.0
    previous_end=None
    for line in lines:
        if 'sender' in line or 'receiver' in line:
            continue
        match=pattern.search(line)
        if match:
            start,end,rate,unit=match.groups()
            start,end,rate=float(start),float(end),float(rate)*scales[unit]
            elapsed=end-start
            if not all(math.isfinite(value) for value in (start,end,rate)) or elapsed<=0 or rate<0:
                raise SystemExit('Invalid iperf interval in '+name)
            if expected_flows and previous_end is not None and abs(start-previous_end)>.05:
                raise SystemExit('Gap or overlapping iperf intervals in '+name)
            previous_end=end
            if expected_duration:
                elapsed=min(elapsed,max(0,expected_duration-duration))
            weighted+=rate*elapsed
            duration+=elapsed
            if expected_duration and duration>=expected_duration-.05:
                break
    if duration==0:
        raise SystemExit('No measurement-window iperf reports in '+name)
    if expected_duration and duration<expected_duration-.05:
        raise SystemExit(f'Short iperf capture in {name}: {duration:g}/{expected_duration:g} seconds')
    total+=weighted/duration
report.write_text(f'Avg_iperf_tput: {total:.6f}\n')
IPERF_WINDOW
    exit $?
fi

period=(
    "0.*-30.*"
    "30.*-60.*"
    "60.*-90.*"
    "90.*-120.*"
    "120.*-150.*"
    "150.*-180.*"
    "180.*-210.*"
    "210.*-240.*"
    "240.*-270.*"
    "270.*-300.*"
)

report_dir="../utils/reports/$1"
report_file="$report_dir/iperf.bw.rpt"
log_file="../utils/logs/$1/iperf.bw.log"

if [ ! -f "$log_file" ]; then
    echo "ERROR: $log_file does not exist"
    exit 1
fi

> "$report_file"

last_tput=""
for p in "${period[@]}"; do
    iperf_tput=$(cat "$log_file" | grep "$p" | awk '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }')
    echo "Period $p tput: $iperf_tput" >> "$report_file"
    if [ -n "$iperf_tput" ]; then
        last_tput="$iperf_tput"
    fi
done
echo "Avg_iperf_tput: $last_tput" >> "$report_file"

echo "log_file: $log_file"
echo "tput report saved to $report_file"
