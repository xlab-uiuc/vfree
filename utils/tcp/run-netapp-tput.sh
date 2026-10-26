#!/bin/bash
SCRIPT_NAME="run-netapp-tput"

#default values
ISOLATED=0
MODE="server"
OUT_DIR="tcptest"
SERVER_IP="192.168.11.127"
CPU_MASK="0,1,2,3,4"
NUM_SERVERS=5
NUM_CLIENTS=5
PORT=3000
BANDWIDTH="100g"

help()
{
    echo "Usage: $SCRIPT_NAME [ --mode (=client/server) ]
               [ -o | --outdir (output directory to store the application stats log; default='test')]
               [ -n | --num_servers (number of server instances)]
               [ -N | --num_clients (number of client instances, only use this option at client)]
               [ -p | --port (port number for the first connection) ]
               [ --server-ip (ip address of the server, only use this option at client) ]
               [ -c | --cores (comma separated cpu core values to run the clients/servers at, for eg., cpu=4,8,12,16; if the number of clients/servers > the number of input cpu cores, the clients/servers will round-robin over the provided input cores; recommended to run on NUMA node local to the NIC for maximum performance) ]
               [ -b | --bandwidth (bandwidth to send at in bits/sec)]
               [ -h | --help  ]"
    exit 2
}

SHORT=o:,n:,N:,p:,c:,b:,h
LONG=isolated,mode:,outdir:,num_servers:,num_clients:,port:,server-ip:,cores:,bandwidth:,help
OPTS=$(getopt -a -n run-netapp-tput --options $SHORT --longoptions $LONG -- "$@") || exit 2
VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$OPTS"

while :;do
  case "$1" in
    --isolated) ISOLATED=1; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    -o | --outdir) OUT_DIR="$2"; shift 2 ;;
    -n | --num_servers) NUM_SERVERS="$2"; shift 2 ;;
    -N | --num_clients) NUM_CLIENTS="$2"; shift 2 ;;
    -p | --port) PORT="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    -c | --cores) CPU_MASK="$2"; shift 2 ;;
    -b | --bandwidth) BANDWIDTH="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

if [[ "$ISOLATED" -eq 1 ]]; then
    set -euo pipefail
    iperf_pids=()
    trap 'if [[ ${#iperf_pids[@]} -gt 0 ]]; then kill "${iperf_pids[@]}" 2>/dev/null || true; wait || true; fi' EXIT
    trap 'exit 1' HUP INT TERM
fi

IFS=',' read -ra core_values <<< $CPU_MASK

mkdir -p ../reports #Directory to store collected logs
mkdir -p ../reports/$OUT_DIR #Directory to store collected logs
mkdir -p ../logs #Directory to store collected logs
mkdir -p ../logs/$OUT_DIR #Directory to store collected logs
rm -f ../logs/$OUT_DIR/iperf.bw.log

function collect_stats() {
  echo "Collecting app throughput for TCP server..."
  echo "Avg_iperf_tput: " $(cat ../logs/$OUT_DIR/iperf.bw.log | grep "30.*-60.*" | awk  '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }') > ../reports/$OUT_DIR/iperf.bw.rpt
}

counter=0
if [ "$MODE" = "server" ]; then
    if [[ "$ISOLATED" -eq 0 ]]; then sudo pkill -9 -f iperf || true; fi
    while [ $counter -lt $NUM_SERVERS ]; do
        index=$(( counter % ${#core_values[@]} ))
        core=${core_values[index]}
        echo "Starting server $counter on core $core"
        report_args=(-i 30 -f m --logfile "../logs/$OUT_DIR/iperf.bw.log")
        if [[ "$ISOLATED" -eq 1 ]]; then
            report_args=(-i 1 -f m --forceflush --logfile "../logs/$OUT_DIR/iperf.bw.$counter.log")
        fi
        sudo taskset -c $core nice -n -20 iperf3 -s --port $(($PORT + $counter)) "${report_args[@]}" &
        if [[ "$ISOLATED" -eq 1 ]]; then iperf_pids+=("$!"); fi
        ((counter+=1))
    done
    if [[ "$ISOLATED" -eq 0 ]]; then
        echo "waiting for few minutes before collecting stats..."
        sleep 120
        collect_stats
    fi
elif [ "$MODE" = "client" ]; then
    if [[ "$ISOLATED" -eq 0 ]]; then sudo pkill -9 -f iperf || true; fi
    while [ $counter -lt $NUM_CLIENTS ]; do
        index=$(( counter % ${#core_values[@]} ))
        core=${core_values[index]}
        echo "Starting client $counter on core $core"
        taskset -c $core nice -n -20 iperf3 -c $SERVER_IP --port $(($PORT+$(($counter%$NUM_SERVERS)))) -t 10000 -C dctcp -b $BANDWIDTH &
        if [[ "$ISOLATED" -eq 1 ]]; then iperf_pids+=("$!"); fi
        ((counter+=1))
    done
else
    echo "incorrect argument specified"
    help
fi

# Isolated traffic is owned by the guest runner until its measurement finishes.
# Any flow ending before cleanup fails this launcher, including a zero exit.
if [[ "$ISOLATED" -eq 1 ]]; then
    rc=0
    wait -n "${iperf_pids[@]}" || rc=$?
    echo "iperf flow exited before experiment cleanup (exit $rc)" >&2
    exit 1
fi
