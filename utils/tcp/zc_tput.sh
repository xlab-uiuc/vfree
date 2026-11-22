#!/bin/bash
# Launch zc_tput flows the way run-netapp-tput.sh launches iperf3: one process
# per flow, round-robin over the given cores, left running in the background.
#   server mode: receivers (recv_zc or recv) listen on PORT, PORT+1, ...
#   client mode: senders (send_zc or send) connect to SERVER_IP
# Each flow logs per-second counters to ../logs/<outdir>/zc_tput.<op>.port<N>.log
SCRIPT_NAME="zc_tput"

MODE="server"
OP=""
OUT_DIR="tcptest"
SERVER_IP=""
CPU_MASK="0"
NUM_SERVERS=1
NUM_CLIENTS=1
PORT=3000
SEND_BYTES=65536
MAX_RUNTIME_S=10000 # same cap as the iperf3 clients (-t 10000)

help()
{
    echo "Usage: $SCRIPT_NAME --mode server|client --op recv_zc|recv|send_zc|send
               [ --server-ip (receiver address; required in client mode) ]
               [ -o | --outdir (log directory name) ]
               [ -n | --num_servers (number of receivers) ]
               [ -N | --num_clients (number of senders) ]
               [ -p | --port (port of the first flow) ]
               [ -c | --cores (comma separated cores; flows round-robin over them) ]
               [ --send-bytes (bytes per send call; default 65536) ]
               [ -h | --help ]"
    exit 2
}

SHORT=o:,n:,N:,p:,c:,h
LONG=mode:,op:,outdir:,num_servers:,num_clients:,port:,server-ip:,cores:,send-bytes:,help
OPTS=$(getopt -a -n "$SCRIPT_NAME" --options $SHORT --longoptions $LONG -- "$@") || help
eval set -- "$OPTS"

while :; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --op) OP="$2"; shift 2 ;;
    -o | --outdir) OUT_DIR="$2"; shift 2 ;;
    -n | --num_servers) NUM_SERVERS="$2"; shift 2 ;;
    -N | --num_clients) NUM_CLIENTS="$2"; shift 2 ;;
    -p | --port) PORT="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    -c | --cores) CPU_MASK="$2"; shift 2 ;;
    --send-bytes) SEND_BYTES="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

case "$MODE:$OP" in
  server:recv_zc|server:recv) ;;
  client:send_zc|client:send) [ -n "$SERVER_IP" ] || { echo "--server-ip is required in client mode"; help; } ;;
  *) echo "Invalid --mode/--op combination: $MODE/$OP"; help ;;
esac

cd "$(dirname "$0")" || exit 1

# Build on each machine so the binary matches its own libc.
if [ ! -x zc_tput ] || [ zc_tput.c -nt zc_tput ]; then
    echo "Building zc_tput..."
    gcc -O2 -Wall -o zc_tput zc_tput.c || { echo "zc_tput build failed"; exit 1; }
fi

IFS=',' read -ra core_values <<< "$CPU_MASK"

mkdir -p "../reports/$OUT_DIR" "../logs/$OUT_DIR"
rm -f "../logs/$OUT_DIR"/zc_tput.*.log

sudo pkill -x zc_tput # kill flows left over from an earlier run
sudo modprobe tcp_dctcp

counter=0
if [ "$MODE" = "server" ]; then
    while [ $counter -lt "$NUM_SERVERS" ]; do
        core=${core_values[$(( counter % ${#core_values[@]} ))]}
        port=$(( PORT + counter ))
        echo "Starting $OP receiver $counter on core $core, port $port"
        sudo taskset -c "$core" nice -n -20 timeout "$MAX_RUNTIME_S" \
            ./zc_tput "$OP" 0.0.0.0 "$port" "../logs/$OUT_DIR/zc_tput.$OP.port$port.log" &
        ((counter++))
    done
else
    while [ $counter -lt "$NUM_CLIENTS" ]; do
        core=${core_values[$(( counter % ${#core_values[@]} ))]}
        port=$(( PORT + counter % NUM_SERVERS ))
        echo "Starting $OP sender $counter on core $core, port $port"
        sudo taskset -c "$core" nice -n -20 timeout "$MAX_RUNTIME_S" \
            ./zc_tput "$OP" "$SERVER_IP" "$port" "../logs/$OUT_DIR/zc_tput.$OP.port$port.log" "$SEND_BYTES" &
        ((counter++))
    done
fi
