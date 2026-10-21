#!/bin/bash

# Treat unset variables as an error when substituting.
set -u

#-------------------------------------------------------------------------------
# CONFIGURATION AND PATHS
#-------------------------------------------------------------------------------
SCRIPT_NAME="many-vm-run-dctcp-tput-experiment"
INIT_PORT=3000
MLC_DURATION_S=100
GUEST_MLC_DIR_REL="mlc/Linux"

FTRACE_BUFFER_SIZE_KB=20000
FTRACE_OVERWRITE_ON_FULL=0 # 0=no overwrite (tracing stops when full), 1=overwrite
PERF_TRACING_ENABLED=0
PERF_TRACING_HOST_ENABLED=0
TELEMETRY_DIR=""
TELEMETRY_HELPER=""

# --- Base Directory Paths (Relative to respective home directories) ---
SCRIPT_DIR=$(dirname "$0")
GUEST_FandS_REL=$(basename $(realpath "$SCRIPT_DIR/../"))
GUEST_PERF_REL="linux-6.12.9/tools/perf/perf"
CLIENT_FandS_REL="Fast-and-Safe-IO-Memory-Protection"

HOST_PERF="/home/lbalara/viommu/linux-6.12.9/tools/perf/perf"

# --- F and S Directory Paths (Relative to respective F and S directories) ---
GUEST_SETUP_DIR_REL="utils"
GUEST_EXP_DIR_REL="utils/tcp"
CLIENT_SETUP_DIR_REL="utils"
CLIENT_EXP_DIR_REL="utils/tcp"

EBPF_GUEST_LOADER_REL="$GUEST_FandS_REL/tracing/guest_loader"
EBPF_HOST_LOADER="/home/lbalara/viommu/ManyVM-FandS/tracing/server_loader" #hardcoded for speed
HOST_SETUP_DIR="/home/lbalara/viommu/ManyVM-FandS/utils"

# --- Remote Access (SSH) Configuration ---
HOST_SSH_UNAME="lbalara"
HOST_SSH_PASSWORD=""
HOST_SSH_IDENTITY_FILE="/home/schai/.ssh/id_rsa"
HOST_USE_PASS_AUTH=0

#-------------------------------------------------------------------------------
# DEFAULT CONFIGURATION AND PATHS EDITABLE BY COMMAND LINE
#-------------------------------------------------------------------------------
# --- Experiment Setup ---
EXP_NAME="tput-test"
VM_ID="0"  # Unique per-VM identifier for session names, ports, file prefixes
NUM_RUNS=1 # Always 1 for multi-VM; coordination handled by host
CORE_DURATION_S=20 # Duration for the main workload
MLC_CORES="none"
EBPF_TRACING_ENABLED=0
EBPF_TRACING_HOST_ENABLED=0
COLLECT_MEM_STATS=0

# --- Guest (Server) Machine Configuration ---
GUEST_HOME="/home/schai"
GUEST_IP="10.10.1.50"
GUEST_INTF="enp8s0np1"
GUEST_NIC_BUS="0x08"
GUEST_NUM_SERVERS=5
GUEST_CPU_MASK="0,1,2,3,4"

# --- Client Machine Configuration ---
CLIENT_HOME="/users/Leshna/"
CLIENT_IP="10.10.1.2"
CLIENT_INTF="eno12409np1"
CLIENT_NUM_CLIENTS=5
CLIENT_CPU_MASK="0,4,8,12,16"
CLIENT_BANDWIDTH="100g"

# --- Host Machine Configuration ---
HOST_HOME="/users/Leshna"
HOST_IP="192.168.122.1"

# --- Network & System Parameters ---
MTU=4000
DDIO_ENABLED=1
RING_BUFFER_SIZE=256
TCP_SOCKET_BUF_MB=1

# --- Remote Access (SSH) Configuration ---
CLIENT_SSH_UNAME="saksham"
CLIENT_SSH_HOST="genie12.cs.cornell.edu"
CLIENT_SSH_PASSWORD="saksham"
CLIENT_USE_PASS_AUTH=1
CLIENT_SSH_IDENTITY_FILE="/home/schai/.ssh/id_ed25519"

#-------------------------------------------------------------------------------
# Help/usage
#-------------------------------------------------------------------------------
help() {
	echo "Usage: $SCRIPT_NAME"
	echo "Server/Guest Configuration:"
	echo "    [ --guest-home <path> (Guest home directory) ]"
	echo "    [ --guest-ip <ip> (IP address of the server/guest) ]"
	echo "    [ --guest-intf <name> (Network interface for the server/guest) ]"
  echo "    [ --guest-bus <bus> (NIC’s PCI bus number) ]"
	echo "    [ -n | --guest-num <count> (Number of server instances; default: 5) ]"
	echo "    [ -c | --guest-cpu-mask <csv> (Guest CPU mask, comma-separated; default: 0,1,2,3,4) ]"
	echo
	echo "Client Configuration:"
	echo "    [ --client-home <path> (Client home directory) ]"
	echo "    [ --client-ip <ip> (IP address of the client) ]"
	echo "    [ --client-intf <name> (Interface name for the client) ]"
	echo "    [ -N | --client-num <count> (Number of client instances; default: 5) ]"
	echo "    [ -C | --client-cpu-mask <csv> (Client CPU mask, comma-separated; default: 0,4,8,12,16) ]"
	echo
	echo "Host Configuration:"
	echo "    [ --host-home <path> (Host home directory) ]"
	echo "    [ --host-ip <ip> (IP address of the host) ]"
	echo "    [ --host-ssh-name <user> (SSH user on host) ]"
	echo "    [ --perf-tracing <0|1> (Record this guest; default: 0) ]"
	echo "    [ --perf-host-tracing <0|1> (VM0 only: record host; default: 0) ]"
	echo
	echo "Experiment Parameters:"
	echo "    [ --vm-id <id> (Unique VM identifier for session names/ports; default: 0) ]"
	echo "    [ -e | --exp-name <name> (Experiment name for output directories; default: tput-test) ]"
	echo "    [ -m | --mtu <size> (MTU size; default: 4000) ]"
	echo "    [ -d | --ddio <0|1> (DDIO enabled; default: 1) ]"
	echo "    [ -b | --bandwidth <rate> (Client bandwidth; default: 100g) ]"
	echo "    [ -r | --ring-buffer <size> (NIC Rx ring buffer size; default: 256) ]"
	echo "    [ --mlc-cores <csv|'none'> (MLC cores; default: none) ]"
	echo "    [ --socket-buf <MB> (TCP socket buffer size in MB; default: 1) ]"
	echo "    [ --dur <seconds> (Core experiment duration in seconds; default: 20) ]"
	echo "    [ --runs <count> (Number of experiment repetitions; forced to 1 for multi-VM) ]"
	echo "    [ --ebpf-tracing <0|1> (Enable eBPF tracing; default: 0) ]"
	echo "    [ --mem-stats <0|1> (Enable collect-mem-stats.sh; default: 0) ]"
	echo
	echo "Client SSH Configuration:"
	echo "    [ --client-ssh-name <uname> ]"
	echo "    [ --client-ssh-host <ip> ]"
	echo "    [ --client-ssh-use-pass <0|1> ]"
	echo "    [ --client-ssh-pass <pass> ]"
	echo "    [ --client-ssh-ifile <path> ]"
	echo
	echo "    [ -h | --help ]"
	exit 2
}


#-------------------------------------------------------------------------------
# COMMAND-LINE ARGUMENT PARSING
#-------------------------------------------------------------------------------
SHORT_OPTS="n:c:N:C:e:m:d:b:r:h"
LONG_OPTS="guest-home:,guest-ip:,guest-intf:,guest-bus:,guest-num:,guest-cpu-mask:,\
client-home:,client-ip:,client-intf:,client-num:,client-cpu-mask:,\
host-home:,host-ip:,host-ssh-name:,perf-tracing:,perf-host-tracing:,telemetry-dir:,telemetry-helper:,\
vm-id:,exp-name:,mtu:,ddio:,bandwidth:,ring-buffer:,mlc-cores:,socket-buf:,dur:,runs:,ebpf-tracing:,mem-stats:,\
client-ssh-name:,client-ssh-host:,client-ssh-use-pass:,client-ssh-pass:,client-ssh-ifile:,help"

PARSED_OPTS=$(getopt -a -n "$SCRIPT_NAME" --options "$SHORT_OPTS" --longoptions "$LONG_OPTS" -- "$@")
VALID_ARGUMENTS=$#
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
	help
fi
eval set -- "$PARSED_OPTS"

while :; do
	case "$1" in
	--guest-home) GUEST_HOME="$2"; shift 2 ;;
	--guest-ip) GUEST_IP="$2"; shift 2 ;;
	--guest-intf) GUEST_INTF="$2"; shift 2 ;;
	--guest-bus) GUEST_NIC_BUS="$2"; shift 2 ;;
	-n | --guest-num) GUEST_NUM_SERVERS="$2"; shift 2 ;;
	-c | --guest-cpu-mask) GUEST_CPU_MASK="$2"; shift 2 ;;
	--client-home) CLIENT_HOME="$2"; shift 2 ;;
	--client-ip) CLIENT_IP="$2"; shift 2 ;;
	--client-intf) CLIENT_INTF="$2"; shift 2 ;;
	-N | --client-num) CLIENT_NUM_CLIENTS="$2"; shift 2 ;;
	-C | --client-cpu-mask) CLIENT_CPU_MASK="$2"; shift 2 ;;
	--host-home) HOST_HOME="$2"; shift 2 ;;
	--host-ip) HOST_IP="$2"; shift 2 ;;
	--host-ssh-name) HOST_SSH_UNAME="$2"; shift 2 ;;
	--perf-tracing) PERF_TRACING_ENABLED="$2"; shift 2 ;;
	--perf-host-tracing) PERF_TRACING_HOST_ENABLED="$2"; shift 2 ;;
	--telemetry-dir) TELEMETRY_DIR="$2"; shift 2 ;;
	--telemetry-helper) TELEMETRY_HELPER="$2"; shift 2 ;;
	--vm-id) VM_ID="$2"; shift 2 ;;
	-e | --exp-name) EXP_NAME="$2"; shift 2 ;;
	-m | --mtu) MTU="$2"; shift 2 ;;
	-d | --ddio) DDIO_ENABLED="$2"; shift 2 ;;
	-b | --bandwidth) CLIENT_BANDWIDTH="$2"; shift 2 ;;
	-r | --ring-buffer) RING_BUFFER_SIZE="$2"; shift 2 ;;
	--mlc-cores) MLC_CORES="$2"; shift 2 ;;
	--socket-buf) TCP_SOCKET_BUF_MB="$2"; shift 2 ;;
	--dur) CORE_DURATION_S="$2"; shift 2 ;;
	--runs) NUM_RUNS="$2"; shift 2 ;;
	--ebpf-tracing) EBPF_TRACING_ENABLED="$2"; shift 2 ;;
	--mem-stats) COLLECT_MEM_STATS="$2"; shift 2 ;;
	--client-ssh-name) CLIENT_SSH_UNAME="$2"; shift 2 ;;
	--client-ssh-host) CLIENT_SSH_HOST="$2"; shift 2 ;;
	--client-ssh-use-pass) CLIENT_USE_PASS_AUTH="$2"; shift 2 ;;
	--client-ssh-pass) CLIENT_SSH_PASSWORD="$2"; shift 2 ;;
	--client-ssh-ifile) CLIENT_SSH_IDENTITY_FILE="$2"; shift 2 ;;
	-h | --help) help ;;
	--) shift; break ;;
	*) echo "Unexpected option: $1"; help ;;
	esac
done

# Force single run for multi-VM coordination
NUM_RUNS=1

# --- VM-specific naming for screen sessions and ports ---
# Each VM gets unique screen session names so cleanup doesn't kill other VMs.
# Port offset avoids any potential conflicts on the client side.
SCREEN_CLIENT_SESSION="client_session_vm${VM_ID}"
SCREEN_CLIENT_LOGGING="logging_session_client_vm${VM_ID}"
INIT_PORT=$((3000 + VM_ID * 100))

# Only trace on vm0
if [ "$VM_ID" -ne 0 ]; then
	PERF_TRACING_HOST_ENABLED=0
  EBPF_TRACING_HOST_ENABLED=0
	EBPF_TRACING_ENABLED=0 
fi

GUEST_SETUP_DIR="${GUEST_HOME}/${GUEST_FandS_REL}/${GUEST_SETUP_DIR_REL}"
GUEST_EXP_DIR="${GUEST_HOME}/${GUEST_FandS_REL}/${GUEST_EXP_DIR_REL}"
GUEST_MLC_DIR="${GUEST_HOME}/${GUEST_MLC_DIR_REL}"
GUEST_PERF="${GUEST_HOME}/${GUEST_PERF_REL}"
CLIENT_SETUP_DIR="${CLIENT_HOME}/${CLIENT_FandS_REL}/${CLIENT_SETUP_DIR_REL}"
CLIENT_EXP_DIR="${CLIENT_HOME}/${CLIENT_FandS_REL}/${CLIENT_EXP_DIR_REL}"
EBPF_GUEST_LOADER="${GUEST_HOME}/${EBPF_GUEST_LOADER_REL}"
PROFILING_LOGGING_DUR_S=$((CORE_DURATION_S))

if [ "$CLIENT_USE_PASS_AUTH" -eq 1 ]; then
	SSH_CLIENT_CMD="sshpass -p $CLIENT_SSH_PASSWORD ssh ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
else
	SSH_CLIENT_CMD="ssh -i $CLIENT_SSH_IDENTITY_FILE ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
fi

if [ "$HOST_USE_PASS_AUTH" -eq 1 ]; then
	SSH_HOST_CMD="sshpass -p $HOST_SSH_PASSWORD ssh ${HOST_SSH_UNAME}@${HOST_IP}"
else
	SSH_HOST_CMD="ssh -i $HOST_SSH_IDENTITY_FILE ${HOST_SSH_UNAME}@${HOST_IP}"
fi

#-------------------------------------------------------------------------------
# HELPER FUNCTIONS
#-------------------------------------------------------------------------------

# mem_pid=""
# cleanup_mem_stats() {
# 	if [ "$COLLECT_MEM_STATS" -eq 1 ] && [ -n "$mem_pid" ]; then
# 		log_info "Killing memory collection (PID $mem_pid)..."
# 		sudo kill "$mem_pid" 2>/dev/null || true
# 		sudo pkill -P "$mem_pid" 2>/dev/null || true
# 		sudo pkill -f "collect-mem-stats.sh" 2>/dev/null || true
# 		wait "$mem_pid" 2>/dev/null || true
# 		mem_pid=""
# 	fi
# }
# trap cleanup_mem_stats EXIT

log_info() {
	echo "[INFO-$(date +%Y-%m-%d-%H:%M:%S)] [vm${VM_ID}] [$EXP_NAME] $1"
}

log_error() {
	echo "[ERROR-$(date +%Y-%m-%d-%H:%M:%S)] [vm${VM_ID}] [$EXP_NAME] $1" >&2
}

progress_bar() {
	local duration_secs=$1
	local interval_secs=$2
	local elapsed_time_secs=0

	if [ "$duration_secs" -eq 0 ]; then
		printf "[==================================================] 100%% (0/0s)\n"
		return
	fi

	local progress_bar_width=50
	while [ "$elapsed_time_secs" -lt "$duration_secs" ]; do
		elapsed_time_secs=$((elapsed_time_secs + interval_secs))
		if [ "$elapsed_time_secs" -gt "$duration_secs" ]; then
			elapsed_time_secs=$duration_secs
		fi

		local progress_percent=$((elapsed_time_secs * 100 / duration_secs))
		local bar_filled_length=$((progress_percent * progress_bar_width / 100))

		local bar_visual=""
		for ((k = 0; k < bar_filled_length; k++)); do bar_visual+="="; done

		printf "[%-*s] %3d%% (%*ds/%ds)\r" "$progress_bar_width" "$bar_visual" "$progress_percent" \
			"${#duration_secs}" "$elapsed_time_secs" "$duration_secs"
		sleep "$interval_secs"
	done

	local full_bar_visual=""
	for ((k = 0; k < progress_bar_width; k++)); do full_bar_visual+="="; done
	printf "[%-*s] 100%% (%ds/%ds)\n" "$progress_bar_width" "$full_bar_visual" "$duration_secs" "$duration_secs"
}

# --- Guest-only pre-experiment setup (no host/client setup) ---
pre_exp_setup() {
	log_info "--- Starting Pre-experiment Setup (guest-only) ---"

	log_info "Disabling TX/RX pause on GUEST interface $GUEST_INTF"
	sudo ethtool --pause "$GUEST_INTF" tx off rx off

	log_info "--- Pre-experiment Setup Finished ---"
}

# --- Guest-only post-experiment cleanup (no host reset) ---
post_exp_cleanup() {
	log_info "--- Starting Post-experiment Cleanup (guest-only) ---"

	log_info "Resetting GUEST ftrace..."
	sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on'
	sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/options/overwrite'
	sudo sh -c 'echo 20000 > /sys/kernel/debug/tracing/buffer_size_kb'

	log_info "--- Post-experiment Cleanup Finished ---"
}

# --- Cleanup: guest processes and THIS VM's client sessions only ---
cleanup() {
	log_info "--- Starting Cleanup Phase ---"

	log_info "Killing local 'loaded_latency', 'iperf' processes..."
	sudo pkill -9 -f loaded_latency 2>/dev/null || true
	sudo pkill -9 -f iperf 2>/dev/null || true

	if [ "$PERF_TRACING_ENABLED" -eq 1 ]; then
		sudo pkill -SIGINT -f "$GUEST_PERF record" 2>/dev/null || true
		sleep 1
		sudo pkill -9 -f "$GUEST_PERF record" 2>/dev/null || true
	fi

	if [ "$PERF_TRACING_HOST_ENABLED" -eq 1 ]; then
		log_info "Killing remote 'perf record' on HOST ($HOST_IP)..."
		$SSH_HOST_CMD \
		    "sudo pkill -SIGINT -f '^$HOST_PERF record'; sleep 1; sudo pkill -9 -f '^$HOST_PERF record'" || true
	fi

	if [ "$EBPF_TRACING_ENABLED" -eq 1 ]; then
		log_info "Stopping guest eBPF tracers..."
		guest_loader_basename=$(basename "$EBPF_GUEST_LOADER")
		cd "$(dirname "$EBPF_GUEST_LOADER")" || { log_error "Failed to cd to $(dirname "$EBPF_GUEST_LOADER")"; }
		make clean 2>/dev/null || true
		make 2>/dev/null || true
		cd - > /dev/null
		sudo pkill -SIGINT -f "$guest_loader_basename" 2>/dev/null || true
		sudo pkill -9 -f "$guest_loader_basename" 2>/dev/null || true
	fi
	if [ "$EBPF_TRACING_HOST_ENABLED" -eq 1 ]; then
	    local host_loader_basename
      host_loader_basename=$(basename "$EBPF_HOST_LOADER")
      $SSH_HOST_CMD \
      "sudo pkill -SIGINT -f '$host_loader_basename'; sleep 5; sudo pkill -9 -f '$host_loader_basename'; screen -S ebpf_host_tracer -X quit || true"
  fi
	# sleep 5


	# Only kill THIS VM's screen sessions on the client (not other VMs')
	log_info "Terminating client screen sessions: $SCREEN_CLIENT_SESSION, $SCREEN_CLIENT_LOGGING"
	$SSH_CLIENT_CMD \
		"screen -S $SCREEN_CLIENT_SESSION -X quit" 2>/dev/null || true
	$SSH_CLIENT_CMD \
		"screen -S $SCREEN_CLIENT_LOGGING -X quit" 2>/dev/null || true

	# Only kill iperf instances talking to THIS VM's guest IP (not other VMs')
	$SSH_CLIENT_CMD \
		"sudo pkill -9 -f 'iperf.*${GUEST_IP}'" 2>/dev/null || true
	$SSH_CLIENT_CMD \
		'screen -wipe' 2>/dev/null || true

	log_info "Resetting GUEST network interface $GUEST_INTF..."
	sudo ip link set "$GUEST_INTF" down
	sleep 1
	sudo ip link set "$GUEST_INTF" up
	sleep 1
	log_info "--- Cleanup Phase Finished ---"
}

save_config_to_report_json() {
	local report_dir="${1:-$current_guest_reports_dir}"
	local config_file="$report_dir/config.json"

	local guest_cmdline=$(cat /proc/cmdline)
	local guest_kernel=$(uname -r)
	local client_cmdline=$($SSH_CLIENT_CMD 'cat /proc/cmdline')
	local client_kernel=$($SSH_CLIENT_CMD 'uname -r')

	cat > "$config_file" <<-EOF
	{
	  "timestamp": "$(date -Iseconds)",
	  "vm_id": "$VM_ID",
	  "test_params": {
	    "core_duration_s": "$CORE_DURATION_S",
	    "mtu": "$MTU",
	    "ddio_enabled": "$DDIO_ENABLED",
	    "ring_buffer_size": "$RING_BUFFER_SIZE",
	    "tcp_socket_buf_mb": "$TCP_SOCKET_BUF_MB",
	    "mlc_cores": "$MLC_CORES",
	    "init_port": "$INIT_PORT"
	  },
	  "guest": {
	    "ip": "$GUEST_IP",
	    "interface": "$GUEST_INTF",
	    "num_servers": "$GUEST_NUM_SERVERS",
	    "cpu_mask": "$GUEST_CPU_MASK",
	    "nic_bus": "$GUEST_NIC_BUS",
	    "kernel": "$guest_kernel",
	    "cmdline": "$guest_cmdline"
	  },
	  "client": {
	    "ip": "$CLIENT_IP",
	    "interface": "$CLIENT_INTF",
	    "num_clients": "$CLIENT_NUM_CLIENTS",
	    "cpu_mask": "$CLIENT_CPU_MASK",
	    "bandwidth": "$CLIENT_BANDWIDTH",
	    "kernel": "$client_kernel",
	    "cmdline": "$client_cmdline"
	  }
	}
	EOF
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------

pre_exp_setup

log_info "Starting experiment: $EXP_NAME"
log_info "VM_ID=$VM_ID, INIT_PORT=$INIT_PORT, single run (multi-VM mode)"

j=0  # Single run, index 0

log_info "############################################################"
log_info "### Starting Experiment: $EXP_NAME (vm${VM_ID})"
log_info "############################################################"

# --- Per-Run Directory and File Definitions ---
# Client report dir uses EXP_NAME which already has VM suffix from the caller.
# Files within the client dir also get vm prefix for safety in case the
# caller passes a shared EXP_NAME.
current_guest_reports_dir="${GUEST_SETUP_DIR}/reports/${EXP_NAME}-RUN-${j}"
host_reports_dir_remote="${HOST_SETUP_DIR}/reports/${EXP_NAME}-RUN-${j}"
client_reports_dir_remote="${CLIENT_SETUP_DIR}/reports/${EXP_NAME}-RUN-${j}"

perf_guest_data_file="${current_guest_reports_dir}/perf_guest_cpu.data"
perf_host_data_file_remote="${host_reports_dir_remote}/perf_host_cpu.data"
iova_ftrace_guest_output_file="${current_guest_reports_dir}/iova_ftrace_guest.txt"
ebpf_guest_stats="${current_guest_reports_dir}/ebpf_guest_stats.csv"
guest_server_app_log_file="${current_guest_reports_dir}/server_app.log"
guest_mlc_log_file="${current_guest_reports_dir}/mlc.log"
client_app_log_file="${current_guest_reports_dir}/client_app.log"
client_app_log_file_remote="${client_reports_dir_remote}/client_app.log"
ebpf_host_stats="${host_reports_dir_remote}/ebpf_host_stats.csv"

sudo mkdir -p "$current_guest_reports_dir"
# $SSH_HOST_CMD "mkdir -p '$host_reports_dir_remote'"

# --- Pre-run cleanup ---
cleanup

# --- Save config ---
save_config_to_report_json "$current_guest_reports_dir"

if [ "$COLLECT_MEM_STATS" -eq 1 ]; then
	log_info "Killing memory-intensive programs..."
	sudo killall -9 code node 2>/dev/null || true
	sudo killall -9 cursor cursor-server 2>/dev/null || true
	log_info "Flushing VM caches..."
	sudo sync
	echo 3 | sudo tee /proc/sys/vm/drop_caches
	log_info "Starting memory collection script..."
	bash collect-mem-stats.sh "$current_guest_reports_dir/memory_stats.csv" 0.5 &
	mem_pid=$!
	log_info "Memory collection started with PID $mem_pid"
fi

# --- Start MLC if configured ---
if [ "$MLC_CORES" != "none" ]; then
	log_info "Starting MLC on cores: $MLC_CORES; logs at $guest_mlc_log_file..."
	"$GUEST_MLC_DIR/mlc" --loaded_latency -T -d0 -e -k"$MLC_CORES" -j0 -b1g -t10000 -W2 &>"$guest_mlc_log_file" &
	log_info "Waiting for MLC to ramp up (30 seconds)..."
	progress_bar 30 5
else
	log_info "MLC not configured for this run."
fi

# --- Setup Guest (Server) Environment ---
log_info "Setting up GUEST server environment..."
cd "$GUEST_SETUP_DIR" || { log_error "Failed to cd to $GUEST_SETUP_DIR"; exit 1; }
sudo bash setup-envir.sh --dep "$GUEST_HOME" --intf "$GUEST_INTF" --ip "$GUEST_IP" -m "$MTU" -d "$DDIO_ENABLED" -r "$RING_BUFFER_SIZE" \
	--socket-buf "$TCP_SOCKET_BUF_MB" --hwpref 1 --rdma 0 --pfc 0 --ecn 1 --opt 1 --nic-bus "$GUEST_NIC_BUS"
cd - > /dev/null

# --- Start Guest (Server) Application ---
log_info "Starting GUEST server application; logs at $guest_server_app_log_file"
cd "$GUEST_EXP_DIR" || { log_error "Failed to cd to $GUEST_EXP_DIR"; exit 1; }
sudo bash run-netapp-tput.sh --mode server -n "$GUEST_NUM_SERVERS" -N "$CLIENT_NUM_CLIENTS" -o "${EXP_NAME}-RUN-${j}" \
	-p "$INIT_PORT" -c "$GUEST_CPU_MASK" &>"$guest_server_app_log_file" &
sleep 2 # Allow server app to initialize
cd - > /dev/null

# --- Start Clients (traffic generation only, no client setup-envir.sh) ---
# Uses VM-specific screen session name and port offset.
log_info "Starting CLIENT traffic on $CLIENT_SSH_HOST (screen: $SCREEN_CLIENT_SESSION, port: $INIT_PORT); logs at $client_app_log_file_remote..."
client_cmd="mkdir -p '$client_reports_dir_remote'; cd '$CLIENT_EXP_DIR'; sudo bash many-run-netapp-tput.sh --mode client --server-ip '$GUEST_IP' -n '$GUEST_NUM_SERVERS' -N '$CLIENT_NUM_CLIENTS' -o '${EXP_NAME}-RUN-${j}' -p '$INIT_PORT' -c '$CLIENT_CPU_MASK' -b '$CLIENT_BANDWIDTH' &>'$client_app_log_file_remote'; exec bash"
$SSH_CLIENT_CMD "screen -dmS $SCREEN_CLIENT_SESSION sudo bash -c \"$client_cmd\""

# --- Warmup Phase ---
log_info "Warming up experiment (120 seconds)..."
progress_bar 120 2

# Every VM keeps traffic running while waiting for the common capture window.
if [[ -n "$TELEMETRY_DIR" ]]; then
    log_info "Waiting at post-warmup counter recording barrier..."
    printf -v barrier_command 'python3 %q barrier %q %q' "$TELEMETRY_HELPER" "$TELEMETRY_DIR" "$VM_ID"
    if ! $SSH_HOST_CMD "$barrier_command"; then
        log_error "Counter recording barrier failed"
        cleanup
        exit 1
    fi
fi

if [ "$EBPF_TRACING_HOST_ENABLED" -eq 1 ]; then
    log_info "Starting HOST eBPF tracer on $HOST_IP..."
    host_loader_cmd="sudo taskset -c 33 $EBPF_HOST_LOADER -o $ebpf_host_stats"
    $SSH_HOST_CMD "screen -dmS ebpf_host_tracer sudo bash -c \"$host_loader_cmd\""
fi
# sleep 4 # Allow eBPF loaders to initialize

# --- Start Guest eBPF Tracers (if enabled) ---
if [ "$EBPF_TRACING_ENABLED" -eq 1 ]; then
	log_info "Starting GUEST eBPF tracer..."
	echo "current_time: $(date) $(date +%s)"
	sudo taskset -c 0 "$EBPF_GUEST_LOADER" -d "$CORE_DURATION_S" -o "$ebpf_guest_stats" &
fi

# Sleep outside so all VMs nearly in sync
# sleep 2

# --- Guest Ftrace Setup ---
log_info "Configuring GUEST ftrace (Buffer: ${FTRACE_BUFFER_SIZE_KB}KB, Overwrite: ${FTRACE_OVERWRITE_ON_FULL})..."
sudo sh -c "echo $FTRACE_BUFFER_SIZE_KB > /sys/kernel/debug/tracing/buffer_size_kb"
sudo sh -c "echo $FTRACE_OVERWRITE_ON_FULL > /sys/kernel/debug/tracing/options/overwrite"
sudo sh -c 'echo > /sys/kernel/debug/tracing/trace'
sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'
log_info "GUEST ftrace is ON."

# --- Start Main Profiling & Logging Phase ---
if [ "$PERF_TRACING_ENABLED" -eq 1 ]; then
    log_info "Starting GUEST perf record (CPU profiling)..."
    sudo "$GUEST_PERF" record -F 99 -a -g --call-graph dwarf -o "$perf_guest_data_file" -- sleep "$PROFILING_LOGGING_DUR_S" \
        >"${current_guest_reports_dir}/perf_guest_record.log" 2>&1 &
fi

if [ "$PERF_TRACING_HOST_ENABLED" -eq 1 ]; then
    log_info "Starting HOST perf record (CPU profiling) on $HOST_IP..."
    host_perf_cmd="mkdir -p '$host_reports_dir_remote'; '$HOST_PERF' record -F 99 -a -g --call-graph dwarf -o '$perf_host_data_file_remote' -- sleep '$PROFILING_LOGGING_DUR_S' >'$host_reports_dir_remote/perf_host_record.log' 2>&1"
    $SSH_HOST_CMD "screen -dmS perf_screen sudo bash -c \"$host_perf_cmd\""
fi

# --- Start Client-side Logging (VM-specific screen session + output dir) ---
log_info "Starting CLIENT-side logging (screen: $SCREEN_CLIENT_LOGGING)..."
client_logging_cmd="cd '$CLIENT_SETUP_DIR'; sudo bash record-host-metrics.sh \
    --dep '$CLIENT_HOME' -o '${EXP_NAME}-RUN-${j}' --dur '$CORE_DURATION_S' \
    --cpu-util 1 -c '$CLIENT_CPU_MASK' --retx 1 --tcplog 0 --bw 1 --flame 0 \
    --pcie 0 --membw 0 --iio 0 --pfc 0 --intf '$CLIENT_INTF' --type 0; exec bash"
$SSH_CLIENT_CMD "screen -dmS $SCREEN_CLIENT_LOGGING sudo bash -c \"$client_logging_cmd\""

# --- Start Guest-side (Server) Logging ---
log_info "Starting GUEST-side (server) logging..."
cd "$GUEST_SETUP_DIR" || { log_error "Failed to cd to $GUEST_SETUP_DIR"; exit 1; }
sudo bash record-host-metrics.sh --dep "$GUEST_HOME" -o "${EXP_NAME}-RUN-${j}" \
	--dur "$CORE_DURATION_S" --cpu-util 1 -c "$GUEST_CPU_MASK" --retx 1 --tcplog 0 --bw 1 --flame 0 \
	--pcie 0 --membw 0 --iio 0 --pfc 0 --intf "$GUEST_INTF" --type 0
cd - > /dev/null

log_info "Logging done."
log_info "Primary data collection phase on GUEST complete."

# --- Save Guest Ftrace Data ---
log_info "Stopping and saving GUEST ftrace data..."
sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on'
sudo cat /sys/kernel/debug/tracing/trace > "$iova_ftrace_guest_output_file"
sudo sh -c 'echo > /sys/kernel/debug/tracing/trace'
log_info "GUEST ftrace data saved to $iova_ftrace_guest_output_file"

head -n 2000 "$iova_ftrace_guest_output_file" > "${iova_ftrace_guest_output_file}.head2000"
tail -n 2000 "$iova_ftrace_guest_output_file" > "${iova_ftrace_guest_output_file}.tail2000"

# --- Stop Guest eBPF Tracers ---
if [ "$EBPF_TRACING_ENABLED" -eq 1 ]; then
	log_info "Stopping guest eBPF tracers..."
	echo "current_time: $(date) $(date +%s)"
	guest_loader_basename=$(basename "$EBPF_GUEST_LOADER")
	sudo pkill -SIGINT -f "$guest_loader_basename" 2>/dev/null && \
		log_info "SIGINT sent to GUEST eBPF loader." || \
		log_info "WARN: GUEST eBPF loader process not found or SIGINT failed."
fi
if [ "$EBPF_TRACING_HOST_ENABLED" -eq 1 ]; then
    host_loader_basename=$(basename "$EBPF_HOST_LOADER")
    $SSH_HOST_CMD "sudo pkill -SIGINT -f '$host_loader_basename'"
fi

# --- Transfer Report Files from Client ---
# Files on the client are in a dir named after EXP_NAME (already VM-specific).
log_info "Transferring report files from CLIENT..."
if [ "$CLIENT_USE_PASS_AUTH" -eq 1 ]; then
	sshpass -p "$CLIENT_SSH_PASSWORD" \
		scp "${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}:${client_reports_dir_remote}/retx.rpt" \
		"${current_guest_reports_dir}/client-retx.rpt" || log_error "Failed to SCP client retx.rpt"
	sshpass -p "$CLIENT_SSH_PASSWORD" \
		scp "${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}:${client_app_log_file_remote}" \
		"$client_app_log_file" || log_error "Failed to SCP client_app.log"
else
	scp -i "$CLIENT_SSH_IDENTITY_FILE" \
		"${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}:${client_reports_dir_remote}/retx.rpt" \
		"${current_guest_reports_dir}/client-retx.rpt" || log_error "Failed to SCP client retx.rpt"
	scp -i "$CLIENT_SSH_IDENTITY_FILE" \
		"${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}:${client_app_log_file_remote}" \
		"$client_app_log_file" || log_error "Failed to SCP client_app.log"
fi

log_info "Waiting for remote operations to settle ($((CORE_DURATION_S * 2))s)..."
progress_bar $((CORE_DURATION_S * 2)) 2

log_info "############################################################"
log_info "### Finished Experiment: $EXP_NAME (vm${VM_ID})"
log_info "############################################################"

# --- Post-run cleanup ---
cleanup

# Decode before the host destroys the guest, while its symbols are available.
if [ "$PERF_TRACING_ENABLED" -eq 1 ]; then
    sudo "$GUEST_PERF" script -i "$perf_guest_data_file" >"${current_guest_reports_dir}/perf_guest_cpu.stacks" \
        2>>"${current_guest_reports_dir}/perf_guest_record.log" || exit 1
fi
if [ "$PERF_TRACING_HOST_ENABLED" -eq 1 ]; then
    $SSH_HOST_CMD "sudo bash -c \"'$HOST_PERF' script -i '$perf_host_data_file_remote' >'$host_reports_dir_remote/perf_host_cpu.stacks' 2>>'$host_reports_dir_remote/perf_host_record.log' && chmod a+r '$perf_host_data_file_remote'\"" || exit 1
fi

post_exp_cleanup

cd "$SCRIPT_DIR" || exit 1

sleep 5

if [ "$MLC_CORES" != "none" ]; then
	log_info "MLC cores were used."
fi

log_info "Collecting and processing statistics..."
if [ "$MLC_CORES" = "none" ]; then
	sudo python3 many-vm-collect-tput-stats.py "$EXP_NAME" "$NUM_RUNS" 0
else
	sudo python3 many-vm-collect-tput-stats.py "$EXP_NAME" "$NUM_RUNS" 0
fi

log_info "Experiment $EXP_NAME (vm${VM_ID}) finished."