import os
import re
import sys
import numpy as np

if len(sys.argv) < 3:
    print("Usage: python script.py <base_exp_name> <metrics> [num_vms] [reports_dir]")
    print("  metrics: comma-separated list of: tput,cpu,all")
    print("  num_vms: optional, auto-detected if omitted")
    sys.exit(1)

# Get the directory where the script is located and change directory
script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
os.chdir(script_dir)

base_exp_name = sys.argv[1]
metrics = list(map(str.lower, sys.argv[2].split(",")))
num_vms = int(sys.argv[3]) if len(sys.argv) > 3 else None

reports_dir = sys.argv[4] if len(sys.argv) > 4 else os.path.join("../utils/reports/")

# Auto-detect VM directories matching the base experiment name
vm_dirs = []
for entry in sorted(os.listdir(reports_dir)):
    full_path = os.path.join(reports_dir, entry)
    if not os.path.isdir(full_path):
        continue
    # Match per-VM directories: must start with base_exp_name, have a suffix, and not be a RUN dir
    suffix = entry[len(base_exp_name):]
    if entry.startswith(base_exp_name + "-") and re.search(r"-vm[0-9]+$", suffix):
        vm_dirs.append(entry)

indices = [int(re.search(r"-vm([0-9]+)$", name).group(1)) for name in vm_dirs]
expected = num_vms if num_vms is not None else len(vm_dirs)
if len(vm_dirs) != expected or set(indices) != set(range(expected)):
    raise SystemExit(f"Expected VMs 0..{expected - 1}; found indices {indices}")

if not vm_dirs:
    print(f"No VM directories found matching '{base_exp_name}' in {reports_dir}")
    sys.exit(1)

# Collect per-VM results
all_tputs = []
all_cpus = []

# Load every VM before printing results, so a missing/invalid VM cannot yield
# a successful report for a subset.
loaded = []
for vm_dir in vm_dirs:
    metrics_file = os.path.join(reports_dir, vm_dir, "tput_metrics.dat")
    try:
        results = np.genfromtxt(metrics_file, dtype=float, delimiter=',', names=True)
        if results.size != 1:
            raise ValueError('expected one metrics row')
        tput, cpu = float(results['net_tput_mean']), float(results['cpu_utils_mean'])
        if not np.isfinite([tput, cpu]).all() or tput < 0 or not 0 <= cpu <= 100:
            raise ValueError('invalid throughput or CPU value')
    except (OSError, ValueError, KeyError) as exc:
        raise SystemExit(f"{metrics_file}: {exc}")
    loaded.append((vm_dir, tput, cpu))

print(f"======= Multi-VM Results: {base_exp_name} =======")
print(f"VMs found: {len(vm_dirs)}")
print()
for vm_dir, tput, cpu in loaded:
    all_tputs.append(tput)
    all_cpus.append(cpu)
    print(f"--- {vm_dir} ---")
    if "tput" in metrics or "all" in metrics:
        print(f"  Throughput: {tput:.4f} Gbps")
    if "cpu" in metrics or "all" in metrics:
        print(f"  CPU Util:   {cpu:.4f} %")
    print()

# Aggregate summary
if all_tputs:
    print(f"======= Aggregate ({len(all_tputs)} VMs) =======")
    if "tput" in metrics or "all" in metrics:
        print(f"  Total Throughput:   {sum(all_tputs):.4f} Gbps")
        print(f"  Mean Throughput:    {np.mean(all_tputs):.4f} Gbps")
        if len(all_tputs) > 1:
            print(f"  Stddev Throughput:  {np.std(all_tputs, ddof=1):.4f} Gbps")
    if "cpu" in metrics or "all" in metrics:
        print(f"  Mean CPU Util:      {np.mean(all_cpus):.4f} %")
        if len(all_cpus) > 1:
            print(f"  Stddev CPU Util:    {np.std(all_cpus, ddof=1):.4f} %")
    print()
