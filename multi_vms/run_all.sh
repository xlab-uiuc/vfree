#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# VIOMMU_MODES=("off" "nested-vFree" "nested")
VIOMMU_MODES=("off")

# --- Experiment configurations ---
#   (num_vms, num_total_cores, num_active_cores, num_flows)
#   num_flows = num_active_cores per VM
CONFIGS=(
	# "1 32 32 32"
	"2 16 16 16"
	# "4 8 8 8"
	# "8 4 4 4"
	# "16 2 2 2"
	# "2 16 16 16"
	# "4 16 16 16"
)

run_idx=0
total=$((${#CONFIGS[@]} * ${#VIOMMU_MODES[@]}))

for config in "${CONFIGS[@]}"; do
	read -r num_vms num_total_cores num_active_cores num_flows <<< "$config"

	for viommu in "${VIOMMU_MODES[@]}"; do
		run_idx=$((run_idx + 1))
		echo ""
		echo "================================================================"
		echo "  Run ${run_idx}/${total}: --viommu ${viommu} --num-vms ${num_vms}" \
			"--num-total-cores ${num_total_cores} --num-active-cores ${num_active_cores}" \
			"--num-flows ${num_flows}"
		echo "================================================================"
		echo ""

		./run_vms.sh \
			--viommu "$viommu" \
			--num-vms "$num_vms" \
			--num-total-cores "$num_total_cores" \
			--num-active-cores "$num_active_cores" \
			--num-flows "$num_flows" \
			--skip-reset-host

		rc=$?
		if [[ $rc -ne 0 ]]; then
			echo "WARNING: Run ${run_idx} failed (exit $rc), continuing..."
		fi
	done
done

echo ""
echo "================================================================"
echo "  All ${total} experiments complete"
echo "================================================================"
