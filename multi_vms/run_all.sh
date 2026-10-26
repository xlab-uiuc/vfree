#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VIOMMU_MODES=("off" "vFree-dlf" "nested" "vFree-pin")
# VIOMMU_MODES=("off")
TRAFFIC_DIRECTION="${TRAFFIC_DIRECTION:-RX}"
NUM_RUNS=1

# --- Experiment configurations ---
#   (num_vms, num_total_cores, num_active_cores, num_flows)
#   num_flows = num_active_cores per VM
CONFIGS=(
	# "1 32 32 32"
	"2 16 16 16"
	"4 8 8 8"
	"8 4 4 4"
	"16 2 2 2"
	# "2 16 16 16"
	# "4 16 16 16"
)


if [[ ! "$NUM_RUNS" =~ ^[1-9][0-9]*$ ]]; then
	echo "Error: NUM_RUNS must be a positive integer" >&2
	exit 2
fi


case "$TRAFFIC_DIRECTION" in
TX|RX) ;;
*) echo "Error: TRAFFIC_DIRECTION must be TX or RX" >&2; exit 2 ;;
esac

if [[ ${#CONFIGS[@]} -eq 0 || ${#VIOMMU_MODES[@]} -eq 0 ]]; then
	echo "Error: CONFIGS and VIOMMU_MODES must not be empty" >&2; exit 2
fi


REPORTS_DIR="${SCRIPT_DIR}/../utils/reports"
mkdir -p "$REPORTS_DIR"
REPORTS_DIR=$(readlink -f "$REPORTS_DIR")
RUN_TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
RUN_NAME="${RUN_TIMESTAMP}-${TRAFFIC_DIRECTION}"
echo "Run timestamp: $RUN_TIMESTAMP"

run_idx=0
failed_runs=0
summary_failed=0
total=$((${#CONFIGS[@]} * ${#VIOMMU_MODES[@]} * NUM_RUNS))

for config in "${CONFIGS[@]}"; do
	read -r num_vms num_total_cores num_active_cores num_flows <<< "$config"
	for viommu in "${VIOMMU_MODES[@]}"; do
		config_name="vms${num_vms}-total${num_total_cores}-active${num_active_cores}-flows${num_flows}"
    config_dir="$REPORTS_DIR/${config_name}-viommu-${viommu}/$RUN_NAME"
    mkdir -p "$(dirname "$config_dir")"
    mkdir "$config_dir"
    echo "Configuration reports: $config_dir"

		for ((run_number = 1; run_number <= NUM_RUNS; run_number++)); do
			run_idx=$((run_idx + 1))
			printf -v run_label 'run-%02d' "$run_number"
			run_dir="$config_dir/$run_label"
			mkdir -p "$run_dir"
			echo ""
			echo "================================================================"
			echo "  Run ${run_idx}/${total}, ${run_label}/${NUM_RUNS}: --direction ${TRAFFIC_DIRECTION} --viommu ${viommu}" \
				"--num-vms ${num_vms} --num-total-cores ${num_total_cores}" \
				"--num-active-cores ${num_active_cores} --num-flows ${num_flows}"
			echo "================================================================"
			rc=0
			./run_vms.sh \
				--skip-reset-host --record-counters on \
				--viommu "$viommu" --num-vms "$num_vms" \
				--num-total-cores "$num_total_cores" --num-active-cores "$num_active_cores" \
				--num-flows "$num_flows" \
				--direction "$TRAFFIC_DIRECTION" \
				--timestamp "$RUN_TIMESTAMP" --run-label "$run_label" \
				--reports-dir "$run_dir" --result-file "$run_dir/result.json" 2>&1 | tee "$run_dir/launcher.log" || rc=$?
			printf '%s\n' "$rc" > "$run_dir/exit-code"
			if [[ $rc -ne 0 ]]; then
				failed_runs=$((failed_runs + 1))
				echo "WARNING: Run ${run_idx} failed (exit $rc), continuing..."
			fi
		done
		if ! python3 "$SCRIPT_DIR/summarize_runs.py" "$config_dir" --expected-runs "$NUM_RUNS"; then
			summary_failed=1
		fi
	done
done

if ! python3 "$SCRIPT_DIR/summarize_runs.py" "$REPORTS_DIR" --sweep "$RUN_NAME"; then
    summary_failed=1
fi

echo "All ${total} runs finished; ${failed_runs} launcher failures."
if [[ "$failed_runs" -gt 0 || "$summary_failed" -ne 0 ]]; then
	echo "WARNING: experiments failed or had incomplete reports; summary failed; inspect per-run logs." >&2
	exit 1
fi
echo "Combined summary: $REPORTS_DIR/summary-$RUN_NAME.txt ($REPORTS_DIR/summary-$RUN_NAME.csv)"
