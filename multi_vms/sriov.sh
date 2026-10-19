#!/bin/bash

set -euo pipefail

PF_BDF="0000:98:00.0"
NUM_VFS="${1:?Usage: $0 <num_vfs>}"
PF_SYSFS="/sys/bus/pci/devices/$PF_BDF"

log_info()  { echo "[INFO]  $1"; }
log_warn()  { echo "[WARN]  $1"; }
log_error() { echo "[ERROR] $1"; }

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

get_drv() {
    local d="/sys/bus/pci/devices/$1/driver"
    if [[ -L "$d" ]]; then
        basename "$(readlink "$d")"
    else
        echo "none"
    fi
}

modprobe -q mlx5_core || true
pf_drv=$(get_drv "$PF_BDF")
echo "PF driver: $pf_drv"
 
if [[ "$pf_drv" != "mlx5_core" ]]; then
    if [[ "$pf_drv" != "none" ]]; then
        echo "$PF_BDF" > "/sys/bus/pci/drivers/$pf_drv/unbind"
    fi
    echo "mlx5_core" > "$PF_SYSFS/driver_override"
    echo "$PF_BDF" > /sys/bus/pci/drivers_probe
    echo "" > "$PF_SYSFS/driver_override"
    echo "PF bound to mlx5_core"
fi

modprobe -q vfio-pci
echo 1 | sudo tee /sys/module/vfio_pci/parameters/enable_sriov

echo 0 > "$PF_SYSFS/sriov_numvfs"
devlink dev eswitch set "pci/$PF_BDF" mode legacy
echo "$NUM_VFS" > "$PF_SYSFS/sriov_numvfs"
echo "Created $NUM_VFS VFs"

pf_netdevs=("$PF_SYSFS"/net/*)
if [[ ${#pf_netdevs[@]} -ne 1 || ! -e "${pf_netdevs[0]}" ]]; then
    log_error "Expected one PF network interface for $PF_BDF"
    exit 1
fi
pf_netdev=${pf_netdevs[0]##*/}

for i in $(seq 0 $((NUM_VFS - 1))); do
    # Give each VF a permanent address before passthrough. Cloned guests can
    # otherwise derive the same persistent MAC from their shared machine-id.
    printf -v vf_mac '02:00:00:98:%02x:%02x' "$((i / 256))" "$((i % 256))"
    ip link set dev "$pf_netdev" vf "$i" mac "$vf_mac"
    vf_bdf=$(basename "$(readlink -f "$PF_SYSFS/virtfn${i}")")
    vf_drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$vf_bdf/driver")" 2>/dev/null || echo "none")
    [[ "$vf_drv" != "none" ]] && echo "$vf_bdf" > "/sys/bus/pci/drivers/$vf_drv/unbind"
    echo "vfio-pci" > "/sys/bus/pci/devices/$vf_bdf/driver_override"
    echo "$vf_bdf" > /sys/bus/pci/drivers_probe
    echo "" > "/sys/bus/pci/devices/$vf_bdf/driver_override"
    grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$vf_bdf/iommu_group")")
    echo "VF $((i+1)): $vf_bdf  mac=$vf_mac  iommu_group=$grp"
done
