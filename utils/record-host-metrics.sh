set -euo pipefail
#default values
SCRIPT_NAME="record-host-metrics"

DEP_DIR="/home/schai"
OUT_DIR="test"
DURATION_S=30
TYPE=1
CPU_UTIL_REPORTING=1  
CPU_MASK=0
RETX_REPORTING=1
TCP_LOG_REPORTING=0
FLAMEGRAPH_REPORTING=0
PERCORE_FLAMEGRAPH=1
BANDWIDTH_REPORTING=1
EXPECTED_FLOWS=0
PCIE_REPORTING=1
MEMBW_REPORTING=1
IIO_REPORTING=0
PFC_REPORTING=0
INTF=enp8s0

PCM_PCIE_FILTER="Socket1,IIO Stack 1 - PCIe3,Part0"

PERF_PATH="/home/schai/linux-6.12.9/tools/perf/perf"
cur_dir=$PWD

help()
{
    echo "Usage: $SCRIPT_NAME [ --dep (dependency directory)]
               [ -o | --outdir (name of the output directory which will store the records; default=test) ] 
               [ --dur (duration in seconds to record each metric; default=30s) ] 
               [ --cpu-util (=0/1, disable/enable recording cpu utilization) ) ] 
               [ -c | --cores (comma separated values of cpu cores to log utilization, eg., '0,4,8,12') ) ] 
               [ --retx (=0/1, disable/enable recording retransmission rate (should be done at TCP senders) ) ] 
               [ --tcplog (=0/1, disable/enable recording TCP log (should be done at TCP senders) ) ] 
               [ --bw (=0/1, disable/enable recording app-level bandwidth ) ]
               [ --expected-flows N (require all N flow logs and the full throughput window) ]
               [ -f | --flame (=0/1, disable/enable recording flamegraph (for cores specified via -C/--cores option) ) ] 
               [ --percore-flame (=0/1, disable/enable per-core flamegraph breakdown (requires --flame=1) ) ] 
               [ --pcie (=0/1, disable/enable recording PCIe bandwidth) ] 
               [ --membw (=0/1, disable/enable recording memory bandwidth) ] 
               [ --iio (=0/1, disable/enable recording IIO occupancy) ] 
               [ --pfc (=0/1, disable/enable recording PFC pause triggers) ] 
               [ --intf (interface name, over which to record PFC triggers) ] 
               [ -t | --type (=0/1, experiment type -- 0 for TCP, 1 for RDMA) ] 
               [ -h | --help  ]"
    exit 2
}

SHORT=o:,c:,f:,t:,h
LONG=dep:,outdir:,dur:,cpu-util:,cores:,retx:,tcplog:,bw:,expected-flows:,flame:,percore-flame:,pcie:,membw:,iio:,pfc:,intf:,type:,help
OPTS=$(getopt -a -n $SCRIPT_NAME --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options
if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi
eval set -- "$OPTS"

#TODO: add input config file to specify NUMA node and PCIe slot for PCIe, MemBW and IIO occupancy logging
while :; do
  case "$1" in
     --dep) DEP_DIR="$2"; shift 2 ;;
    -o | --outdir) OUT_DIR="$2"; shift 2 ;;
    --dur) DURATION_S="$2"; shift 2 ;;
    --cpu-util) CPU_UTIL_REPORTING="$2"; shift 2 ;; 
    -c | --cores) CPU_MASK="$2"; shift 2 ;;
    --retx) RETX_REPORTING="$2"; shift 2 ;;
    --tcplog) TCP_LOG_REPORTING="$2"; shift 2 ;;
    --bw) BANDWIDTH_REPORTING="$2"; shift 2 ;;
    --expected-flows) EXPECTED_FLOWS="$2"; shift 2 ;;
    -f | --flame) FLAMEGRAPH_REPORTING="$2"; shift 2 ;;
    --percore-flame) PERCORE_FLAMEGRAPH="$2"; shift 2 ;;
    --pcie) PCIE_REPORTING="$2"; shift 2 ;;
    --membw) MEMBW_REPORTING="$2"; shift 2 ;;
    --iio) IIO_REPORTING="$2"; shift 2 ;;
    --pfc) PFC_REPORTING="$2"; shift 2 ;;
    --intf) INTF="$2"; shift 2 ;;
    -t | --type) TYPE="$2"; shift 2 ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1"; help ;;
  esac
done

mkdir -p logs #Directory to store collected logs
mkdir -p logs/$OUT_DIR #Directory to store collected logs
mkdir -p reports #Directory to store parsed metrics
mkdir -p reports/$OUT_DIR #Directory to store parsed metrics

function dump_netstat() {
    local SLEEP_TIME=$1
    local interface=$2

    echo "Before measurement"
    netstat -s
    sudo ip -s link show dev $interface

    echo "Sleeping..."
    sleep $SLEEP_TIME

    echo "After measurement"
    netstat -s
    sudo ip -s link show dev $interface
}

function dump_pciebw() {
    modprobe msr
    # sudo strace -e trace=open,openat -o logs/$OUT_DIR/strace.txt 
    sudo taskset -c 15 $DEP_DIR/pcm/build/bin/pcm-iio 1 -csv=logs/$OUT_DIR/pcie.csv &
}

function parse_pciebw() {
    local input_file="logs/$OUT_DIR/pcie.csv"
    local output_file="reports/$OUT_DIR/pcie.rpt"
    local filter="$PCM_PCIE_FILTER"

    read ib_wr_gbps ib_rd_gbps \
         iotlb_first_lk iotlb_all_lk iotlb_4k_hits iotlb_2m_hits iotlb_1g_hits iotlb_misses \
         ctx_lk ctx_hit \
         cache_lk hit_256T hit_512G hit_1G hit_2M cache_fills \
         iommu_mem_access iotlb_inv pwt_occ < <(
        grep -F -- "$filter" "$input_file" \
        | awk -F',' '
            {
              n++
              ibw += $6; ibr += $7;

              iotlb_first += $10; iotlb_all += $11
              iotlb_4k += $12; iotlb_2m += $13; iotlb_1g += $14; iotlb_miss += $15

              ctx_lkp += $16; ctx_hits += $17

              cache_lkp += $18; hit_256T += $19; hit_512G += $20; hit_1G += $21; hit_2M += $22; cache_fills += $23

              mem_access += $24
              inv_iotlb += $26; pwt += $28
            }
            END{
              if (n==0) n=1

              ibw/=n; ibr/=n

              # Gbps
              ib_wr_gbps = ibw * 8 / 1e9
              ib_rd_gbps = ibr * 8 / 1e9

              iotlb_first/=n; iotlb_all/=n; iotlb_4k/=n; iotlb_2m/=n; iotlb_1g/=n; iotlb_miss/=n
              ctx_lkp/=n; ctx_hits/=n
              cache_lkp/=n; hit_256T/=n; hit_512G/=n; hit_1G/=n; hit_2M/=n; cache_fills/=n
              mem_access/=n
              inv_iotlb/=n; pwt/=n

              # Print space-separated in fixed order for `read`
              printf "%.6f %.6f ", ib_wr_gbps, ib_rd_gbps
              printf "%.6f %.6f %.6f %.6f %.6f %.6f ", iotlb_first, iotlb_all, iotlb_4k, iotlb_2m, iotlb_1g, iotlb_miss
              printf "%.6f %.6f ", ctx_lkp, ctx_hits
              printf "%.6f %.6f %.6f %.6f %.6f %.6f ", cache_lkp, hit_256T, hit_512G, hit_1G, hit_2M, cache_fills
              printf "%.6f ", mem_access
              printf "%.6f %.6f ", inv_iotlb, pwt
            }
        '
    )

    # Write report
    {
        printf "PCIe_wr_tput: %.3f\n" "$ib_wr_gbps"
        printf "PCIe_rd_tput: %.3f\n" "$ib_rd_gbps"

        printf "IOTLB_first_lookup_avg: %.3f\n" "$iotlb_first_lk"
        printf "IOTLB_all_lookup_avg: %.3f\n"   "$iotlb_all_lk"
        printf "IOTLB_4K_hits_avg: %.3f\n"      "$iotlb_4k_hits"
        printf "IOTLB_2M_hits_avg: %.3f\n"      "$iotlb_2m_hits"
        printf "IOTLB_1G_hits_avg: %.3f\n"      "$iotlb_1g_hits"
        printf "IOTLB_miss_avg: %.3f\n"         "$iotlb_misses"

        printf "Ctx_lookup_avg: %.3f\n"         "$ctx_lk"
        printf "Ctx_hits_avg: %.3f\n"           "$ctx_hit"

        printf "Cache_lookup_avg: %.3f\n"       "$cache_lk"
        printf "Cache_hit_256T_avg: %.3f\n"     "$hit_256T"
        printf "Cache_hit_512G_avg: %.3f\n"     "$hit_512G"
        printf "Cache_hit_1G_avg: %.3f\n"       "$hit_1G"
        printf "Cache_hit_2M_avg: %.3f\n"       "$hit_2M"
        printf "Cache_fills_avg: %.3f\n"        "$cache_fills"

        printf "IOMMU_mem_access: %.3f\n"       "$iommu_mem_access"
        printf "IOTLB_inv_avg: %.3f\n"          "$iotlb_inv"
        printf "PWT_occupancy_avg: %.3f\n"      "$pwt_occ"
    } > "$output_file"
}

function dump_membw() {
    modprobe msr
    sudo taskset -c 15 $DEP_DIR/pcm/build/bin/pcm-memory 1 -columns=5
}

function parse_membw() {
    #TODO: make more general, parse memory bandwidth for any given number of sockets
    echo "Node0_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Mem Read" | awk '{ sum += $8; n++ } END { if (n > 0) printf "%f\n", sum / n; }') > reports/$OUT_DIR/membw.rpt
    echo "Node0_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Mem Write" | awk '{ sum += $7; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node0_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 0 Memory" | awk '{ sum += $6; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Mem Read" | awk '{ sum += $16; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Mem Write" | awk '{ sum += $14; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node1_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 1 Memory" | awk '{ sum += $12; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> reports/$OUT_DIR/membw.rpt
    echo "Node2_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Mem Read" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node2_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Mem Write" | awk '{ sum += $21; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node2_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 2 Memory" | awk '{ sum += $18; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_rd_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Mem Read" | awk '{ sum += $32; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_wr_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Mem Write" | awk '{ sum += $28; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
    echo "Node3_total_bw: " $(cat logs/$OUT_DIR/membw.log | grep "NODE 3 Memory" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> reports/$OUT_DIR/membw.rpt
}

function collect_pfc() {
    #assuming PFC is enabled for QoS 0
    sudo ethtool -S $INTF | grep pause > logs/$OUT_DIR/pause.before.log
    sleep $DURATION_S
    sudo ethtool -S $INTF | grep pause > logs/$OUT_DIR/pause.after.log

    pause_before=$(cat logs/$OUT_DIR/pause.before.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_before=$(cat logs/$OUT_DIR/pause.before.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')
    pause_after=$(cat logs/$OUT_DIR/pause.after.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_after=$(cat logs/$OUT_DIR/pause.after.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')

    echo "pauses_before: "$pause_before > logs/$OUT_DIR/pause.log
    echo "pause_duration_before: "$pause_duration_before >> logs/$OUT_DIR/pause.log
    echo "pauses_after: "$pause_after >> logs/$OUT_DIR/pause.log
    echo "pause_duration_after: "$pause_duration_after >> logs/$OUT_DIR/pause.log

    # echo $pause_before, $pause_after
    echo "print(($pause_after - $pause_before)/$DURATION_S)" | lua > reports/$OUT_DIR/pause.rpt

    # echo $pause_duration_before, $pause_duration_after
    echo "print(($pause_duration_after - $pause_duration_before)/$DURATION_S)" | lua >> reports/$OUT_DIR/pause.rpt
}

function compile_if_needed() {
    local source_file=$1
    local executable=$2

    # Check if the executable exists and if the source file is newer
    if [ ! -f "$executable" ] || [ "$source_file" -nt "$executable" ]; then
        echo "Compiling $source_file..."
        gcc -o "$executable" "$source_file"
        if [ $? -eq 0 ]; then
            echo "Compilation successful."
        else
            echo "Compilation failed."
        fi
    else
        echo "No need to recompile."
    fi
}

if [ "$TYPE" -eq 0 ]; then
    echo "Collecting TCP experiment metrics..."

    if [[ "$EXPECTED_FLOWS" -gt 0 && "$BANDWIDTH_REPORTING" -eq 1 ]]; then
        rm -f "reports/$OUT_DIR/iperf.bw.rpt"
    fi
    bw_offsets="{}"
    if [[ "$BANDWIDTH_REPORTING" -eq 1 ]]; then
        bw_offsets=$(python3 - "logs/$OUT_DIR" "$EXPECTED_FLOWS" <<'IPERF_OFFSETS'
import json,sys
from pathlib import Path
directory, expected = Path(sys.argv[1]), int(sys.argv[2])
files = list(directory.glob('iperf.bw.*.log'))
if expected and {p.name for p in files} != {f'iperf.bw.{i}.log' for i in range(expected)}:
    raise SystemExit(f'Expected {expected} flow logs in {directory}; found {len(files)}')
print(json.dumps({str(p.resolve()):p.stat().st_size for p in files}))
IPERF_OFFSETS
)
    fi

    if [ "$CPU_UTIL_REPORTING" -eq 1 ]; then
      echo "Collecting CPU utilization for cores $CPU_MASK..." 
      sar -P "$CPU_MASK" 1 "$DURATION_S" > "logs/$OUT_DIR/cpu_util.log" &
      sar_pid=$!
      trap 'kill "$sar_pid" 2>/dev/null || true' EXIT
      wait "$sar_pid"
      trap - EXIT
      python3 cpu_util.py logs/$OUT_DIR/cpu_util.log > reports/$OUT_DIR/cpu_util.rpt
    fi

    if [[ "$BANDWIDTH_REPORTING" -eq 1 && "$bw_offsets" != "{}" ]]; then
        [[ "$CPU_UTIL_REPORTING" -eq 1 ]] || sleep "$DURATION_S"
        # The existing parser runs from scripts/, as in the original TX runner.
        if [[ "$EXPECTED_FLOWS" -gt 0 ]]; then
            (cd ../scripts && bash collect-period-tput.sh "$OUT_DIR" "$bw_offsets" "$DURATION_S" "$EXPECTED_FLOWS")
        else
            (cd ../scripts && bash collect-period-tput.sh "$OUT_DIR" "$bw_offsets")
        fi
    fi

    if [ "$RETX_REPORTING" -eq 1 ]; then
      echo "Collecting retransmission rate..."
      dump_netstat $DURATION_S $INTF > logs/$OUT_DIR/retx.log
      python3 print_retx_rate.py logs/$OUT_DIR/retx.log $DURATION_S > reports/$OUT_DIR/retx.rpt
      # dump_netstat $DURATION_S $INTF > logs/$OUT_DIR/retx.log
      # cat logs/$OUT_DIR/retx.log | grep -E "segment|TCPLostRetransmit" > retx.out
      # python3 print_retx_rate.py retx.out $DURATION_S > reports/$OUT_DIR/retx.rpt
    fi

    if [ "$TCP_LOG_REPORTING" -eq 1 ]; then
      echo "Collecting tcplog..."
      cd /sys/kernel/debug/tracing
      echo > trace
      echo 1 > events/tcp/tcp_probe/enable
      sleep 2
      echo 0 > events/tcp/tcp_probe/enable
      sleep 2
      cp trace $cur_dir/logs/$OUT_DIR/tcp.trace.log
      echo > trace
      cd -
      python3 parse_tcplog.py $OUT_DIR
    fi
elif [ "$TYPE" -eq 1 ]; then
  echo "Collecting RDMA experiment metrics..."
  
  if [ "$PFC_REPORTING" -eq 1 ]; then
    echo "Collecting PFC triggers at RDMA server..."
    collect_pfc
  fi
else
  echo "Incorrect type..."
  help
fi

if [ "$PCIE_REPORTING" -eq 1 ]; then
  echo "Collecting PCIe bandwidth..."
  dump_pciebw
  sleep $DURATION_S
  sudo pkill -9 -f "pcm"
  parse_pciebw
fi

if [ "$MEMBW_REPORTING" -eq 1 ]; then
  echo "Collecting Memory bandwidth..."
  dump_membw > logs/$OUT_DIR/membw.log &
  # sleep 30
  sleep $DURATION_S
  sudo pkill -9 -f "pcm"
  parse_membw
fi

if [ "$IIO_REPORTING" -eq 1 ]; then
  echo "Collecting IIO occupancy..."
  compile_if_needed collect_iio_occ.c collect_iio_occ
  taskset -c 14 ./collect_iio_occ &
  sleep 5
  sudo pkill -2 -f collect_iio_occ
  sleep 5
  mv iio.log logs/$OUT_DIR/iio.log
  #TODO: make more generic and add a parser to create report for iio occupancy logging from userspace
fi

if [ "$FLAMEGRAPH_REPORTING" -eq 1 ]; then
    sudo rm -f logs/$OUT_DIR/out.perf-folded
    sudo rm -f perf.data
    echo "Creating Flame Graph..."

    # hack collect the last CPU
    COLLECT_CPU_MASK=$CPU_MASK"31"

    echo "Collecting flamegraph for cores $COLLECT_CPU_MASK..."
    sudo $PERF_PATH record -o logs/$OUT_DIR/perf.data -C $COLLECT_CPU_MASK -g -F 99 -- sleep $DURATION_S

    # sudo $PERF_PATH script -i logs/$OUT_DIR/perf.data > logs/$OUT_DIR/perf.data.txt
    # sudo $DEP_DIR/FlameGraph/stackcollapse-perf.pl logs/$OUT_DIR/perf.data.txt > logs/$OUT_DIR/out.perf-folded
    # sudo $DEP_DIR/FlameGraph/flamegraph.pl logs/$OUT_DIR/out.perf-folded > reports/$OUT_DIR/perf-kernel-flame.svg

    # echo "Flamegraph Results saved to $(realpath reports/$OUT_DIR/perf-kernel-flame.svg)"

    # Generate per-core flamegraphs
    if [ "$PERCORE_FLAMEGRAPH" -eq 1 ]; then
        # IFS=',' read -ra CORES <<< "$CPU_MASK"
        # for core in "${CORES[@]}"; do
        for core in 4 31; do
            # core=$(echo "$core" | xargs)
            # if [ -z "$core" ]; then continue; fi

            echo "Generating flamegraph for core $core..."
            sudo $PERF_PATH script -C "$core" -i logs/$OUT_DIR/perf.data > logs/$OUT_DIR/perf.data.cpu$core.txt
            if [ -s logs/$OUT_DIR/perf.data.cpu$core.txt ]; then
                sudo $DEP_DIR/FlameGraph/stackcollapse-perf.pl logs/$OUT_DIR/perf.data.cpu$core.txt > logs/$OUT_DIR/out.perf-folded.cpu$core
                sudo $DEP_DIR/FlameGraph/flamegraph.pl logs/$OUT_DIR/out.perf-folded.cpu$core > reports/$OUT_DIR/perf-kernel-flame-cpu$core.svg
                echo "  Saved to reports/$OUT_DIR/perf-kernel-flame-cpu$core.svg"
            else
                echo "  No samples found for core $core"
            fi
        done
    fi
    
    # also collect cache miss rates
    sudo $PERF_PATH stat -C $CPU_MASK -e LLC-load,LLC-load-misses,l2_rqsts.all_demand_miss,l2_rqsts.all_demand_references -o logs/$OUT_DIR/llc.miss.log sleep 2
    #loadmisses=$(cat logs/$4/$3/llc.miss.log | grep "LLC-load-misses" | awk '{ printf $1 }')
    #loads=$(cat logs/$4/$3/llc.miss.log | grep "LLC-load " | awk '{ printf $1 }')
fi
