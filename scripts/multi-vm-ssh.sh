#!/bin/bash
# Reuse each guest's authenticated connections throughout setup, logging and
# result copies. The runner uses sudo, so the outer wrapper uses the same root
# client and control sockets; otherwise it would open a fresh connection again.
multi_vm_transport() {
	local tool=$1
	shift
	local control_dir="${MULTI_VM_SSH_CONTROL_DIR:-/run/viommu-ssh}"
	local options=(-o ControlMaster=auto -o ControlPersist=300
		-o "ControlPath=$control_dir/%C" -o ConnectTimeout=10
		-o ServerAliveInterval=15 -o ServerAliveCountMax=2)
	if [[ $EUID -eq 0 ]]; then
		command mkdir -p -m 700 "$control_dir" || return
		command "$tool" "${options[@]}" "$@"
	else
		command sudo -n mkdir -p -m 700 "$control_dir" || return
		command sudo -n "$tool" "${options[@]}" "$@"
	fi
}

ssh() { multi_vm_transport ssh "$@"; }
scp() { multi_vm_transport scp "$@"; }

# Workload synchronization with run_vms.sh. This helper only signals readiness
# and waits; the host runner owns phase transitions and failure propagation.
multi_vm_wait_for_signal() {
    local phase=$1 signal_command attempt rc
    [[ -n "${SYNC_DIR:-}" ]] || { echo "Missing --sync-dir" >&2; return 1; }
    case "$phase" in warmup|measure) ;; *) echo "Unknown VM phase: $phase" >&2; return 1 ;; esac
    printf -v signal_command 'set -e; touch %q; attempt=0; while [ "$attempt" -lt 3000 ]; do if [ -f %q ]; then exit 1; fi; if [ -f %q ]; then exit 0; fi; sleep 0.2; attempt=$((attempt+1)); done; echo "Timed out waiting for host phase signal" >&2; exit 1' \
        "$SYNC_DIR/$phase-ready-vm$VM_ID" "$SYNC_DIR/failed" "$SYNC_DIR/$phase.start"
    for ((attempt=1;attempt<=8;attempt++)); do
        rc=0
        $SSH_HOST_CMD "$signal_command" || rc=$?
        [[ "$rc" -eq 0 ]] && return 0
        [[ "$rc" -eq 255 && "$attempt" -lt 8 ]] || return "$rc"
        sleep "$((attempt + VM_ID % 3))"
    done
}

# Local traffic launchers and client SSH commands must remain alive until cleanup.
multi_vm_check_traffic() {
    local pid rc
    for pid in "${traffic_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rc=0
            wait "$pid" || rc=$?
            echo "Traffic process $pid exited before experiment cleanup (exit $rc)" >&2
            return 1
        fi
    done
}
