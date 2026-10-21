#!/usr/bin/env python3
"""Per-run evidence collection; only the coordinator writes to the host report tree.

The same file is streamed to remote Python interpreters, so endpoints need no
checkout or installed Python packages. No NIC/CPU/IOMMU settings are changed.
"""
import argparse
import concurrent.futures
import csv
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time

START_LEAD_S = 10


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def command(argv, timeout=10, cwd=None):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return dict(argv=argv, returncode=p.returncode, stdout=p.stdout, stderr=p.stderr)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return dict(argv=argv, returncode=-1, stdout='', stderr=str(exc))


def read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return None


def stamp():
    return dict(unix_s=time.time(), monotonic_s=time.monotonic())


def wait_until(epoch):
    # Convert once; elapsed windows then use the monotonic clock.
    deadline = time.monotonic() + epoch - time.time()
    while time.monotonic() < deadline:
        time.sleep(max(0, min(.2, deadline - time.monotonic())))


def probe(interface):
    missing = [name for name in ('ethtool', 'ss', 'ip') if not shutil.which(name)]
    if not Path('/sys/class/net', interface).is_dir():
        missing.append('interface ' + interface)
    return dict(**stamp(), hostname=socket.gethostname(), missing=missing)


def socket_counters(raw):
    connections = {}
    key = None
    for line in raw.splitlines():
        if not line.startswith((' ', '\t')):
            fields = line.split()
            key = ' '.join(fields[3:5]) if len(fields) >= 5 and fields[0] == 'ESTAB' else None
        elif key:
            connections.setdefault(key, {}).update({m[1]: int(m[2]) for m in re.finditer(
                r'\b(bytes_acked|bytes_received|bytes_retrans|bytes_sent|segs_out|segs_in|data_segs_out|data_segs_in):([0-9]+)', line)})
    return connections


def snapshot(interface, peers):
    begin = stamp()
    cpu_raw = read('/proc/stat') or ''
    cpus = {line.split()[0]: list(map(int, line.split()[1:9]))
            for line in cpu_raw.splitlines() if re.match(r'^cpu\d* ', line)}
    protocols = {}
    raw_proc = {name: read('/proc/' + name) for name in (
        'stat', 'softirqs', 'interrupts', 'net/softnet_stat', 'net/snmp', 'net/netstat')}
    for name in ('net/snmp', 'net/netstat'):
        lines = (raw_proc[name] or '').splitlines()
        for header, values in zip(lines[::2], lines[1::2]):
            labels, counts = header.split(), values.split()
            protocols.update({labels[0].rstrip(':') + '.' + k: int(v)
                              for k, v in zip(labels[1:], counts[1:])})
    nic = command(['ethtool', '-S', interface])
    nic_values = {m[1]: int(m[2]) for m in re.finditer(
        r'^\s*(\S+):\s*(\d+)\s*$', nic['stdout'], re.M)}
    # Restrict to workload peers: excludes SSH/control-plane connections.
    filters = []
    if peers:
        filters.append('(')
        for index, peer in enumerate(peers):
            if index:
                filters.append('or')
            filters.extend(['dst', peer])
        filters.append(')')
    tcp_start = stamp()
    tcp = command(['ss', '-tinH', 'state', 'established'] + filters)
    # `state established` omits the State column. Normalize for stable endpoint keys.
    normalized = '\n'.join('ESTAB ' + line if line and not line[0].isspace() else line
                           for line in tcp['stdout'].splitlines())
    tcp_end = stamp()
    net_stats = Path('/sys/class/net', interface, 'statistics')
    frequency = {}
    for cpu in cpus:
        if cpu == 'cpu':
            continue
        base = Path('/sys/devices/system/cpu', cpu, 'cpufreq')
        frequency[cpu] = {k: read(base / k) for k in ('scaling_cur_freq', 'scaling_governor')}
    return dict(begin=begin, end=stamp(), cpu=cpus, protocol=protocols,
                proc_raw=raw_proc, ethtool=nic_values, ethtool_raw=nic,
                sysfs={p.name: int(p.read_text()) for p in net_stats.iterdir()},
                frequency=frequency,
                tcp=dict(begin=tcp_start, end=tcp_end, raw=tcp,
                         connections=socket_counters(normalized)))


def summarize(before, after):
    elapsed = after['begin']['monotonic_s'] - before['begin']['monotonic_s']
    result = dict(elapsed_s=elapsed, delta={}, counter_resets={}, cpu_busy_pct={})
    for group in ('ethtool', 'protocol', 'sysfs'):
        common = {k for k in before[group].keys() & after[group].keys()
                  if not k.startswith('outbound_pci_stalled_') and k != 'Tcp.CurrEstab'}
        result['delta'][group] = {k: after[group][k] - before[group][k] for k in common
                                  if after[group][k] >= before[group][k]}
        result['counter_resets'][group] = [k for k in common if after[group][k] < before[group][k]]
    for cpu in before['cpu'].keys() & after['cpu'].keys():
        ticks = [a - b for a, b in zip(after['cpu'][cpu], before['cpu'][cpu])]
        if sum(ticks) > 0 and min(ticks) >= 0:
            result['cpu_busy_pct'][cpu] = 100 * (sum(ticks) - ticks[3] - ticks[4]) / sum(ticks)
    b, a = before['tcp']['connections'], after['tcp']['connections']
    stable = a.keys() & b.keys()
    fields = ('bytes_acked', 'bytes_received', 'bytes_retrans', 'bytes_sent')
    # ss omits zero-valued TCP_INFO fields (notably bytes_retrans).
    per_socket = {k: {f: a[k].get(f, 0) - b[k].get(f, 0) for f in fields
                      if a[k].get(f, 0) >= b[k].get(f, 0)} for k in stable}
    tcp_elapsed = (after['tcp']['begin']['monotonic_s'] - before['tcp']['begin']['monotonic_s'])
    totals = {f: sum(values.get(f, 0) for values in per_socket.values()) for f in fields}
    result['tcp'] = dict(elapsed_s=tcp_elapsed, stable_socket_count=len(stable),
                         opened=sorted(a.keys() - b.keys()), closed=sorted(b.keys() - a.keys()),
                         counter_resets={k: [f for f in fields if a[k].get(f, 0) < b[k].get(f, 0)]
                                         for k in stable},
                         per_socket_delta=per_socket, delta=totals,
                         gbps={f: v * 8 / tcp_elapsed / 1e9 for f, v in totals.items()})
    return result


def capture(args):
    metadata = dict(hostname=socket.gethostname(), kernel=os.uname().release,
                    cmdline=read('/proc/cmdline'), interface=args.interface,
                    peers=args.peer, scheduled_start_unix_s=args.start_at,
                    requested_duration_s=args.duration,
                    ethtool={flag: command(['ethtool', flag, args.interface])
                             for flag in ('-i', '-a', '-g', '-c', '-k', '-l', '-x')},
                    link=command(['ip', '-details', '-statistics', 'link', 'show', 'dev', args.interface]),
                    addresses=command(['ip', 'address', 'show', 'dev', args.interface]),
                    lscpu=command(['lscpu', '-e']),
                    device=str(Path('/sys/class/net', args.interface, 'device').resolve()))
    wait_until(args.start_at)
    metadata['start_lateness_s'] = time.time() - args.start_at
    samples = []
    start = time.monotonic()
    index = 0
    while True:
        samples.append(snapshot(args.interface, args.peer))
        if len(samples) > 1 and samples[-1]['begin']['monotonic_s'] >= start + args.duration:
            break
        index += 1
        delay = min(start + index * args.interval, start + args.duration) - time.monotonic()
        if delay > 0:
            time.sleep(delay)
    errors = [dict(sample=i, tool=key, **s[key])
              for i, s in enumerate(samples)
              for key in ('ethtool_raw',) if s[key]['returncode']]
    errors.extend(dict(sample=i, tool='ss', **s['tcp']['raw'])
                  for i, s in enumerate(samples) if s['tcp']['raw']['returncode'])
    if metadata['start_lateness_s'] > 2:
        errors.append(dict(tool='timing', error='capture started more than 2 seconds late'))
    if args.peer and not any(s['tcp']['connections'] for s in samples):
        errors.append(dict(tool='ss', error='no established workload sockets observed'))
    print(json.dumps(dict(schema_version=1, metadata=metadata, samples=samples,
                          summary=summarize(samples[0], samples[-1]), errors=errors)))
    return int(bool(errors))


def barrier(output, vm_id):
    output = Path(output)
    (output / ('ready-vm' + str(vm_id))).touch()
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        if (output / 'failed.json').exists():
            raise RuntimeError('telemetry coordinator failed; see ' + str(output))
        if (output / 'start.json').exists():
            wait_until(json.loads((output / 'start.json').read_text())['unix_s'])
            return 0
        time.sleep(.2)
    raise TimeoutError('timed out waiting for telemetry start')


def endpoint_command(endpoint, arguments):
    python = ['sudo', '-n', 'python3', '-'] + arguments
    return endpoint['ssh'] + [shlex.join(python)] if endpoint['ssh'] else python


def iio_mean_rates(path):
    """Mean each PCM event at each location, ignoring repeated CSV headers."""
    groups = {}
    with Path(path).open() as stream:
        for row in csv.DictReader(stream):
            if row.get('Socket') == 'Socket':
                continue
            key = tuple(row.get(k, '') for k in ('Socket', 'Name', 'Part'))
            metrics = groups.setdefault(key, {})
            for field, value in row.items():
                if field and value and any(token in field for token in ('IB write', 'IB read', 'IOTLB', 'IOMMU')):
                    try:
                        number = float(value)
                    except ValueError:
                        continue
                    if math.isfinite(number):
                        metrics.setdefault(field, []).append(number)
    return {key: {field: sum(values) / len(values) for field, values in metrics.items()}
            for key, metrics in groups.items()}


def render_summary(output):
    """Render the raw evidence for inclusion after the existing throughput report."""
    output = Path(output)
    manifest = json.loads((output / 'manifest.json').read_text())
    lines = ['', '======= Counter recording summary =======',
             f"Status: {manifest.get('status', 'incomplete')}",
             f"Window: {manifest['duration_s']:g} s; sampling: {manifest['interval_s']:g} s",
             'Raw evidence: counters/']
    if manifest.get('error'):
        lines.append('Error: ' + manifest['error'])
    received = {}
    for name in ['host', 'peer'] + ['vm' + str(i) for i in range(manifest['num_vms'])]:
        try:
            evidence = json.loads((output / (name + '.json')).read_text())
        except (OSError, ValueError):
            lines.append(f'{name}: capture unavailable (see counters/{name}.log)')
            continue
        summary = evidence['summary']
        elapsed = summary['elapsed_s']
        cpu = summary['cpu_busy_pct'].get('cpu')
        lines.append(f"--- {name}: {evidence['metadata']['interface']}; measured {elapsed:.3f} s ---")
        if cpu is not None:
            lines.append(f'  CPU busy (all CPUs, idle/iowait excluded): {cpu:.2f}%')
        nic = summary['delta']['ethtool']
        sysfs = summary['delta']['sysfs']
        lines.append('  NIC sysfs RX/TX: ' + ' / '.join(
            f'{sysfs[key] * 8 / elapsed / 1e9:.3f}' if key in sysfs else 'unavailable'
            for key in ('rx_bytes', 'tx_bytes')) + ' Gbit/s')
        if name in ('host', 'peer'):
            lines.append('  NIC physical RX/TX: ' + ' / '.join(
                f'{nic[key] * 8 / elapsed / 1e9:.3f}' if key in nic else 'unavailable'
                for key in ('rx_bytes_phy', 'tx_bytes_phy')) + ' Gbit/s')
            if name == 'host':
                lines.append('  PF sysfs bytes can exclude VF passthrough traffic; use physical counters above.')
        for key in ('rx_discards_phy', 'rx_out_of_buffer', 'rx_prio0_buf_discard',
                    'rx_pause_ctrl_phy', 'tx_pause_ctrl_phy', 'rx_pause_duration_phy', 'tx_pause_duration_phy'):
            if key in nic:
                lines.append(f'  {key} delta: {nic[key]}')
        for key in ('Tcp.RetransSegs', 'TcpExt.TCPTimeouts', 'TcpExt.TCPRcvQDrop'):
            if key in summary['delta']['protocol']:
                lines.append(f"  {key} delta: {summary['delta']['protocol'][key]}")
        if evidence['metadata']['peers']:
            tcp = summary['tcp']
            received[name] = tcp['gbps']['bytes_received']
            lines.append(f"  TCP received / acked: {tcp['gbps']['bytes_received']:.3f} / "
                         f"{tcp['gbps']['bytes_acked']:.3f} Gbit/s ({tcp['elapsed_s']:.3f} s)")
            lines.append(f"  TCP retransmitted bytes: {tcp['delta']['bytes_retrans']}; "
                         f"stable sockets: {tcp['stable_socket_count']}; "
                         f"opened/closed: {len(tcp['opened'])}/{len(tcp['closed'])}")
        resets = sum(sum(key != 'Tcp.CurrEstab' for key in values)
                     for values in summary['counter_resets'].values())
        if resets or evidence['errors']:
            lines.append(f"  Counter resets: {resets}; capture errors: {len(evidence['errors'])}")
    receivers = ['vm' + str(i) for i in range(manifest['num_vms'])] if manifest['direction'] == 'RX' else ['peer']
    if all(name in received for name in receivers):
        lines.append(f"Delivered {manifest['direction']} over counter window: "
                     f"{sum(received[name] for name in receivers):.3f} Gbit/s")
    lines.append('--- Host IIO (mean rates; event groups are multiplexed) ---')
    try:
        means = iio_mean_rates(output / 'iio.csv')
        # Report the busiest DMA and translation locations; retain every location in CSV.
        selected = set()
        for fields in (('IB write', 'IB read'), tuple({field for values in means.values()
                                                    for field in values if 'IOTLB' in field})):
            ranked = sorted(means, key=lambda key: sum(means[key].get(f, 0) for f in fields), reverse=True)
            selected.update(key for key in ranked[:4] if sum(means[key].get(f, 0) for f in fields) > 0)
        for key in sorted(selected):
            values = means[key]
            lines.append('  ' + ' / '.join(key) + ': ' + '; '.join(
                f'{field}={value / 1e9:.3f} GB/s' if field in ('IB write', 'IB read')
                else f'{field}={value / 1e6:.3f} million/s' for field, value in values.items()))
        if not selected:
            lines.append('  No nonzero DMA/IOTLB samples available.')
        lines.append('  Showing top four DMA and top four IOTLB locations; all locations are in counters/iio.csv.')
    except (OSError, ValueError):
        lines.append('  IIO samples unavailable; see counters/iio.log.')
    return '\n'.join(lines) + '\n'


def coordinate(args):
    output = Path(args.output).resolve()
    source = Path(__file__).read_text()
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in ('manifest.json', 'armed.json', 'start.json', 'failed.json')):
        raise FileExistsError('recording directory already contains evidence: ' + str(output))
    # Retain the exact collector used with the evidence.
    (output / 'collector.py').write_text(source)
    endpoints = [dict(name='host', interface=args.host_interface, ssh=[], peers=[]),
                 dict(name='peer', interface=args.peer_interface, ssh=shlex.split(args.peer_ssh),
                      peers=[args.guest_data_ip_base.rsplit('.', 1)[0] + '.' +
                             str(int(args.guest_data_ip_base.rsplit('.', 1)[1]) + i)
                             for i in range(args.num_vms)])]
    for i in range(args.num_vms):
        endpoints.append(dict(name='vm' + str(i), interface=args.guest_interface,
                              ssh=shlex.split(args.guest_ssh) + [args.guest_user + '@' +
                                  args.guest_ip_base.rsplit('.', 1)[0] + '.' +
                                  str(int(args.guest_ip_base.rsplit('.', 1)[1]) + i)],
                              peers=[args.peer_ip]))
    children = []
    handles = []
    manifest = dict(schema_version=1, experiment=args.experiment, direction=args.direction,
                    num_vms=args.num_vms, total_cores=args.total_cores,
                    active_cores=args.active_cores, flows=args.flows, viommu=args.viommu,
                    duration_s=args.duration, interval_s=args.interval, endpoints=[])
    try:
        def check(endpoint):
            begin = time.time()
            try:
                p = subprocess.run(endpoint_command(endpoint, ['probe', '--interface', endpoint['interface']]),
                                   input=source, text=True, capture_output=True, timeout=45)
            except subprocess.TimeoutExpired:
                raise TimeoutError(endpoint['name'] + ' preflight timed out') from None
            end = time.time()
            if p.returncode:
                raise RuntimeError(endpoint['name'] + ' preflight: ' + p.stderr)
            info = json.loads(p.stdout)
            if info['missing']:
                raise RuntimeError(endpoint['name'] + ' missing: ' + ', '.join(info['missing']))
            # Correct endpoint wall-clock skew using SSH round-trip midpoint.
            endpoint['clock_offset_s'] = info['unix_s'] - (begin + end) / 2
            endpoint['clock_uncertainty_s'] = (end - begin) / 2
            endpoint['hostname'] = info['hostname']

        with concurrent.futures.ThreadPoolExecutor(max_workers=len(endpoints)) as pool:
            list(pool.map(check, endpoints))
        pcm = Path(args.pcm_bin).resolve()
        pcm_dir = Path(args.pcm_dir).resolve()
        if not pcm.is_file() or not os.access(pcm, os.X_OK) or not pcm_dir.is_dir():
            raise RuntimeError('PCM binary or event directory missing; set PCM_IIO_BIN / PCM_IIO_DIR')
        # PCM reads model-specific opCode files from cwd. Preserve all candidates.
        event_dir = output / 'pcm-events'
        event_dir.mkdir()
        for path in pcm_dir.glob('opCode*.txt'):
            shutil.copy2(path, event_dir / path.name)
        if not list(event_dir.iterdir()):
            raise RuntimeError('no PCM opCode*.txt event files in ' + str(pcm_dir))
        if command(['pgrep', '-x', 'pcm-iio'])['returncode'] == 0:
            raise RuntimeError('pcm-iio is already running; refusing to share IIO counters')
        topology = command(['sudo', '-n', str(pcm), '--list'], timeout=45, cwd=event_dir)
        atomic_json(output / 'iio-topology.json', topology)
        if topology['returncode']:
            raise RuntimeError('PCM --list failed; see iio-topology.json')
        manifest['endpoints'] = [{k: v for k, v in e.items() if k != 'ssh'} for e in endpoints]
        manifest['pcm'] = dict(binary=str(pcm), event_directory=str(event_dir),
                               source_event_directory=str(pcm_dir))
        atomic_json(output / 'manifest.json', manifest)
        atomic_json(output / 'armed.json', stamp())
        deadline = time.monotonic() + args.ready_timeout
        while not all((output / ('ready-vm' + str(i))).exists() for i in range(args.num_vms)):
            if time.monotonic() > deadline:
                raise TimeoutError('not all VMs reached the post-warmup barrier')
            time.sleep(.2)
        start = time.time() + START_LEAD_S
        for endpoint in endpoints:
            arguments = ['capture', '--interface', endpoint['interface'], '--duration', str(args.duration),
                         '--interval', str(args.interval), '--start-at', str(start + endpoint['clock_offset_s'])]
            for peer in endpoint['peers']:
                arguments += ['--peer', peer]
            stdout = (output / (endpoint['name'] + '.json')).open('w')
            stderr = (output / (endpoint['name'] + '.log')).open('w')
            handles += [stdout, stderr]
            process = subprocess.Popen(endpoint_command(endpoint, arguments), stdin=subprocess.PIPE,
                                       stdout=stdout, stderr=stderr, text=True)
            process.stdin.write(source)
            process.stdin.close()
            children.append((endpoint['name'], process))
        atomic_json(output / 'start.json', dict(unix_s=start))
        wait_until(start)
        pcm_log = (output / 'iio.log').open('w')
        handles.append(pcm_log)
        pcm_argv = ['sudo', '-n', str(pcm), str(args.interval),
                    '-i=' + str(math.ceil(args.duration / args.interval)), '-csv=' + str(output / 'iio.csv')]
        pcm_begin = stamp()
        pcm_process = subprocess.Popen(pcm_argv, cwd=event_dir, stdout=pcm_log, stderr=subprocess.STDOUT)
        children.append(('iio', pcm_process))
        statuses = {}
        deadline = time.monotonic() + args.duration + 90
        for name, process in children:
            statuses[name] = process.wait(timeout=max(1, deadline - time.monotonic()))
        for handle in handles:
            handle.close()
        manifest['pcm'].update(argv=pcm_argv, begin=pcm_begin, end=stamp())
        manifest['returncodes'] = statuses
        manifest['scheduled_start_unix_s'] = start
        # Empty/truncated data is a failed recording even if the command returned 0.
        failures = [name for name, rc in statuses.items() if rc]
        for endpoint in endpoints:
            evidence = json.loads((output / (endpoint['name'] + '.json')).read_text())
            if evidence['errors']:
                failures.append(endpoint['name'])
        csv_path = output / 'iio.csv'
        if not csv_path.exists() or csv_path.stat().st_size == 0:
            failures.append('empty iio.csv')
        else:
            with csv_path.open() as stream:
                rows = csv.DictReader(stream)
                columns = rows.fieldnames or []
                if not (any('IOTLB' in c for c in columns) and any('IOMMU' in c for c in columns)):
                    failures.append('IIO event configuration lacks IOTLB/IOMMU counters')
                if next(rows, None) is None:
                    failures.append('iio.csv has no samples')
        manifest['status'] = 'failed' if failures else 'complete'
        atomic_json(output / 'manifest.json', manifest)
        if failures:
            raise RuntimeError('recording failed: ' + ', '.join(failures))
        return 0
    except BaseException as exc:
        manifest.update(status='failed', error=str(exc))
        atomic_json(output / 'manifest.json', manifest)
        atomic_json(output / 'failed.json', dict(error=str(exc), **stamp()))
        raise
    finally:
        for _, process in children:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in handles:
            handle.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    p = sub.add_parser('probe')
    p.add_argument('--interface', required=True)
    p = sub.add_parser('capture')
    p.add_argument('--interface', required=True)
    p.add_argument('--peer', action='append', default=[])
    p.add_argument('--duration', type=float, default=20)
    p.add_argument('--interval', type=float, default=1)
    p.add_argument('--start-at', type=float, required=True)
    p = sub.add_parser('barrier')
    p.add_argument('output')
    p.add_argument('vm_id', type=int)
    p = sub.add_parser('summary')
    p.add_argument('output')
    p = sub.add_parser('coordinate')
    for name in ('output', 'experiment', 'direction', 'viommu', 'host-interface', 'peer-interface',
                 'peer-ip', 'peer-ssh', 'guest-interface', 'guest-ssh', 'guest-user', 'guest-ip-base',
                 'guest-data-ip-base',
                 'pcm-bin', 'pcm-dir'):
        p.add_argument('--' + name, required=True)
    for name in ('num-vms', 'total-cores', 'active-cores', 'flows'):
        p.add_argument('--' + name, type=int, required=True)
    p.add_argument('--duration', type=float, default=20)
    p.add_argument('--interval', type=float, default=1)
    p.add_argument('--ready-timeout', type=float, default=600)
    args = parser.parse_args()
    for name in ('duration', 'interval'):
        if hasattr(args, name) and (not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0):
            parser.error('--' + name + ' must be finite and positive')
    if args.mode == 'probe':
        print(json.dumps(probe(args.interface)))
        return 0
    if args.mode == 'capture':
        return capture(args)
    if args.mode == 'barrier':
        return barrier(args.output, args.vm_id)
    if args.mode == 'summary':
        summary = render_summary(args.output)
        (Path(args.output) / 'summary.txt').write_text(summary)
        print(summary, end='')
        return 0
    # Ensure SIGTERM follows the same cleanup path as ordinary failures.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError('terminated')))
    return coordinate(args)


if __name__ == '__main__':
    sys.exit(main())
