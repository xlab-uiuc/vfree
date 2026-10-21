#!/bin/bash
set -euo pipefail

# Passthrough guests use the system daemon, including in noninteractive SSH.
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# ============================================================
# Configuration
# ============================================================

GUEST_VIOMMU="nested-vFree" # off/nested/nested-vFree
NUM_VMS=1
NUM_TOTAL_CORES="16"
NUM_ACTIVE_CORES="12"
NUM_FLOWS="12"
REUSE=0
SKIP_RESET_HOST=0
PERF_TRACING="vm0" # off/vm0/all; one host recording whenever enabled
RECORD_COUNTERS=off # run_all.sh enables this by default
MEASUREMENT_DURATION=20
COUNTER_INTERVAL=1
HOST_PF_BDF="${HOST_PF_BDF:-0000:98:00.0}"
PCM_IIO_BIN="${PCM_IIO_BIN:-/home/lbalara/viommu/pcm/build/bin/pcm-iio}"
PCM_IIO_DIR="${PCM_IIO_DIR:-/home/lbalara/viommu/pcm/src}"
counter_pid=""
RUN_LABEL=""
RESULT_FILE=""
TRAFFIC_DIRECTION="TX"
vm_names=()

# --- Hardcoded experiment config ---
GIT_REPO="/home/schai/viommu"
GIT_BRANCH="multi-cross-numa-tx"

# --- Host paths (this script runs ON the host) ---
HOST_FandS_ABS=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
HOST_SETUP_DIR="${HOST_FandS_ABS}/utils"
echo "Host F&S dir: ${HOST_FandS_ABS}"

# --- Host config (auto-inferred, passed to VMs so they can SCP results back) ---
HOST_IP="192.17.101.97"
HOST_SSH_UNAME="${SUDO_USER:-$(whoami)}"
HOST_HOME="$(getent passwd "$HOST_SSH_UNAME" | cut -d: -f6)"
HOST_RESULTS_DIR="${HOST_FandS_ABS}/utils/reports/"

# --- Client machine config ---
CLIENT_HOME="/home/siyuanc3"
CLIENT_FandS_REL="Fast-and-Safe-IO-Memory-Protection"
CLIENT_SETUP_DIR_REL="utils"
CLIENT_INTF="ens1006np0"
CLIENT_IP="192.168.101.3"

# Client SSH (from host -> client)
CLIENT_SSH_UNAME="siyuanc3"
CLIENT_SSH_HOST="nexus03.csl.illinois.edu"
CLIENT_SSH_PASSWORD="saksham"
CLIENT_USE_PASS_AUTH=0
CLIENT_SSH_IDENTITY_FILE="/home/lbalara/.ssh/id_rsa"

# Client kernel validation
CLIENT_EXPECTED_KERNEL="6.12.9"
CLIENT_EXPECTED_IOMMU="intel_iommu=off"

# --- Network & experiment parameters ---
MTU=4000
DDIO_ENABLED=1
RING_BUFFER_SIZE=512
TCP_SOCKET_BUF_MB=1

# --- VM SSH settings (host -> guest VMs) ---
SSH_USER="schai"
SSH_KEY="/home/lbalara/.ssh/id_rsa"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

XML_DIR="./generated"


EXP_NAME=""
IP_BASE="192.168.122.100"

# --- SR-IOV settings ---
VF_DRIVER="vfio-pci"

# --- Timeouts ---
BOOT_TIMEOUT=240  # seconds to poll SSH
NIC_WAIT=120      # seconds to wait for guest NIC

# --- Guest NIC interface name (SR-IOV VF) ---
GUEST_NIC="enp0s1"

# --- Host-side in-tree modules (set after GUEST_KERNEL is resolved) ---
# HOST_MLX5_CORE and HOST_MLXFW are set after --viommu parsing below

# Save original directory
ORIG_DIR="$(pwd)"

# ============================================================
# Argument parsing
# ============================================================

usage() {
	cat <<-USAGE
	Usage: $0 [OPTIONS]
	  --direction DIR    Traffic direction: TX or RX (default: TX)
	  --viommu MODE       Guest vIOMMU mode: off, nested, nested-vFree (default: $GUEST_VIOMMU)
	  --num-total-cores N    Total cores per VM
	  --num-active-cores N   Active cores (iperf instances) per VM
	  --num-flows N       Number of flows per VM experiment
	  --num-vms N         Number of VMs (default: $NUM_VMS)
	  --reuse             Reuse already-defined VMs (skip undefine/define, just start)
	  --skip-reset-host   Skip host reset (host setup will still run)
	  --boot-timeout N    Seconds to wait for SSH per VM (default: $BOOT_TIMEOUT)
	  --perf-tracing MODE Record host and selected guests: off, vm0, all (default: off)
	  --record-counters MODE Record NIC/CPU/TCP and host IIO: on or off (default: off)
	  --duration N       Main measurement duration in seconds (default: 20)
	  --counter-interval N Counter sampling interval in seconds (default: 1)
	  --run-label LABEL  Append a repetition label to the experiment name
	  --result-file PATH Write machine-readable run status for sweep aggregation
	  -h, --help          Show this help
	USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--direction)
		[[ $# -ge 2 ]] || { echo "Error: --direction requires TX or RX" >&2; exit 2; }
		TRAFFIC_DIRECTION="$2"; shift 2 ;;
	--direction=*) TRAFFIC_DIRECTION="${1#*=}"; shift ;;
	--viommu)        GUEST_VIOMMU="$2"; shift 2 ;;
	--num-vms)       NUM_VMS="$2";      shift 2 ;;
	--num-total-cores)  NUM_TOTAL_CORES="$2";  shift 2 ;;
	--num-active-cores) NUM_ACTIVE_CORES="$2"; shift 2 ;;
	--num-flows)     NUM_FLOWS="$2";    shift 2 ;;
	--reuse)            REUSE=1;           shift   ;;
	--skip-reset-host)  SKIP_RESET_HOST=1; shift   ;;
	--boot-timeout)  BOOT_TIMEOUT="$2"; shift 2 ;;
	--perf-tracing)  PERF_TRACING="$2"; shift 2 ;;
	--record-counters) RECORD_COUNTERS="$2"; shift 2 ;;
	--duration) MEASUREMENT_DURATION="$2"; shift 2 ;;
	--counter-interval) COUNTER_INTERVAL="$2"; shift 2 ;;
	--run-label) RUN_LABEL="$2"; shift 2 ;;
	--result-file) RESULT_FILE="$2"; shift 2 ;;
	-h|--help)       usage; exit 0      ;;
	*)               echo "Error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
	esac
done

# Select the guest workload before any VM or host setup happens.
traffic_direction="${TRAFFIC_DIRECTION^^}"
case "$traffic_direction" in
TX) VM_SCRIPT="cd ${GIT_REPO}/scripts/sosp24-experiments; ./many_vm_tx_flows_exp.sh" ;;
RX) VM_SCRIPT="cd ${GIT_REPO}/scripts/sosp24-experiments; ./many_vm_flows_exp.sh" ;;
*) echo "Error: --direction must be TX or RX" >&2; exit 2 ;;
esac

case "$PERF_TRACING" in
off|vm0|all) ;;
*) echo "Error: --perf-tracing must be off, vm0, or all" >&2; exit 1 ;;
esac

case "$RECORD_COUNTERS" in
on|off) ;;
*) echo "Error: --record-counters must be on or off" >&2; exit 1 ;;
esac
if [[ -n "$RUN_LABEL" && ! "$RUN_LABEL" =~ ^[[:alnum:]_.-]+$ ]]; then
	echo "Error: --run-label must contain only letters, digits, dots, underscores, or hyphens" >&2
	exit 1
fi
# The existing shell runners require an integer measurement duration.
if [[ ! "$MEASUREMENT_DURATION" =~ ^[1-9][0-9]*$ || ! "$COUNTER_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
	echo "Error: --duration and --counter-interval must be positive integers" >&2
	exit 1
fi

if [[ -z "$NUM_TOTAL_CORES" || -z "$NUM_FLOWS" || -z "$NUM_VMS" || -z "$NUM_ACTIVE_CORES" ]]; then
	echo "Error: --num-total-cores, --num-active-cores, --num-flows, and --num-vms are required" >&2
	usage >&2
	exit 1
fi

# --- Build client SSH command ---
CLIENT_SETUP_DIR="${CLIENT_HOME}/${CLIENT_FandS_REL}/${CLIENT_SETUP_DIR_REL}"

if [ "$CLIENT_USE_PASS_AUTH" -eq 1 ]; then
	SSH_CLIENT_CMD="sshpass -p $CLIENT_SSH_PASSWORD ssh ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
else
	SSH_CLIENT_CMD="ssh -i $CLIENT_SSH_IDENTITY_FILE ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
fi

# --- Derive guest kernel, initrd, and cmdline from vIOMMU mode ---
GUEST_CMD_LINE_BASE="root=/dev/vda2 ro console=ttyS0,115200 earlyprintk=serial,ttyS0,115200"

case "$GUEST_VIOMMU" in
off)
	GUEST_KERNEL="6.12.9-iommufd"
	GUEST_KERNEL_PATH="/boot/vmlinuz-$GUEST_KERNEL"
	GUEST_INITRD_PATH="/boot/initrd.img-$GUEST_KERNEL"
	GUEST_CMD_LINE="$GUEST_CMD_LINE_BASE intel_iommu=off"
	;;
nested)
	GUEST_KERNEL="6.12.9-iommufd"
	GUEST_KERNEL_PATH="/boot/vmlinuz-$GUEST_KERNEL"
	GUEST_INITRD_PATH="/boot/initrd.img-$GUEST_KERNEL"
	GUEST_CMD_LINE="$GUEST_CMD_LINE_BASE intel_iommu=on,sm_on iommu.strict=1"
	;;
nested-vFree)
	GUEST_KERNEL="6.12.9-iommufd-nested-pin-mq"
	GUEST_KERNEL_PATH="/boot-VM/vmlinuz-$GUEST_KERNEL"
	GUEST_INITRD_PATH="/boot-VM/initrd.img-$GUEST_KERNEL"
	GUEST_CMD_LINE="$GUEST_CMD_LINE_BASE intel_iommu=on,sm_on iommu.strict=1 intel_iommu_pinned=on intel_iommu_dfp=on"
	;;
*)
	echo "Error: unknown --viommu mode '$GUEST_VIOMMU' (expected: off, nested, nested-vFree)" >&2
	exit 1
	;;
esac

HOST_KERNEL="$(uname -r)"

# --- Host-side in-tree modules to push into guests ---
HOST_MLX5_CORE="/lib/modules/$GUEST_KERNEL/kernel/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko"
HOST_MLXFW="/lib/modules/$GUEST_KERNEL/kernel/drivers/net/ethernet/mellanox/mlxfw/mlxfw.ko"

# ============================================================
# Helper functions
# ============================================================

log_info() {
	echo "[INFO-$(date +%Y-%m-%d-%H:%M:%S)] [host] $1"
}

log_error() {
	echo "[ERROR-$(date +%Y-%m-%d-%H:%M:%S)] [host] $1" >&2
}

parse_iommu_mode() {
	local cmdline="${1:-$(</proc/cmdline)}"
	local cl
	cl="$(printf '%s' "$cmdline" | tr '[:upper:]' '[:lower:]')"

	# Passthrough (separate case)
	if [[ "$cl" =~ (^|[[:space:]])(iommu=pt|iommu\.passthrough=(1|on|y|yes|true))($|[[:space:]]) ]]; then
		echo passthrough
		return
	fi

	# Off
	if [[ "$cl" =~ (^|[[:space:]])(noiommu|iommu=off|intel_iommu=off|amd_iommu=off)($|[[:space:]]) ]]; then
		echo off
		return
	fi

	# Strict
	if [[ "$cl" =~ (^|[[:space:]])iommu\.strict=(1|on|y|yes|true)($|[[:space:]]) ]] || \
	   [[ "$cl" =~ (^|[[:space:]])intel_iommu=([^[:space:]]*,)?strict([^[:space:]]*)($|[[:space:]]) ]] || \
	   [[ "$cl" =~ (^|[[:space:]])amd_iommu=([^[:space:]]*,)?strict([^[:space:]]*)($|[[:space:]]) ]]; then
		echo strict
		return
	fi

	# Lazy (non-strict)
	if [[ "$cl" =~ (^|[[:space:]])iommu\.strict=(0|off|n|no|false)($|[[:space:]]) ]] || \
	   [[ "$cl" =~ (^|[[:space:]])intel_iommu=([^[:space:]]*,)?nonstrict([^[:space:]]*)($|[[:space:]]) ]] || \
	   [[ "$cl" =~ (^|[[:space:]])amd_iommu=([^[:space:]]*,)?nonstrict([^[:space:]]*)($|[[:space:]]) ]]; then
		echo lazy
		return
	fi

	# Explicitly enabled but no strictness specified → assume strict
	if [[ "$cl" =~ (^|[[:space:]])(iommu=on|intel_iommu=on|amd_iommu=on)($|[[:space:]]) ]]; then
		echo strict
		return
	fi

	# Default if unspecified
	echo strict
}

vm_ip() {
	local idx=$1
	local prefix="${IP_BASE%.*}"
	local base_last_octet="${IP_BASE##*.}"
	echo "${prefix}.$((base_last_octet + idx))"
}

VM_DESTROY_WHITELIST=(
	"server-mini-off"
)

destroy_all_running_vms() {
	log_info "Shutting down any running VMs..."
	for vm in $(virsh list --name 2>/dev/null | grep -v '^$'); do
		local skip=false
		for wl in "${VM_DESTROY_WHITELIST[@]}"; do
			if [[ "$vm" == "$wl" ]]; then
				skip=true
				break
			fi
		done
		if $skip; then
			echo "  Skipping (whitelisted): $vm"
			continue
		fi
		echo "  Destroying: $vm"
		virsh destroy "$vm" 2>/dev/null || true
	done
	sleep 2
}

wait_for_ssh() {
	local ip=$1
	local name=$2
	local elapsed=0

	while [[ $elapsed -lt $BOOT_TIMEOUT ]]; do
		if ssh $SSH_OPTS "$SSH_USER@$ip" true 2>/dev/null; then
			echo "  ${name} (${ip}): SSH reachable after ${elapsed}s"
			return 0
		fi
		sleep 5
		elapsed=$((elapsed + 5))
	done

	log_error "${name} (${ip}): SSH not reachable after ${BOOT_TIMEOUT}s"
	return 1
}

wait_for_nic() {
	local ip=$1
	local name=$2

	if ssh $SSH_OPTS "$SSH_USER@$ip" "ip link show $GUEST_NIC" &>/dev/null; then
		echo "  ${name} (${ip}): $GUEST_NIC already up"
		return 0
	fi

	echo "  ${name} (${ip}): $GUEST_NIC not found, pushing in-tree mlx5 modules..."
	scp $SSH_OPTS "$HOST_MLX5_CORE" "$HOST_MLXFW" "$SSH_USER@$ip:/tmp/" &>/dev/null
	scp $SSH_OPTS /tmp/modules.tar.gz "$SSH_USER@$ip:/tmp/" &>/dev/null

	ssh $SSH_OPTS "$SSH_USER@$ip" "
		sudo tar xzf /tmp/modules.tar.gz -C /lib/modules/$(uname -r)/
		sudo rm -f /lib/modules/\$(uname -r)/updates/dkms/mlx5_core.ko \
		           /lib/modules/\$(uname -r)/updates/dkms/mlx5-vfio-pci.ko \
		           /lib/modules/\$(uname -r)/updates/dkms/mlxfw.ko \
		           /lib/modules/\$(uname -r)/updates/dkms/mlx_compat.ko \
		           /lib/modules/\$(uname -r)/updates/dkms/mlxdevm.ko
		sudo mkdir -p /lib/modules/\$(uname -r)/kernel/drivers/net/ethernet/mellanox/mlx5/core
		sudo mkdir -p /lib/modules/\$(uname -r)/kernel/drivers/net/ethernet/mellanox/mlxfw
		sudo cp /tmp/mlx5_core.ko /lib/modules/\$(uname -r)/kernel/drivers/net/ethernet/mellanox/mlx5/core/
		sudo cp /tmp/mlxfw.ko /lib/modules/\$(uname -r)/kernel/drivers/net/ethernet/mellanox/mlxfw/
		sudo depmod -a 2>/dev/null
		sudo modprobe mlx5_core 2>/dev/null
		sudo modprobe msr 2>/dev/null
	" &>/dev/null

	local elapsed=0
	while [[ $elapsed -lt $NIC_WAIT ]]; do
		if ssh $SSH_OPTS "$SSH_USER@$ip" "ip link show $GUEST_NIC" &>/dev/null; then
			echo "  ${name} (${ip}): $GUEST_NIC ready after ${elapsed}s"
			return 0
		fi
		sleep 5
		elapsed=$((elapsed + 5))
		echo "  ${name} (${ip}): waiting for $GUEST_NIC... (${elapsed}s/${NIC_WAIT}s)"
	done

	log_error "${name} (${ip}): $GUEST_NIC not found after ${NIC_WAIT}s"
	return 1
}

sync_git_repo() {
	local ip=$1
	local name=$2

	echo "  ${name} (${ip}): git checkout ${GIT_BRANCH} + pull..."
	ssh $SSH_OPTS "$SSH_USER@$ip" "
		cd ${GIT_REPO} && \
		git fetch --all && \
		git reset --hard HEAD && \
		git checkout ${GIT_BRANCH} && \
		git reset --hard origin/${GIT_BRANCH}
	"
	if [[ $? -ne 0 ]]; then
		log_error "${name} (${ip}): git sync failed"
		return 1
	fi
	echo "  ${name} (${ip}): git repo synced"
}

# --- Client kernel check (run once from host) ---
check_client_kernel() {
	log_info "Checking client kernel and IOMMU config..."

	local client_kernel
	client_kernel=$($SSH_CLIENT_CMD 'uname -r')
	local client_cmdline
	client_cmdline=$($SSH_CLIENT_CMD 'cat /proc/cmdline')

	if [[ "$client_kernel" != *"$CLIENT_EXPECTED_KERNEL"* ]]; then
		log_error "Client kernel mismatch. Expected: $CLIENT_EXPECTED_KERNEL, Actual: $client_kernel"
		return 1
	fi

	if [[ "$client_cmdline" != *"$CLIENT_EXPECTED_IOMMU"* ]]; then
		log_error "Client IOMMU mismatch. Expected: $CLIENT_EXPECTED_IOMMU, Actual: $client_cmdline"
		return 1
	fi

	log_info "Client kernel check PASSED (kernel=$client_kernel)"
}

# --- Client environment setup (run once from host before experiments) ---
setup_client() {
	log_info "Setting up client environment on $CLIENT_SSH_HOST..."

	# Disable flow control
	log_info "Disabling TX/RX pause on client interface $CLIENT_INTF"
	$SSH_CLIENT_CMD "sudo ethtool --pause $CLIENT_INTF tx off rx off"

	# Disable SMT
	log_info "Disabling SMT on client"
	$SSH_CLIENT_CMD "echo off | sudo tee /sys/devices/system/cpu/smt/control"

	# Run client setup-envir.sh
	log_info "Running client setup-envir.sh..."
	$SSH_CLIENT_CMD "cd '$CLIENT_SETUP_DIR'; \
		sudo bash setup-envir.sh \
			--dep '$CLIENT_HOME' \
			--intf '$CLIENT_INTF' \
			--ip '$CLIENT_IP' \
			-m '$MTU' \
			-d '$DDIO_ENABLED' \
			-r '$RING_BUFFER_SIZE' \
			--socket-buf '$TCP_SOCKET_BUF_MB' \
			--hwpref 1 --rdma 0 --pfc 0 --ecn 1 --opt 1"

	$SSH_CLIENT_CMD "sudo pkill -9 -f iperf"

	log_info "Client setup complete"
}

# --- Host environment setup (run locally, this IS the host) ---
setup_host() {
	log_info "Setting up host environment..."

	cd "$HOST_SETUP_DIR" || { log_error "Failed to cd to $HOST_SETUP_DIR"; return 1; }
	sudo bash setup-host.sh \
		-m "$MTU" \
		--socket-buf "$TCP_SOCKET_BUF_MB" \
		--hwpref 1 --rdma 0 --ecn 1
	cd "$ORIG_DIR"

	log_info "Host setup complete"
}

# Own only the recorder created for this run. Its children have bounded lifetimes.
stop_counter_recorder() {
	if [[ -n "$counter_pid" ]]; then
		kill "$counter_pid" 2>/dev/null || true
		wait "$counter_pid" 2>/dev/null || true
		counter_pid=""
	fi
}
finish_run() {
	local run_rc=$?
	trap - EXIT
	stop_counter_recorder
	if [[ -n "$RESULT_FILE" ]]; then
		if ! python3 - "$RESULT_FILE" "$run_rc" "$EXP_NAME" "$HOST_RESULTS_DIR" \
			"$GUEST_VIOMMU" "$NUM_VMS" "$NUM_TOTAL_CORES" "$NUM_ACTIVE_CORES" "$NUM_FLOWS" \
			"$MEASUREMENT_DURATION" "$COUNTER_INTERVAL" "$RECORD_COUNTERS" "$PERF_TRACING" \
			"$RUN_LABEL" "${traffic_direction:-unknown}" "$GUEST_KERNEL" "$ORIG_DIR" "${vm_names[@]}" <<'RESULT'
import json
import platform
from pathlib import Path
import shutil
import sys

(destination, rc, experiment, reports, viommu, num_vms, total, active, flows,
 duration, interval, counters, perf, label, direction, guest_kernel, log_directory, *vm_names) = sys.argv[1:]
report = (Path(reports) / experiment).resolve() if experiment else None
result = dict(schema_version=1, status='complete' if int(rc) == 0 else 'failed',
              exit_code=int(rc), experiment=experiment, report_directory=str(report) if report else None,
              run_label=label, vm_names=vm_names,
              configuration=dict(viommu=viommu, num_vms=int(num_vms), total_cores=int(total),
                                 active_cores=int(active), flows=int(flows), direction=direction,
                                 duration_s=int(duration), interval_s=int(interval),
                                 record_counters=counters, perf_tracing=perf, host_kernel=platform.release(),
                                 guest_kernel=guest_kernel))
if report:
    report.mkdir(parents=True, exist_ok=True)
    for name in vm_names:
        source = Path(log_directory) / (name + '_experiment.log')
        if source.exists() and experiment in source.read_text(errors='replace'):
            shutil.copy2(source, report / ('host-' + name + '_experiment.log'))
path = Path(destination).resolve()
path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_name(path.name + '.tmp')
temporary.write_text(json.dumps(result, indent=2) + '\n')
temporary.replace(path)
RESULT
		then
			log_error "Failed to write run result: $RESULT_FILE"
			[[ "$run_rc" -ne 0 ]] || run_rc=1
		fi
	fi
	exit "$run_rc"
}
trap finish_run EXIT

append_counter_summary() {
	if [[ "$RECORD_COUNTERS" == on && -f "$TELEMETRY_DIR/manifest.json" ]]; then
		python3 "$TELEMETRY_HELPER" summary "$TELEMETRY_DIR" \
			| tee -a "${HOST_RESULTS_DIR%/}/${EXP_NAME}/summary.txt"
	fi
}

# --- Cleanup (post-experiment) ---
cleanup() {
	stop_counter_recorder
	echo ""
	log_info "=== Cleanup ==="

	# Sync guest filesystems
	log_info "Syncing VM filesystems..."
	for ((i = 0; i < NUM_VMS; i++)); do
		local ip
		ip=$(vm_ip "$i")
		ssh $SSH_OPTS "$SSH_USER@$ip" "sync" 2>/dev/null || true
	done
	sleep 2

	# Destroy VMs and kill console loggers
	log_info "Destroying VMs..."
	for ((i = 0; i < NUM_VMS; i++)); do
		echo "  Destroying: ${vm_names[$i]}"
		virsh destroy "${vm_names[$i]}" 2>/dev/null || true
		if [[ -n "${console_pids[$i]:-}" ]]; then
			kill "${console_pids[$i]}" 2>/dev/null || true
			wait "${console_pids[$i]}" 2>/dev/null || true
		fi
	done

	# Reset SR-IOV
	log_info "Resetting SR-IOV..."
	sudo ./sriov_undo.sh

	# Host reset
	if [[ "$SKIP_RESET_HOST" -eq 1 ]]; then
		log_info "Skipping host reset (--skip-reset-host)"
	else
		log_info "Running host reset..."
		cd "$HOST_SETUP_DIR" || { log_error "Failed to cd to $HOST_SETUP_DIR"; return; }
		sudo ./reset-host.sh
		cd "$ORIG_DIR"
	fi

	log_info "=== Cleanup complete ==="
}

# ============================================================
# Main
# ============================================================

host_cmdline=$(cat /proc/cmdline)
host_iommu_config=$(parse_iommu_mode "$host_cmdline")

iommu_config="host-${host_iommu_config}-guest-${GUEST_VIOMMU}"
echo "iommu_config: $iommu_config"

# --- Step 1: Destroy any running VMs ---
echo ""
log_info "Step 1: Destroying any running VMs..."
destroy_all_running_vms

log_info "Doing sriov undo"
sudo ./sriov_undo.sh

# --- Step 2: Generate XML files ---
if [[ $REUSE -eq 0 ]]; then
	rm -rf ./generated
	./xml_generator.sh --kernel "$GUEST_KERNEL_PATH" --initrd "$GUEST_INITRD_PATH" --cmdline "$GUEST_CMD_LINE" \
		--vcpus $NUM_TOTAL_CORES --num-vms $NUM_VMS --viommu $GUEST_VIOMMU
fi

timestamp=$(date '+%Y-%m-%d-%H-%M-%S')
EXP_NAME="${timestamp}-HOST-$HOST_KERNEL-GUEST-$GUEST_KERNEL-MANY-${traffic_direction}-flow${NUM_FLOWS}-${iommu_config}-${NUM_TOTAL_CORES}cores-${NUM_ACTIVE_CORES}active-cores"
if [[ -n "$RUN_LABEL" ]]; then
	EXP_NAME+="-${RUN_LABEL}"
fi

echo "============================================================"
echo "  VM Benchmark Runner"
echo "============================================================"
echo "  VMs:       ${NUM_VMS}"
echo "  XML dir:   ${XML_DIR}"
echo "  Reuse:     ${REUSE}"
echo "  Branch:    ${GIT_BRANCH}"
echo "  Total Cores:  ${NUM_TOTAL_CORES}"
echo "  Active Cores: ${NUM_ACTIVE_CORES}"
echo "  Flows:     ${NUM_FLOWS}"
echo "  Perf:      ${PERF_TRACING}"
echo "  Exp name:  ${EXP_NAME}"
echo "  MTU:       ${MTU}"
echo "  Ring buf:  ${RING_BUFFER_SIZE}"
echo "  Socket buf: ${TCP_SOCKET_BUF_MB} MB"
echo "============================================================"
echo ""

# --- Step 3: Discover XML files and VM names ---
log_info "Step 3: Discovering VM XML files..."
xml_files=()
for f in "${XML_DIR}"/*.xml; do
	[[ -f "$f" ]] || continue
	xml_files+=("$f")
done

if [[ ${#xml_files[@]} -lt $NUM_VMS ]]; then
	log_error "Found ${#xml_files[@]} XML files in ${XML_DIR}, need ${NUM_VMS}"
	exit 1
fi

IFS=$'\n' xml_files=($(sort <<<"${xml_files[*]}")); unset IFS

vm_names=()
for ((i = 0; i < NUM_VMS; i++)); do
	xml="${xml_files[$i]}"
	vm_name=$(grep -oP '(?<=<name>)[^<]+' "$xml")
	vm_names+=("$vm_name")
	echo "  VM${i}: ${vm_name}"
done

# --- Step 4: Define or reuse VMs ---
echo ""
if [[ $REUSE -eq 0 ]]; then
	log_info "Step 4: Defining VMs from ${XML_DIR}..."
	for ((i = 0; i < NUM_VMS; i++)); do
		xml="${xml_files[$i]}"
		name="${vm_names[$i]}"

		if virsh dominfo "$name" &>/dev/null; then
			echo "  ${name}: already exists, undefining..."
			virsh undefine "$name" 2>/dev/null || true
		fi

		virsh define "$xml"
		echo "  Defined: ${name} (from ${xml})"
	done
else
	log_info "Step 4: Reusing already-defined VMs..."
	for ((i = 0; i < NUM_VMS; i++)); do
		name="${vm_names[$i]}"
		if ! virsh dominfo "$name" &>/dev/null; then
			log_error "${name} is not defined. Run without --reuse first."
			exit 1
		fi
		echo "  Reusing: ${name}"
	done
fi

# --- Step 5: Check client kernel ---
echo ""
log_info "Step 5: Checking client kernel..."
if ! check_client_kernel; then
	log_error "Client kernel check failed, aborting"
	cleanup
	exit 1
fi

# --- Step 6: Setup client environment ---
# Setup before so we have access to device
echo ""
log_info "Step 6: Setting up client environment..."
if ! setup_client; then
	log_error "Client setup failed, aborting"
	cleanup
	exit 1
fi

# --- Step 7: Configure SR-IOV ---
echo ""
log_info "Step 7: Configuring SR-IOV (${NUM_VMS} VFs)..."
sudo ./sriov.sh "$NUM_VMS"

# --- Step 8: Start all VMs + attach console loggers ---
echo ""
log_info "Step 8: Starting VMs..."
console_pids=()
for ((i = 0; i < NUM_VMS; i++)); do
	name="${vm_names[$i]}"
	virsh start "$name"
	sleep 2
	script -q -c "virsh console $name" "${name}.log" > /dev/null 2>&1 &
	console_pids+=($!)
	echo "  Started: ${name} (console -> ${name}.log)"
done

# --- Step 9: Wait for SSH on all VMs ---
echo ""
log_info "Step 9: Waiting for SSH (timeout: ${BOOT_TIMEOUT}s per VM)..."
failed=0
for ((i = 0; i < NUM_VMS; i++)); do
	ip=$(vm_ip "$i")
	if ! wait_for_ssh "$ip" "${vm_names[$i]}"; then
		failed=$((failed + 1))
	fi
done

if [[ $failed -gt 0 ]]; then
	log_error "${failed} VM(s) not reachable via SSH, aborting"
	cleanup
	exit 1
fi

# --- Step 10: Fix mlx5 modules and wait for guest NIC ---
echo ""
log_info "Step 10: Waiting for guest NIC ($GUEST_NIC)..."
failed=0
# Add sudo so that over users can overwrite
sudo rm -f /tmp/modules.tar.gz
tar czf /tmp/modules.tar.gz -C /lib/modules/$GUEST_KERNEL .
for ((i = 0; i < NUM_VMS; i++)); do
	ip=$(vm_ip "$i")
	if ! wait_for_nic "$ip" "${vm_names[$i]}"; then
		failed=$((failed + 1))
	fi
done

if [[ $failed -gt 0 ]]; then
	log_error "${failed} VM(s) missing $GUEST_NIC, aborting"
	cleanup
	exit 1
fi

# Reject cloned-interface address collisions before starting any traffic.
log_info "Checking that guest data NIC MAC addresses are unique..."
declare -A seen_guest_macs=()
for ((i = 0; i < NUM_VMS; i++)); do
	ip=$(vm_ip "$i")
	if ! mac=$(ssh $SSH_OPTS "$SSH_USER@$ip" "cat /sys/class/net/$GUEST_NIC/address"); then
		log_error "Could not read ${vm_names[$i]}'s data NIC MAC"
		cleanup
		exit 1
	fi
	if [[ ! "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
		log_error "Invalid data NIC MAC from ${vm_names[$i]}: $mac"
		cleanup
		exit 1
	fi
	if [[ -n "${seen_guest_macs[$mac]:-}" ]]; then
		log_error "Duplicate data NIC MAC $mac on ${seen_guest_macs[$mac]} and ${vm_names[$i]}"
		cleanup
		exit 1
	fi
	seen_guest_macs[$mac]="${vm_names[$i]}"
	echo "  ${vm_names[$i]}: $mac"
done

# --- Step 11: Sync git repo on all VMs ---
echo ""
log_info "Step 11: Syncing git repo (${GIT_BRANCH})..."
failed=0
for ((i = 0; i < NUM_VMS; i++)); do
	ip=$(vm_ip "$i")
	if ! sync_git_repo "$ip" "${vm_names[$i]}"; then
		failed=$((failed + 1))
	fi
done

if [[ $failed -gt 0 ]]; then
	log_error "${failed} VM(s) failed git sync, aborting"
	cleanup
	exit 1
fi


# --- Step 12: Setup host environment ---
echo ""
log_info "Step 12: Setting up host environment..."
if ! setup_host; then
	log_error "Host setup failed, aborting"
	cleanup
	exit 1
fi

# Guest runners and wrappers come from the Git sync in Step 11.
TELEMETRY_DIR=""
TELEMETRY_HELPER="${HOST_FandS_ABS}/multi_vms/record_sweep.py"
if [[ "$RECORD_COUNTERS" == on ]]; then
	pf_interfaces=(/sys/bus/pci/devices/"$HOST_PF_BDF"/net/*)
	if [[ ${#pf_interfaces[@]} -ne 1 || ! -e "${pf_interfaces[0]}" ]]; then
		log_error "Expected one host PF interface for $HOST_PF_BDF"
		cleanup
		exit 1
	fi
	TELEMETRY_DIR="${HOST_RESULTS_DIR%/}/${EXP_NAME}/counters"
	mkdir -p "$TELEMETRY_DIR"
	# Guest-to-host barrier SSH uses the invoking user's account, also under sudo.
	if [[ $EUID -eq 0 ]]; then
		chown "$HOST_SSH_UNAME" "$TELEMETRY_DIR"
	fi
	python3 "$TELEMETRY_HELPER" coordinate \
		--output "$TELEMETRY_DIR" --experiment "$EXP_NAME" --direction "$traffic_direction" \
		--viommu "$GUEST_VIOMMU" --num-vms "$NUM_VMS" --total-cores "$NUM_TOTAL_CORES" \
		--active-cores "$NUM_ACTIVE_CORES" --flows "$NUM_FLOWS" \
		--duration "$MEASUREMENT_DURATION" --interval "$COUNTER_INTERVAL" \
		--host-interface "${pf_interfaces[0]##*/}" \
		--peer-interface "$CLIENT_INTF" --peer-ip "$CLIENT_IP" --peer-ssh "$SSH_CLIENT_CMD" \
		--guest-interface "$GUEST_NIC" --guest-ssh "ssh $SSH_OPTS" \
		--guest-user "$SSH_USER" --guest-ip-base "$IP_BASE" --guest-data-ip-base "192.168.101.11" \
		--pcm-bin "$PCM_IIO_BIN" --pcm-dir "$PCM_IIO_DIR" \
		>"$TELEMETRY_DIR/coordinator.log" 2>&1 &
	counter_pid=$!
	for ((attempt = 0; attempt < 120; attempt++)); do
		[[ -f "$TELEMETRY_DIR/armed.json" ]] && break
		if ! kill -0 "$counter_pid" 2>/dev/null; then
			log_error "Counter preflight failed: $TELEMETRY_DIR/coordinator.log"
			cleanup
			exit 1
		fi
		sleep 1
	done
	if [[ ! -f "$TELEMETRY_DIR/armed.json" ]]; then
		log_error "Counter preflight timed out: $TELEMETRY_DIR/coordinator.log"
		cleanup
		exit 1
	fi
	log_info "Counter recording armed: $TELEMETRY_DIR"
fi

# --- Step 13: Run experiment on all VMs simultaneously ---
echo ""
log_info "Step 13: Launching experiments on all VMs..."
echo "  Script:    ${VM_SCRIPT}"
echo "  Total Cores:  ${NUM_TOTAL_CORES}"
echo "  Active Cores: ${NUM_ACTIVE_CORES}"
echo "  Flows:     ${NUM_FLOWS}"
echo "  Exp name:  ${EXP_NAME}"
echo ""

ssh_pids=()
for ((i = 0; i < NUM_VMS; i++)); do
	ip=$(vm_ip "$i")
	name="${vm_names[$i]}"

	# VM0 starts the single host recorder after its guest warmup. Other VMs
	# only start their own guest recorder, avoiding duplicate host samples.
	perf_guest=0
	perf_host=0
	if [[ "$PERF_TRACING" == all || ( "$PERF_TRACING" == vm0 && "$i" -eq 0 ) ]]; then
		perf_guest=1
	fi
	if [[ "$PERF_TRACING" != off && "$i" -eq 0 ]]; then
		perf_host=1
	fi

	vm_cmd="${VM_SCRIPT} --vm-name ${name} --num-cores ${NUM_ACTIVE_CORES} --num-flows ${NUM_FLOWS} \
		--exp-name ${EXP_NAME}-${name} \
		--host-ip ${HOST_IP} --host-ssh-uname ${HOST_SSH_UNAME} \
		--host-home ${HOST_HOME} --host-results-dir ${HOST_RESULTS_DIR} \
		--perf-tracing ${perf_guest} --perf-host-tracing ${perf_host} --duration ${MEASUREMENT_DURATION}"
	if [[ "$RECORD_COUNTERS" == on ]]; then
		printf -v counter_args ' --telemetry-dir %q --telemetry-helper %q' "$TELEMETRY_DIR" "$TELEMETRY_HELPER"
		vm_cmd+="$counter_args"
	fi
	ssh $SSH_OPTS "$SSH_USER@$ip" "$vm_cmd" &>"${name}_experiment.log" &
	ssh_pids+=($!)
	echo "  Launched on ${name} (${ip}), log -> ${name}_experiment.log"
done

echo ""
log_info "All experiments launched. Waiting for completion..."

any_failed=false
for ((i = 0; i < NUM_VMS; i++)); do
	name="${vm_names[$i]}"
	rc=0
	wait "${ssh_pids[$i]}" || rc=$?
	if [[ $rc -eq 0 ]]; then
		echo "  ${name}: finished (exit 0)"
	else
		echo "  ${name}: FAILED (exit $rc)"
		any_failed=true
	fi
done

# Preserve partial evidence and report counter failures before destroying guests.
if [[ -n "$counter_pid" ]]; then
	if ! wait "$counter_pid"; then
		log_error "Counter recording FAILED; see $TELEMETRY_DIR/coordinator.log"
		any_failed=true
	fi
	counter_pid=""
fi

# --- Step 14: Cleanup ---
echo ""
log_info "Step 14: Cleanup..."
cleanup

if [[ "$any_failed" == true ]]; then
	append_counter_summary
	echo ""
	log_info "=== Experiment finished with ERRORS (check *_experiment.log files) ==="
	exit 1
fi

# --- Step 16: Aggregate results from all VMs ---
echo ""
log_info "Step 16: Aggregating results from all VMs..."
REPORT_SCRIPT="${HOST_FandS_ABS}/scripts/many-vm-report-tput-metrics.py"
SUMMARY_DIR="${HOST_RESULTS_DIR}/${EXP_NAME}"

mkdir -p "$SUMMARY_DIR"
cd "${HOST_FandS_ABS}/scripts" || true
report_rc=0
python3 "$REPORT_SCRIPT" "$EXP_NAME" tput,cpu "$NUM_VMS" | tee "$SUMMARY_DIR/summary.txt" || report_rc=$?
append_counter_summary
cd "$ORIG_DIR"
if [[ "$report_rc" -ne 0 ]]; then
	log_error "Throughput report failed (exit $report_rc); counter summary retained"
	exit "$report_rc"
fi

log_info "=== Experiment finished successfully ==="
exit 0
