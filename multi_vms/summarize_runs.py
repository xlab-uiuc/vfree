#!/usr/bin/env python3
"""Aggregate independent launcher repetitions, never pooling VMs or PCM samples."""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics

from record_sweep import atomic_json, iio_mean_rates


def finite(value):
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('nonfinite metric')
    return value


def run_metrics(result):
    config = result['configuration']
    root = Path(result['report_directory'])
    metrics = {}
    vms = {}
    names = result.get('vm_names') or [p.name[len(result['experiment']) + 1:]
                                      for p in root.parent.glob(result['experiment'] + '-*-vm[0-9]*')
                                      if p.is_dir() and p.name.rsplit('-vm', 1)[-1].isdigit()]
    for name in names:
        index = int(name.rsplit('-vm', 1)[1])
        if index in vms:
            raise ValueError('duplicate VM index ' + str(index))
        with (root.parent / (result['experiment'] + '-' + name) / 'tput_metrics.dat').open() as stream:
            rows = list(csv.DictReader(stream))
        if len(rows) != 1:
            raise ValueError('expected one metrics row for ' + name)
        row = rows[0]
        vms[index] = (finite(row['net_tput_mean']), finite(row['cpu_utils_mean']))
    if set(vms) != set(range(config['num_vms'])):
        raise ValueError('missing or unexpected per-VM metrics')
    metrics['throughput.total_gbps'] = sum(values[0] for values in vms.values())
    metrics['throughput.vm_mean_gbps'] = statistics.mean(values[0] for values in vms.values())
    metrics['cpu.guest_mean_pct'] = statistics.mean(values[1] for values in vms.values())
    for index, (throughput, cpu) in vms.items():
        metrics[f'vm{index}.throughput_gbps'] = throughput
        metrics[f'vm{index}.cpu_util_pct'] = cpu
    if config['record_counters'] == 'off':
        return metrics
    counters = root / 'counters'
    manifest = json.loads((counters / 'manifest.json').read_text())
    if manifest.get('status') != 'complete' or any(manifest['returncodes'].values()):
        raise ValueError('counter recording did not complete')
    if any(manifest[key] != config[key] for key in ('direction', 'viommu', 'num_vms',
                                                   'total_cores', 'active_cores', 'flows', 'duration_s', 'interval_s')):
        raise ValueError('counter recording configuration mismatch')
    received = {}
    for name in ['host', 'peer'] + [f'vm{i}' for i in range(config['num_vms'])]:
        evidence = json.loads((counters / (name + '.json')).read_text())
        if evidence['errors']:
            raise ValueError(name + ' capture has errors')
        summary = evidence['summary']
        elapsed = finite(summary['elapsed_s'])
        if elapsed <= 0:
            raise ValueError('invalid capture duration')
        cpu = summary['cpu_busy_pct'].get('cpu')
        if cpu is not None:
            metrics[name + '.cpu_busy_pct'] = finite(cpu)
        for group, keys in (
            ('ethtool', ('rx_discards_phy', 'rx_out_of_buffer', 'rx_prio0_buf_discard',
                         'rx_pause_ctrl_phy', 'tx_pause_ctrl_phy', 'rx_pause_duration_phy', 'tx_pause_duration_phy')),
            ('protocol', ('Tcp.RetransSegs', 'TcpExt.TCPTimeouts', 'TcpExt.TCPRcvQDrop')),
        ):
            for key in keys:
                if key in summary['delta'][group]:
                    metrics[f'{name}.{key}.delta'] = finite(summary['delta'][group][key])
        for group, keys in (('sysfs', ('rx_bytes', 'tx_bytes')), ('ethtool', ('rx_bytes_phy', 'tx_bytes_phy'))):
            for key in keys:
                if key in summary['delta'][group]:
                    metrics[f'{name}.{key}.gbps'] = finite(summary['delta'][group][key]) * 8 / elapsed / 1e9
        if evidence['metadata']['peers']:
            tcp = summary['tcp']
            for key, value in tcp['gbps'].items():
                metrics[f'{name}.tcp.{key}.gbps'] = finite(value)
            metrics[name + '.tcp.bytes_retrans.delta'] = finite(tcp['delta']['bytes_retrans'])
            metrics[name + '.tcp.stable_sockets'] = tcp['stable_socket_count']
            metrics[name + '.tcp.opened_sockets'] = len(tcp['opened'])
            metrics[name + '.tcp.closed_sockets'] = len(tcp['closed'])
            received[name] = finite(tcp['gbps']['bytes_received'])
    receivers = [f'vm{i}' for i in range(config['num_vms'])] if config['direction'] == 'RX' else ['peer']
    metrics['throughput.counter_window_gbps'] = sum(received[name] for name in receivers)
    means = iio_mean_rates(counters / 'iio.csv')
    if not any('IOMMU' in field for values in means.values() for field in values):
        raise ValueError('no IOMMU samples')
    for location, values in means.items():
        for field, value in values.items():
            metrics['iio.' + '/'.join(location) + '.' + field + '.per_s'] = finite(value)
    return metrics


def aggregate(directory, expected_runs):
    directory = Path(directory).resolve()
    records = []
    configuration = None
    seen = set()
    for repetition in range(1, expected_runs + 1):
        path = directory / f'rep-{repetition:03d}'
        record = dict(repetition=repetition, status='pending', directory=str(path))
        records.append(record)
        if not path.exists():
            continue
        try:
            rc = int((path / 'exit-code').read_text().strip())
            if rc:
                raise ValueError('launcher exit code ' + str(rc))
            result = json.loads((path / 'result.json').read_text())
            record.update(experiment=result.get('experiment'), report_directory=result.get('report_directory'))
            if result['status'] != 'complete' or result['exit_code']:
                raise ValueError('launcher reported failure')
            if not result['experiment'] or not result['report_directory']:
                raise ValueError('missing experiment identity')
            identity = str(Path(result['report_directory']).resolve())
            if identity in seen:
                raise ValueError('report directory reused by another repetition')
            seen.add(identity)
            values = run_metrics(result)
            if configuration is not None and result['configuration'] != configuration:
                raise ValueError('configuration differs from other successful repetitions')
            configuration = result['configuration']
            record.update(status='complete', metrics=values)
        except (OSError, ValueError, KeyError, TypeError, ZeroDivisionError) as exc:
            record.update(status='failed', error=str(exc))
    good = [record for record in records if record['status'] == 'complete']
    keys = sorted({key for record in good for key in record['metrics']})
    metrics = {}
    for key in keys:
        values = [record['metrics'][key] for record in good if key in record['metrics']]
        metrics[key] = dict(n=len(values), mean=statistics.mean(values),
                            stddev=statistics.stdev(values) if len(values) > 1 else None)
    summary = dict(schema_version=1, expected_runs=expected_runs, successful_runs=len(good),
                   failed_runs=sum(r['status'] == 'failed' for r in records),
                   pending_runs=sum(r['status'] == 'pending' for r in records),
                   configuration=configuration, stddev_method='sample (n - 1)', metrics=metrics, runs=records)
    atomic_json(directory / 'summary.json', summary)
    with (directory / 'runs.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['repetition', 'status', 'experiment', 'report_directory', 'error'] + keys)
        for record in records:
            writer.writerow([record['repetition'], record['status'], record.get('experiment', ''),
                             record.get('report_directory', ''), record.get('error', '')] +
                            [record.get('metrics', {}).get(key, '') for key in keys])
    lines = ['======= Repeated configuration: ' + directory.name + ' =======',
             f"Runs: {len(good)}/{expected_runs} successful; {summary['failed_runs']} failed; {summary['pending_runs']} pending",
             'Statistics are across independent repetitions; stddev uses n - 1 (N/A for fewer than two).']
    if configuration:
        lines.append('Configuration: ' + json.dumps(configuration, sort_keys=True))
    for record in records:
        lines.append(f"  Rep {record['repetition']}: {record['status']} " +
                     (record.get('report_directory') or record.get('error') or 'not started'))
        if record['status'] == 'failed' and record.get('report_directory'):
            lines.append('    ' + record['error'])
    lines += ['', f"{'Metric':<75} {'Mean':>16} {'Stddev':>16} {'n':>5}"]
    # Keep the text report readable: all IIO locations remain in JSON and CSV.
    locations = {key.rsplit('.', 2)[0] for key in keys if key.startswith('iio.')}
    busy = sorted(locations, key=lambda prefix: sum(metrics.get(prefix + '.' + field + '.per_s', {}).get('mean', 0)
                  for field in ('IB write', 'IB read', 'IOTLB Lookup', 'IOTLB All Lookup')), reverse=True)[:4]
    for key, values in metrics.items():
        if key.startswith('iio.') and not any(key.startswith(prefix + '.') for prefix in busy):
            continue
        stddev = f"{values['stddev']:.6f}" if values['stddev'] is not None else 'N/A'
        lines.append(f"{key:<75} {values['mean']:>16.6f} {stddev:>16} {values['n']:>5}")
    if locations:
        lines.append('IIO: text shows four busiest locations; summary.json and runs.csv include all locations.')
    lines.append('Failed or incomplete repetitions are excluded; missing metrics are not replaced with zero.')
    (directory / 'summary-details.txt').write_text('\n'.join(lines) + '\n')
    text = throughput_summary(summary, directory.name)
    (directory / 'summary.txt').write_text(text)
    return summary, text


def throughput_summary(summary, name):
    """Keep the default report focused on throughput; retain counters separately."""
    config = summary['configuration']
    metrics = summary['metrics']
    lines = ['======= Repeated configuration: ' + name + ' =======']
    if config:
        lines.append(f"{config['direction']} | vIOMMU {config['viommu']} | "
                     f"{config['num_vms']} VMs | {config['total_cores']} cores/VM | "
                     f"{config['active_cores']} active/VM | {config['flows']} flows/VM")
    lines += [f"Runs: {summary['successful_runs']}/{summary['expected_runs']} successful; "
              f"{summary['failed_runs']} failed; {summary['pending_runs']} pending",
              'Means and sample stddevs are across repetitions (n - 1; N/A for one run).']

    def table(title, rows):
        lines.extend(['', title, f"{'Measurement':<44} {'Mean':>12} {'Stddev':>12} {'n':>5}"])
        for label, key in rows:
            values = metrics.get(key)
            if values is None:
                lines.append(f"{label:<44} {'N/A':>12} {'N/A':>12} {0:>5}")
            else:
                stddev = f"{values['stddev']:.4f}" if values['stddev'] is not None else 'N/A'
                lines.append(f"{label:<44} {values['mean']:>12.4f} {stddev:>12} {values['n']:>5}")

    aggregate_rows = [('Total: sum of VM iperf throughput', 'throughput.total_gbps')]
    if 'throughput.counter_window_gbps' in metrics:
        aggregate_rows.append(('Total: TCP receive over counter window', 'throughput.counter_window_gbps'))
    table('Aggregate throughput (Gbit/s)', aggregate_rows)
    vm_keys = sorted((key for key in metrics if key.startswith('vm') and key.endswith('.throughput_gbps')),
                     key=lambda key: int(key.split('.')[0][2:]))
    table('Per-VM throughput (iperf, Gbit/s)',
          [(key.split('.')[0].upper(), key) for key in vm_keys] +
          [('Mean across VMs in each run', 'throughput.vm_mean_gbps')])
    if 'throughput.counter_window_gbps' in metrics:
        lines += ['', 'Iperf and TCP counter totals use different measurement windows.']
    for record in summary['runs']:
        if record['status'] != 'complete':
            lines.append(f"Rep {record['repetition']}: {record['status']}: " + record.get('error', 'not started'))
    lines += ['', 'Detailed NIC/CPU/TCP/IOMMU statistics and run paths: summary-details.txt',
              'All metrics: summary.json | Per-repetition values: runs.csv']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    parser.add_argument('--expected-runs', type=int, required=True)
    args = parser.parse_args()
    if args.expected_runs < 1:
        parser.error('--expected-runs must be positive')
    summary, text = aggregate(args.directory, args.expected_runs)
    print(text, end='')
    return int(summary['successful_runs'] != args.expected_runs)


if __name__ == '__main__':
    raise SystemExit(main())
