#!/bin/bash
SCRIPT_NAME="setup-envir"

#default values
MTU=4000
DDIO_ENABLED=1
INTF="eno12409np1"
IP="10.10.1.2"
NIC_BUS="0x6f"
TCP_OPTIMIZATION_ENABLED=1
TCP_SOCKET_BUF_MB=1
ECN_ENABLED=1
HWPREF_ENABLED=1
RDMA=0
PFC_ENABLED=0
RING_BUFFER_SIZE=1024
DEPS_DIR="/users/Leshna"
MLNX_DRIVER=1
ENDPOINT_ROLE=legacy

help()
{
    echo "Usage: $SCRIPT_NAME 
              [ --role guest|physical (optional; omitted preserves existing setup behavior) ]
              [ --dep (path to dependencies directories)]
              [ --intf (interface name, eg. ens2f0) ]
              [ --ip (ip address for the interface) ]
	            [ --nic-bus (NIC's PCI bus number) ]
              [ -m | --mtu (MTU size in bytes; default=4000 for TCP, 4096 for RDMA) ] 
              [ -d | --ddio (0/1/keep; keep preserves physical DDIO configuration) ]
              [ -r | --ring-buffer (size of Rx ring buffer. Note: opt must be set to change this)]
              [ --opt (enable TCP optimization TSO,GRO,aRFS) ]
              [ --socket-buf (TCP socket buffer size (in MB)) ]
              [ --ecn (Enable ECN support in Linux stack) ]
              [ --hwpref (Enable hardware prefetching) ]
              [ --rdma (=0/1, whether the setup is for running RDMA experiments (MTU offset will be different)) ]
              [ --pfc (=0/1, disable or enable PFC) ]
              [ -h | --help  ]"
    exit 2
}

SHORT=m:,d:,r:,h
LONG=role:,dep:,nic-bus:,mtu:,ddio:,ring-buffer:,intf:,ip:,opt:,socket-buf:,ecn:,hwpref:,rdma:,pfc:,help
PARSED_OPTS=$(getopt -a -n $SCRIPT_NAME --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$#
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$PARSED_OPTS"

while :;do
  case "$1" in
    --role) ENDPOINT_ROLE="$2"; shift 2 ;;
    --dep) DEPS_DIR="$2"; shift 2 ;;
    --nic-bus) NIC_BUS="$2"; shift 2 ;;
    -m | --mtu) MTU="$2"; shift 2 ;;
    -d | --ddio) DDIO_ENABLED="$2"; shift 2 ;;
    -r | --ring-buffer) RING_BUFFER_SIZE="$2"; shift 2 ;;
    --intf) INTF="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --opt) TCP_OPTIMIZATION_ENABLED="$2"; shift 2 ;;
    --socket-buf) TCP_SOCKET_BUF_MB="$2"; shift 2 ;;
    --ecn) ECN_ENABLED="$2"; shift 2 ;;
    --hwpref) HWPREF_ENABLED="$2"; shift 2 ;;
    --rdma) RDMA="$2"; shift 2 ;;
    --pfc) PFC_ENABLED="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

log_info() {
    echo "[INFO] - $1"
}

# Existing callers retain their original error handling and hardware behavior.
# Multi-VM callers opt in explicitly with --role.
if [[ "$ENDPOINT_ROLE" != legacy ]]; then
    set -euo pipefail
fi

case "$ENDPOINT_ROLE" in legacy|guest|physical) ;; *) echo "Invalid --role: $ENDPOINT_ROLE" >&2; exit 2 ;; esac
case "$DDIO_ENABLED" in 0|1|keep) ;; *) echo "Invalid --ddio: $DDIO_ENABLED" >&2; exit 2 ;; esac

configure_physical_controls() {
    if [[ "$ENDPOINT_ROLE" == guest ]]; then
        log_info "Guest VF: skip physical hardware controls"
        return 0
    fi
    if [[ "$ENDPOINT_ROLE" == physical ]]; then
        sudo ethtool -A "$INTF" rx off tx off
    fi
    if [[ "$DDIO_ENABLED" == keep ]]; then
        log_info "Preserving physical DDIO configuration"
    else
        #Enable/disable DDIO
        cd ${DEPS_DIR}/ddio-bench/
        if [ "$DDIO_ENABLED" -eq 1 ]; then
            log_info "Enabling DDIO..."
            sudo ./ddio-tool -b $NIC_BUS enable
        else
            log_info "Disabling DDIO..."
            sudo ./ddio-tool -b $NIC_BUS disable
        fi
        cd -
    fi
    #Enable prefetching
    if [ "$HWPREF_ENABLED" -eq 1 ]; then
        log_info "Enabling hardware prefetching..."
        modprobe msr
        wrmsr -a 0x1a4 0
    else
        log_info "Disabling hardware prefetching..."
        modprobe msr
        wrmsr -a 0x1a4 1
    fi

    #Enable PFC (on QoS 0)
    if [ "$PFC_ENABLED" -eq 1 ]
    then
        log_info "Enabling PFC..."
        if [ "$MLNX_DRIVER" -eq 1 ]; then
          mlnx_qos -i $INTF --pfc 1,0,0,0,0,0,0,0
        else
          sudo lldptool -T -i $INTF -V PFC willing=no enabled=0
        fi
        tc_wrap.py -i $INTF
        tc_wrap.py -i $INTF -u 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

        # To enable on other QoS, modify the above code accordingly
        # For eg., to enable PFC on QoS 1 or 2 us the code below

        # Qos 1
        #  mlnx_qos -i $INTF --pfc 0,1,0,0,0,0,0,0
        #  tc_wrap.py -i $INTF
        #  tc_wrap.py -i $INTF -u 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1

        # Qos 2
        # mlnx_qos -i $INTF --pfc 0,0,1,0,0,0,0,0
        # tc_wrap.py -i $INTF
        # tc_wrap.py -i $INTF -u 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
    else
        log_info "Disabling PFC..."
        if [ "$MLNX_DRIVER" -eq 1 ]; then
          sudo mlnx_qos -i $INTF --pfc 0,0,0,0,0,0,0,0
        else
          sudo lldptool -T -i $INTF -V PFC willing=no enabled=
        fi
    fi
    local pfc_rc=$?
    if [[ "$ENDPOINT_ROLE" == physical && -f /sys/devices/system/cpu/smt/control && $(cat /sys/devices/system/cpu/smt/control) != notsupported ]]; then
        echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null
    else
        return "$pfc_rc"
    fi
}

if [ "$RDMA" -eq 1 ]; then
  log_info "Configuring MTU according to RDMA supported values..."
  MTU=$(($MTU + 96))
  if [ "$MTU" -lt 1280 ]; then
      log_info "Requested physical MTU size is $MTU, updating to 1280"
      MTU=1280
  fi
  log_info "MTU configured to $MTU"
fi

# setup the interface
log_info "Setting up the interface $INTF..."
# ifconfig $INTF up
# ifconfig $INTF $IP
# ifconfig $INTF mtu $MTU
sudo ip -4 addr flush dev $INTF
sudo ip -6 addr flush dev $INTF

sudo ip link set $INTF up
sudo ip address add $IP/24 dev $INTF
sudo ip link set dev $INTF mtu $MTU
 


#disable TCP buffer auto-tuning, and set the buffer size to the specified size
log_info "Setting up the socket buffer size to be ${TCP_SOCKET_BUF_MB}MB"
echo 0 > /proc/sys/net/ipv4/tcp_moderate_rcvbuf 
#Set TCP receive buffer size to be 1MB (other 1MB is for the application buffer)
echo "$(($TCP_SOCKET_BUF_MB * 2000000)) $(($TCP_SOCKET_BUF_MB * 2000000)) $(($TCP_SOCKET_BUF_MB * 2000000))" > /proc/sys/net/ipv4/tcp_rmem 
#Set TCP send buffer size to be 1MB
echo "$(($TCP_SOCKET_BUF_MB * 1000000)) $(($TCP_SOCKET_BUF_MB * 1000000)) $(($TCP_SOCKET_BUF_MB * 1000000))" > /proc/sys/net/ipv4/tcp_wmem

#Enable TCP ECN support at the senders/receivers
if [ "$ECN_ENABLED" = 1 ]; then
    log_info "Enabling ECN support..."
    echo 1 > /proc/sys/net/ipv4/tcp_ecn
fi

#Enable aRFS, TSO, GRO for the interface
if [ "$TCP_OPTIMIZATION_ENABLED" -eq 1 ]; then
    cd ${DEPS_DIR}/Understanding-network-stack-overheads-SIGCOMM-2021
    log_info "Enabling TCP optimizations (TSO, GRO, aRFS)..."
    sudo python3 network_setup.py $INTF --arfs --mtu $MTU --sock-size --tso --gro --ring-buffer $RING_BUFFER_SIZE
    cd -
fi

# Explicit multi-VM setup also clears tracing; legacy callers retain the
# exit status of their original final hardware operation.
# Only explicit multi-VM setup changes tracing state.
if [[ "$ENDPOINT_ROLE" != legacy ]]; then
    configure_physical_controls
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    echo 0 > /sys/kernel/debug/tracing/events/enable
    echo nop > /sys/kernel/debug/tracing/current_tracer
else
    configure_physical_controls
fi
