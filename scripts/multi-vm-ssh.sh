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
