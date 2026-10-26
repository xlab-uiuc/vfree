#!/usr/bin/env python3
"""Per-run NIC/TCP-protocol and host IIO diagnostics; only the coordinator writes to the host report tree.

The same file is streamed to remote Python interpreters, so endpoints need no
checkout or installed Python packages. Endpoint configuration belongs to
utils/setup-envir.sh and utils/setup-host.sh; CPU utilization and application throughput are collected by the existing workload scripts.
"""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
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


def snapshot(interface):
    begin = stamp()
    protocols = {}
    for name in ('net/snmp', 'net/netstat'):
        lines = (read('/proc/' + name) or '').splitlines()
        for header, values in zip(lines[::2], lines[1::2]):
            labels, counts = header.split(), values.split()
            protocols.update({labels[0].rstrip(':') + '.' + key: int(value)
                              for key, value in zip(labels[1:], counts[1:])})
    nic = command(['ethtool', '-S', interface])
    nic_values = {m[1]: int(m[2]) for m in re.finditer(
        r'^\s*(\S+):\s*(\d+)\s*$', nic['stdout'], re.M)}
    stats = Path('/sys/class/net', interface, 'statistics')
    return dict(begin=begin, end=stamp(), protocol=protocols,
                ethtool=nic_values, ethtool_raw=nic,
                sysfs={p.name: int(p.read_text()) for p in stats.iterdir()})


def summarize(before, after):
    result = dict(elapsed_s=after['begin']['monotonic_s'] - before['begin']['monotonic_s'],
                  delta={}, counter_resets={})
    for group in ('ethtool', 'protocol', 'sysfs'):
        common = {key for key in before[group].keys() & after[group].keys()
                  if not key.startswith('outbound_pci_stalled_') and key != 'Tcp.CurrEstab'}
        result['delta'][group] = {key: after[group][key] - before[group][key]
                                  for key in common if after[group][key] >= before[group][key]}
        result['counter_resets'][group] = [key for key in common
                                           if after[group][key] < before[group][key]]
    return result


def capture(args):
    metadata = dict(hostname=socket.gethostname(), kernel=os.uname().release,
                    cmdline=read('/proc/cmdline'), interface=args.interface,
                    scheduled_start_unix_s=args.start_at,
                    requested_duration_s=args.duration,
                    ethtool={flag: command(['ethtool', flag, args.interface])
                             for flag in ('-i', '-a', '-g', '-c', '-k', '-l', '-x')},
                    link=command(['ip', '-details', '-statistics', 'link', 'show', 'dev', args.interface]),
                    addresses=command(['ip', 'address', 'show', 'dev', args.interface]),
                    device=str(Path('/sys/class/net', args.interface, 'device').resolve()))
    if getattr(args, 'controlled', False):
        # Preparation can take seconds under load. Do it before choosing a start.
        print(json.dumps(dict(event='ready', **stamp())), file=sys.stderr, flush=True)
        message = json.loads(sys.stdin.readline())
        if message['command'] != 'clock':
            raise RuntimeError('expected clock request')
        print(json.dumps(dict(event='clock', **stamp())), file=sys.stderr, flush=True)
        message = json.loads(sys.stdin.readline())
        if message['command'] != 'start':
            raise RuntimeError('expected capture start')
        args.start_at = message['unix_s']
        metadata['scheduled_start_unix_s'] = args.start_at
    wait_until(args.start_at)
    metadata['start_lateness_s'] = time.time() - args.start_at
    samples = [snapshot(args.interface)]
    # Diagnostics need before/after readings. PCM performs periodic IIO sampling.
    deadline = samples[0]['begin']['monotonic_s'] + args.duration
    time.sleep(max(0, deadline - time.monotonic()))
    samples.append(snapshot(args.interface))
    errors = [dict(sample=i, tool=key, **s[key])
              for i, s in enumerate(samples)
              for key in ('ethtool_raw',) if s[key]['returncode']]
    if metadata['start_lateness_s'] > 2:
        errors.append(dict(tool='timing', error='capture started more than 2 seconds late'))
    summary = summarize(samples[0], samples[-1])
    print(json.dumps(dict(schema_version=2, metadata=metadata, samples=samples,
                          summary=summary, errors=errors)))
    return int(bool(errors))


def endpoint_command(endpoint, arguments, controlled=False):
    if controlled:
        # Read a length-prefixed source, leaving stdin open for clock/start messages.
        bootstrap = "import sys; exec(compile(sys.stdin.read(int(sys.stdin.readline())), '<collector>', 'exec'))"
        python = ['sudo', '-n', 'python3', '-u', '-c', bootstrap] + arguments
    else:
        python = ['sudo', '-n', 'python3', '-'] + arguments
    return endpoint['ssh'] + [shlex.join(python)] if endpoint['ssh'] else python


def collector_messages(captures, event, timeout=120):
    messages = {}
    deadline = time.monotonic() + timeout
    with selectors.DefaultSelector() as selector:
        for endpoint, process, log in captures:
            selector.register(process.stderr, selectors.EVENT_READ, (endpoint, log))
        while selector.get_map():
            if time.monotonic() > deadline:
                pending = ', '.join(key.data[0]['name'] for key in selector.get_map().values())
                raise TimeoutError('collectors did not report ' + event + ': ' + pending)
            for key, _ in selector.select(.2):
                endpoint, log = key.data
                line = key.fileobj.readline()
                log.write(line)
                log.flush()
                try:
                    message = json.loads(line)
                except ValueError:
                    if not line:
                        raise RuntimeError(endpoint['name'] + ' collector failed before ' + event + '; see its .log')
                    # Preserve sudo/SSH warnings and tracebacks; EOF or the timeout
                    # determines whether a collector actually failed to prepare.
                    continue
                if message.get('event') != event:
                    raise RuntimeError(endpoint['name'] + ' unexpected collector event: ' + str(message))
                messages[endpoint['name']] = dict(message, received_unix_s=time.time())
                selector.unregister(key.fileobj)
    return messages


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
             f"Window: {manifest['duration_s']:g} s; IIO sampling: {manifest['interval_s']:g} s",
             'Raw evidence: counters/']
    if manifest.get('error'):
        lines.append('Error: ' + manifest['error'])
    for name in ['host', 'peer'] + ['vm' + str(i) for i in range(manifest['num_vms'])]:
        try:
            evidence = json.loads((output / (name + '.json')).read_text())
        except (OSError, ValueError):
            lines.append(f'{name}: capture unavailable (see counters/{name}.log)')
            continue
        summary = evidence['summary']
        elapsed = summary['elapsed_s']
        lines.append(f"--- {name}: {evidence['metadata']['interface']}; measured {elapsed:.3f} s ---")
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
        resets = sum(sum(key != 'Tcp.CurrEstab' for key in values)
                     for values in summary['counter_resets'].values())
        if resets or evidence['errors']:
            lines.append(f"  Counter resets: {resets}; capture errors: {len(evidence['errors'])}")
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


def collect(args):
    output = Path(args.output).resolve()
    source = Path(__file__).read_text()
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in ('manifest.json', 'armed.json', 'start.json', 'failed.json')):
        raise FileExistsError('recording directory already contains evidence: ' + str(output))
    endpoints = [dict(name='host', interface=args.host_interface, ssh=[]),
                 dict(name='peer', interface=args.peer_interface, ssh=shlex.split(args.peer_ssh))]
    for i in range(args.num_vms):
        endpoints.append(dict(name='vm'+str(i), interface=args.guest_interface,
            ssh=shlex.split(args.guest_ssh)+[args.guest_user+'@'+
                args.guest_ip_base.rsplit('.',1)[0]+'.'+
                str(int(args.guest_ip_base.rsplit('.',1)[1])+i)]))
    children = []
    handles = []
    captures = []
    log_threads = []
    manifest = dict(schema_version=1, experiment=args.experiment, direction=args.direction,
                    num_vms=args.num_vms, total_cores=args.total_cores,
                    active_cores=args.active_cores, flows=args.flows, viommu=args.viommu,
                    duration_s=args.duration, interval_s=args.interval, endpoints=[],
                    measurement_basis='network-and-iio-diagnostics')
    try:
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
        for endpoint in endpoints:
            arguments = ['capture', '--interface', endpoint['interface'], '--duration', str(args.duration),
                         '--controlled']
            stdout = (output / (endpoint['name'] + '.json')).open('w')
            stderr = (output / (endpoint['name'] + '.log')).open('w')
            handles += [stdout, stderr]
            process = subprocess.Popen(endpoint_command(endpoint, arguments, controlled=True), stdin=subprocess.PIPE,
                                       stdout=stdout, stderr=subprocess.PIPE, text=True)
            children.append((endpoint['name'], process))
            captures.append((endpoint, process, stderr))
            process.stdin.write(str(len(source)) + '\n' + source)
            process.stdin.flush()
        collector_messages(captures, 'ready')
        # Refresh clocks over established channels after metadata/preparation, so
        # SSH startup and the warmup duration do not bias the offsets.
        clock_begin = {}
        for endpoint, process, _ in captures:
            clock_begin[endpoint['name']] = time.time()
            process.stdin.write(json.dumps(dict(command='clock')) + '\n')
            process.stdin.flush()
        clocks = collector_messages(captures, 'clock', timeout=15)
        for endpoint, _, _ in captures:
            info = clocks[endpoint['name']]
            begin, end = clock_begin[endpoint['name']], info['received_unix_s']
            endpoint['clock_offset_s'] = info['unix_s'] - (begin + end) / 2
            endpoint['clock_uncertainty_s'] = (end - begin) / 2
        manifest['endpoints'] = [{k: v for k, v in e.items() if k != 'ssh'} for e in endpoints]
        start = time.time() + START_LEAD_S
        for endpoint, process, log in captures:
            process.stdin.write(json.dumps(dict(command='start', unix_s=start + endpoint['clock_offset_s'])) + '\n')
            process.stdin.close()
            thread = threading.Thread(target=shutil.copyfileobj, args=(process.stderr, log), daemon=True)
            thread.start()
            log_threads.append(thread)
        atomic_json(output / 'manifest.json', manifest)
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
        for thread in log_threads:
            thread.join(timeout=5)
        for handle in handles:
            handle.close()
        manifest['pcm'].update(argv=pcm_argv, begin=pcm_begin, end=stamp())
        manifest['returncodes'] = statuses
        manifest['scheduled_start_unix_s'] = start
        # Empty/truncated data is a failed recording even if the command returned 0.
        failures = {name for name, rc in statuses.items() if rc}
        for endpoint in endpoints:
            evidence = json.loads((output / (endpoint['name'] + '.json')).read_text())
            if evidence['errors']:
                failures.add(endpoint['name'])
        csv_path = output / 'iio.csv'
        if not csv_path.exists() or csv_path.stat().st_size == 0:
            failures.add('empty iio.csv')
        else:
            with csv_path.open() as stream:
                rows = csv.DictReader(stream)
                columns = rows.fieldnames or []
                if not (any('IOTLB' in c for c in columns) and any('IOMMU' in c for c in columns)):
                    failures.add('IIO event configuration lacks IOTLB/IOMMU counters')
                if next(rows, None) is None:
                    failures.add('iio.csv has no samples')
        manifest['status'] = 'failed' if failures else 'complete'
        atomic_json(output / 'manifest.json', manifest)
        if failures:
            raise RuntimeError('recording failed: ' + ', '.join(sorted(failures)))
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
        for thread in log_threads:
            thread.join(timeout=5)
        for _, process, log in captures:
            if not log.closed and not log_threads:
                log.write(process.stderr.read())
            process.stderr.close()
            if not process.stdin.closed:
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    pass
        for handle in handles:
            handle.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    p = sub.add_parser('capture')
    p.add_argument('--interface', required=True)
    p.add_argument('--duration', type=float, default=20)
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument('--start-at', type=float)
    group.add_argument('--controlled', action='store_true')
    p = sub.add_parser('summary')
    p.add_argument('output')
    p = sub.add_parser('collect')
    for name in ('output', 'experiment', 'direction', 'viommu', 'host-interface', 'peer-interface',
                 'peer-ssh', 'guest-interface', 'guest-ssh', 'guest-user', 'guest-ip-base',
                 'pcm-bin', 'pcm-dir'):
        p.add_argument('--' + name, required=True)
    for name in ('num-vms', 'total-cores', 'active-cores', 'flows'):
        p.add_argument('--' + name, type=int, required=True)
    p.add_argument('--duration', type=float, default=20)
    p.add_argument('--interval', type=float, default=1)
    args = parser.parse_args()
    for name in ('duration', 'interval'):
        if hasattr(args, name) and (not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0):
            parser.error('--' + name + ' must be finite and positive')
    if args.mode == 'capture':
        return capture(args)
    if args.mode == 'summary':
        summary = render_summary(args.output)
        (Path(args.output) / 'summary.txt').write_text(summary)
        print(summary, end='')
        return 0
    # Ensure SIGTERM follows the same cleanup path as ordinary failures.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError('terminated')))
    return collect(args)


if __name__ == '__main__':
    sys.exit(main())
