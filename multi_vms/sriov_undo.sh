#!/bin/bash

PF_BDF="0000:98:00.0"
PF_SYSFS="/sys/bus/pci/devices/$PF_BDF"

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

# Destroy VFS
echo 0 > "$PF_SYSFS/sriov_numvfs"
devlink dev eswitch set "pci/$PF_BDF" mode legacy

# Rebind physical function for passthrough
# echo "0000:98:00.0" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
# echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:98:00.0/driver_override
# echo "0000:98:00.0" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind

