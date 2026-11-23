#!/bin/bash
# Ensure we are in the scripts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Assuming the script is in scripts/sosp24-experiments/
# We want to go to scripts/
cd "$SCRIPT_DIR/.." || exit 1
echo "Running flow experiment... this may take a few minutes"

# Add dry run flag
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --dry)
        DRY_RUN=1
        shift # past argument
        ;;
        *)
        shift # past unknown argument
        ;;
    esac
done

GUEST_INTF="enp0s1np0"
GUEST_IP="192.168.101.11"
GUEST_NIC_BUS="0x0"
GUEST_HOME="/home/schai"
# for some reason, public domain name doesn't work
HOST_IP="192.17.101.97"
HOST_UNAME="lbalara"
HOST_HOME="/home/lbalara"
CLIENT_HOME="/home/siyuanc3"
CLIENT_INTF="ens1006np0"
CLIENT_IP="192.168.101.3"
CLIENT_SSH_UNAME="siyuanc3"
CLIENT_SSH_HOST="nexus03.csl.illinois.edu" # Public IP or hostname for SSH "genie12.cs.cornell.edu"
CLIENT_SSH_PASSWORD="saksham"
CLIENT_USE_PASS_AUTH=0 # 1 to use password, 0 to use identity file
CLIENT_SSH_IDENTITY_FILE="/home/schai/.ssh/id_rsa"

function detect_virt_tech() {
    local virsh_out=$(ssh -i "$CLIENT_SSH_IDENTITY_FILE" "${HOST_UNAME}@${HOST_IP}" 'bash -l -c "virsh list --all"')
    local running_vms=$(echo "$virsh_out" | grep running | awk '{print $2}')

    if [ -z "$running_vms" ]; then
        echo "ERROR: No VMs are currently running" >&2
        return 1
    fi

    echo "Found running VMs: $running_vms" >&2

    local detected_tech=""
    if [[ "$running_vms" == *"nested"* ]]; then
        detected_tech="nested"
    elif [[ "$running_vms" == *"shadow"* ]]; then
        detected_tech="shadow"
    elif [[ "$running_vms" == *"off"* ]]; then
        detected_tech="off"
    else
        echo "ERROR: Could not detect virtualization technology from VM name: $running_vms" >&2
        echo "Expected VM name to contain 'nested', 'shadow', or 'off'" >&2
        return 1
    fi

    echo "$detected_tech"
    return 0
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

if [ "$CLIENT_USE_PASS_AUTH" -eq 1 ]; then
	SSH_CLIENT_CMD="sshpass -p $CLIENT_SSH_PASSWORD ssh ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
else
	SSH_CLIENT_CMD="ssh -i $CLIENT_SSH_IDENTITY_FILE ${CLIENT_SSH_UNAME}@${CLIENT_SSH_HOST}"
fi

guest_cmdline=$(cat /proc/cmdline)
guest_iommu_config=$(parse_iommu_mode "$guest_cmdline")
host_cmdline=$(ssh -i "$CLIENT_SSH_IDENTITY_FILE" "${HOST_UNAME}@${HOST_IP}" 'cat /proc/cmdline')
host_iommu_config=$(parse_iommu_mode "$host_cmdline")

virt_tech=$(detect_virt_tech)
if [ $? -ne 0 ]; then
    echo "Failed to detect virtualization technology"
    echo "Running in baremetal, so probably not a problem"
    exit 1
fi

# Client SMT off
$SSH_CLIENT_CMD "echo off | sudo tee /sys/devices/system/cpu/smt/control"

iommu_config="host-${host_iommu_config}-guest-${guest_iommu_config}-$virt_tech"
echo "iommu_config: $iommu_config"

client_cores="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31"
server_cores="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31"

timestamp=$(date '+%Y-%m-%d-%H-%M-%S')

N_RUNS=5
Z_LIST_DLF="1"

for socket_buf in 1; do
    for ring_buffer in 512; do
        for i in 1; do
            # for num_cores in 1 4 8 12 16 20 24; do
            for num_cores in 1 4 8 12 16 20 24 28 32; do
                client_cores_mask=($(echo $client_cores | tr ',' '\n' | head -n $num_cores | tr '\n' ','))
                server_cores_mask=($(echo $server_cores | tr ',' '\n' | head -n $num_cores | tr '\n' ','))
                
                n_val=$(( i * num_cores ))
                # echo $n_val
                format_i=$(printf "%02d\n" $n_val)

                # Check for leader_max_flushes to determine mode
                if sudo test -f "/sys/kernel/debug/iommu/leader_max_flushes"; then
                    # DLF Mode
                    z_list="$Z_LIST_DLF"
                else
                    # Standard Mode
                    z_list=""
                fi

                run_list="$z_list"
                if [ -z "$run_list" ]; then run_list="default"; fi

                for z in $run_list; do
                    if [ "$z" != "default" ]; then
                        # DLF Setup
                        exp_name="${timestamp}-$(uname -r)-RX-flow${format_i}-${iommu_config}-${num_cores}cores-ringbuf${ring_buffer}-sockbuf${socket_buf}-zval${z}"
                        echo $z | sudo tee /sys/kernel/debug/iommu/leader_max_flushes
                        echo "Leader Max Flushes: $(sudo cat /sys/kernel/debug/iommu/leader_max_flushes)"
                    else
                        # Standard Setup
                        exp_name="${timestamp}-$(uname -r)-RX-flow${format_i}-${iommu_config}-${num_cores}cores-ringbuf${ring_buffer}-sockbuf${socket_buf}"
                    fi

                    echo $exp_name
                    echo "Running $exp_name" "N_RUN=$N_RUNS"

                    if [ "$DRY_RUN" -eq 1 ]; then
                        continue
                    fi

                    sudo mkdir -p ../utils/reports/$exp_name
                    sudo bash vm-run-dctcp-tput-experiment.sh \
                        --guest-home "$GUEST_HOME" --guest-ip "$GUEST_IP" --guest-intf "$GUEST_INTF" --guest-bus "$GUEST_NIC_BUS" -n "$n_val" -c $server_cores_mask \
                        --client-home "$CLIENT_HOME" --client-ip "$CLIENT_IP" --client-intf "$CLIENT_INTF" -N "$n_val" -C $client_cores_mask \
                        --host-home "$HOST_HOME" --host-ip "$HOST_IP" \
                        --client-ssh-name "$CLIENT_SSH_UNAME" --client-ssh-pass "$CLIENT_SSH_PASSWORD" --client-ssh-host "$CLIENT_SSH_HOST" --client-ssh-use-pass "$CLIENT_USE_PASS_AUTH" --client-ssh-ifile "$CLIENT_SSH_IDENTITY_FILE" \
                        -e "$exp_name" -m 4000 -r $ring_buffer -b "400g" -d 1\
                        --socket-buf $socket_buf --mlc-cores 'none' --runs $N_RUNS 2>&1 | sudo tee ../utils/reports/$exp_name/experiment.log

                    python3 report-tput-metrics.py $exp_name tput,drops,acks,iommu,cpu | sudo tee ../utils/reports/$exp_name/summary.txt
                    echo $PWD
                    cd ../utils/reports/$exp_name

                    cd -
                    sudo chmod +666 -R ../utils/reports/$exp_name
                done
            done
        done
    done
done

