#!/bin/bash
set -euo pipefail
# Ensure we are in the scripts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Assuming the script is in scripts/sosp24-experiments/
# We want to go to scripts/
cd "$SCRIPT_DIR/.." || exit 1
echo "Running flow experiment... this may take a few minutes"

# --- Parse arguments ---
VM_NAME=""
NUM_CORES=""
NUM_FLOWS=""
DRY_RUN=0
EXP_NAME=""
HOST_IP_ARG=""
HOST_SSH_UNAME_ARG=""
HOST_HOME_ARG=""
HOST_RESULTS_DIR_ARG=""
PERF_TRACING=0
PERF_HOST_TRACING=0
SYNC_DIR=""
MEASUREMENT_DURATION=20

while [[ $# -gt 0 ]]; do
	case "$1" in
	--vm-name)          VM_NAME="$2";              shift 2 ;;
	--num-cores)        NUM_CORES="$2";            shift 2 ;;
	--num-flows)        NUM_FLOWS="$2";            shift 2 ;;
	--exp-name)         EXP_NAME="$2";             shift 2 ;;
	--host-ip)          HOST_IP_ARG="$2";          shift 2 ;;
	--host-ssh-uname)   HOST_SSH_UNAME_ARG="$2";   shift 2 ;;
	--host-home)        HOST_HOME_ARG="$2";        shift 2 ;;
	--host-results-dir) HOST_RESULTS_DIR_ARG="$2"; shift 2 ;;
	--perf-tracing)     PERF_TRACING="$2";         shift 2 ;;
	--perf-host-tracing) PERF_HOST_TRACING="$2";   shift 2 ;;
	--sync-dir) SYNC_DIR="$2"; shift 2 ;;
	--duration) MEASUREMENT_DURATION="$2"; shift 2 ;;
	--dry)              DRY_RUN=1;                 shift   ;;
	*)                  shift                      ;;
	esac
done

if [[ -z "$VM_NAME" || -z "$NUM_CORES" || -z "$NUM_FLOWS" || -z "$EXP_NAME" ]]; then
	echo "Usage: $0 --vm-name <n> --num-cores <N> --num-flows <N> --exp-name <name> [--dry]" >&2
	echo "  Optional: --perf-tracing <0|1> --perf-host-tracing <0|1>" >&2
	echo "  Optional: --host-ip <ip> --host-ssh-uname <user> --host-home <path> --host-results-dir <path>" >&2
	exit 1
fi

case "${PERF_TRACING}:${PERF_HOST_TRACING}" in
0:0|0:1|1:0|1:1) ;;
*) echo "ERROR: perf tracing flags must be 0 or 1" >&2; exit 1 ;;
esac

# --- Derive VM index from name (trailing vmN) ---
if [[ "$VM_NAME" =~ vm([0-9]+)$ ]]; then
	VM_INDEX="${BASH_REMATCH[1]}"
else
	echo "ERROR: cannot extract VM index from name '$VM_NAME'" >&2
	exit 1
fi

echo "VM name:  $VM_NAME"
echo "VM index: $VM_INDEX"
echo "Cores:    $NUM_CORES"
echo "Flows:    $NUM_FLOWS"
echo "Experiment Name: $EXP_NAME"
echo "Perf recording: guest=$PERF_TRACING host=$PERF_HOST_TRACING"

# --- Configuration ---
GUEST_INTF="enp0s1"
GUEST_IP="192.168.101.$((11 + VM_INDEX))"
GUEST_NIC_BUS="0x0"
GUEST_HOME="/home/schai"

HOST_IP="${HOST_IP_ARG:-192.17.101.97}"
HOST_SSH_UNAME="${HOST_SSH_UNAME_ARG:-lbalara}"
HOST_HOME="${HOST_HOME_ARG:-/home/lbalara}"
HOST_RESULTS_DIR="${HOST_RESULTS_DIR_ARG:-/home/lbalara/viommu/ManyVM-FandS/utils/reports/}"

CLIENT_HOME="/home/siyuanc3"
CLIENT_INTF="ens1006np0"
CLIENT_IP="192.168.101.3"
CLIENT_SSH_UNAME="siyuanc3"
CLIENT_SSH_HOST="nexus03.csl.illinois.edu"
CLIENT_SSH_PASSWORD="saksham"
CLIENT_USE_PASS_AUTH=0
CLIENT_SSH_IDENTITY_FILE="/home/schai/.ssh/id_rsa"

HOST_SSH_PASSWORD=""
HOST_SSH_IDENTITY_FILE="/home/schai/.ssh/id_rsa"
HOST_USE_PASS_AUTH=0

Z_LIST_DLF="1"

echo "Guest IP: $GUEST_IP"

source "$SCRIPT_DIR/../multi-vm-ssh.sh"

if [ "$CLIENT_USE_PASS_AUTH" -eq 1 ]; then
	SSH_CLIENT_CMD="sshpass -p $CLIENT_SSH_PASSWORD ssh ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
else
	SSH_CLIENT_CMD="ssh -i $CLIENT_SSH_IDENTITY_FILE ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
fi

if [ "$HOST_USE_PASS_AUTH" -eq 1 ]; then
	SSH_HOST_CMD="sshpass -p $HOST_SSH_PASSWORD ssh ${HOST_SSH_UNAME}@${HOST_IP}"
	SCP_HOST_CMD="sshpass -p $HOST_SSH_PASSWORD scp"
else
	SSH_HOST_CMD="ssh -i $HOST_SSH_IDENTITY_FILE ${HOST_SSH_UNAME}@${HOST_IP}"
	SCP_HOST_CMD="scp -i $HOST_SSH_IDENTITY_FILE"
fi

all_cores=$(echo {0..63} | tr ' ' ',')
client_core_offset=$((VM_INDEX * NUM_CORES))
client_cores_mask=$(echo "$all_cores" | tr ',' '\n' | tail -n +$((client_core_offset + 1)) | head -n "$NUM_CORES" | tr '\n' ',' | sed 's/,$//')
server_cores_mask=$(echo "$all_cores" | tr ',' '\n' | head -n "$NUM_CORES" | tr '\n' ',' | sed 's/,$//')

echo "Client cores (offset by VM index $VM_INDEX): $client_cores_mask"
echo "Server cores: $server_cores_mask"

# --- Run experiment ---
socket_buf=1
ring_buffer=512

# Always one run as we need to sync for multi-vm
N_RUNS=1

format_flows=$(printf "%02d" "$NUM_FLOWS")


# Check for DLF mode
if sudo test -f "/sys/kernel/debug/iommu/leader_max_flushes"; then
	z_list="$Z_LIST_DLF"
else
	z_list=""
fi

run_list="${z_list:-default}"

for z in $run_list; do
  if [ "$z" != "default" ]; then
    # DLF Setup
    echo $z | sudo tee /sys/kernel/debug/iommu/leader_max_flushes
    echo "Leader Max Flushes: $(sudo cat /sys/kernel/debug/iommu/leader_max_flushes)"
  fi
  
  echo "Running $EXP_NAME" "N_RUN=$N_RUNS"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] Skipping actual experiment"
    continue
  fi

  sudo mkdir -p ../utils/reports/$EXP_NAME
  
  sudo bash many-vm-tx-run-dctcp-tput-experiment.sh \
    --vm-id "$VM_INDEX" \
    --guest-home "$GUEST_HOME" --guest-ip "$GUEST_IP" --guest-intf "$GUEST_INTF" --guest-bus "$GUEST_NIC_BUS" \
    -n "$NUM_FLOWS" -c $server_cores_mask \
    --client-home "$CLIENT_HOME" --client-ip "$CLIENT_IP" --client-intf "$CLIENT_INTF" \
    -N "$NUM_FLOWS" -C $client_cores_mask \
    --host-results-dir "$HOST_RESULTS_DIR" --host-home "$HOST_HOME" --host-ip "$HOST_IP" --host-ssh-name "$HOST_SSH_UNAME" \
    --perf-tracing "$PERF_TRACING" --perf-host-tracing "$PERF_HOST_TRACING" \
		--sync-dir "$SYNC_DIR" --dur "$MEASUREMENT_DURATION" \
    --client-ssh-name "$CLIENT_SSH_UNAME" --client-ssh-pass "$CLIENT_SSH_PASSWORD" \
    --client-ssh-host "$CLIENT_SSH_HOST" --client-ssh-use-pass "$CLIENT_USE_PASS_AUTH" \
    --client-ssh-ifile "$CLIENT_SSH_IDENTITY_FILE" \
    -e "$EXP_NAME" -m 4000 -r $ring_buffer -b "400g" -d 1 \
    --socket-buf $socket_buf --mlc-cores 'none' --runs $N_RUNS 2>&1 | sudo tee ../utils/reports/$EXP_NAME/experiment.log

  sudo chmod -R a+rw ../utils/reports/$EXP_NAME
  
  # --- SCP results back to host ---
	echo "Copying results to host..."
	local_report_dir="../utils/reports/$EXP_NAME"
	local_run_dir="${local_report_dir}-RUN-0"

	$SSH_HOST_CMD "mkdir -p ${HOST_RESULTS_DIR}/${EXP_NAME}"

	sleep 5

	$SCP_HOST_CMD -r \
		"$local_report_dir"/* \
		"${HOST_SSH_UNAME}@${HOST_IP}:${HOST_RESULTS_DIR}/${EXP_NAME}/"

	# The stats collector copies only summary metrics. Preserve perf artifacts
	# from the raw run directory before the host destroys this guest.
	if [[ "$PERF_TRACING" -eq 1 ]]; then
		sudo chmod a+r "$local_run_dir"/perf_guest_cpu.{data,stacks} "$local_run_dir/perf_guest_record.log"
		$SCP_HOST_CMD \
			"$local_run_dir"/perf_guest_cpu.{data,stacks} "$local_run_dir/perf_guest_record.log" \
			"${HOST_SSH_UNAME}@${HOST_IP}:${HOST_RESULTS_DIR}/${EXP_NAME}/"
	fi

	echo "Results copied to ${HOST_SSH_UNAME}@${HOST_IP}:${HOST_RESULTS_DIR}/${EXP_NAME}/"

done

sleep 1
echo ""
echo "=== Experiment complete on ${VM_NAME} ==="