#!/usr/bin/env python3
"""Measure task CPU energy/GPU time and, only when unplugged, battery discharge.

Requires macOS and clang, no administrator privileges. Task energy excludes OS
helpers and WindowServer; battery discharge includes the entire computer.
Use --require-battery to refuse AC power rather than call an AC run a battery test.
The battery Wh value integrates sampled current/voltage, not an external meter.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

from measure_resources import RUsage

BATTERY_UNITS_SOURCE = "https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/pwr_mgt/IOPMPowerSource.h"
TASK_UNITS_SOURCE = "https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c"


def signed_current(value):
    if type(value) is not int:
        raise ValueError("Missing or non-integer battery current")
    # IORegistry can serialize a negative OSNumber as unsigned 32/64-bit.
    if 2**63 <= value < 2**64:
        value -= 2**64
    elif 2**31 <= value < 2**32:
        value -= 2**32
    if not -100_000 <= value <= 100_000:
        raise ValueError("Implausible battery current")
    return value


def battery_sample():
    data = plistlib.loads(subprocess.check_output(
        ['/usr/sbin/ioreg', '-r', '-c', 'AppleSmartBattery', '-a'], timeout=10))
    if not data:
        return {'available':False, 'external_power':None, 'charging':None,
                'capacity':None, 'capacity_max':None, 'voltage_mv':None,
                'current_ma':None, 'battery_discharge_w':None}
    if len(data) != 1:
        raise RuntimeError("Expected one internal battery")
    value = data[0]
    volts = value.get('Voltage')
    if type(volts) is not int or not 1000 <= volts <= 30000:
        raise ValueError("Missing or implausible battery voltage")
    current = signed_current(value.get('Amperage'))
    external = value.get('ExternalConnected')
    charging = value.get('IsCharging')
    if type(external) is not bool or type(charging) is not bool:
        raise ValueError("Missing battery power-source flags")
    # Preserve only measurements: no device serial, registry ID or other metadata.
    return {'available':True, 'external_power': external, 'charging': charging,
            'capacity': value.get('CurrentCapacity'), 'capacity_max': value.get('MaxCapacity'),
            'voltage_mv': volts, 'current_ma': current,
            'battery_discharge_w': -current * volts / 1e6 if not external and not charging and current <= 0 else None}


def integrate_discharge(samples, interval):
    watt_seconds = covered = 0.0
    for a, b in zip(samples, samples[1:]):
        elapsed = b['seconds'] - a['seconds']
        wall = b['epoch_seconds'] - a['epoch_seconds']
        power_a, power_b = a['battery']['battery_discharge_w'], b['battery']['battery_discharge_w']
        # Do not integrate across sleep, a clock jump, AC transitions or gaps.
        if (power_a is not None and power_b is not None and 0 < elapsed <= 2 * interval + 1
                and abs(wall - elapsed) <= 2):
            watt_seconds += (power_a + power_b) / 2 * elapsed
            covered += elapsed
    return {'sampled_wh': watt_seconds / 3600 if covered else None, 'covered_seconds': covered}


def measure(pid, seconds, interval, output, require_battery=False):
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int

    def process_identity():
        usage = RUsage()
        if libproc.proc_pid_rusage(pid, 4, ctypes.byref(usage)):
            raise OSError(ctypes.get_errno(), 'Process unavailable')
        return usage.proc_start_abstime

    samples, error = [], None
    identity = process_identity()
    start, start_wall = time.monotonic(), time.time()
    with tempfile.TemporaryDirectory(prefix='aicb-energy-') as tmp:
        probe = Path(tmp) / 'task-power'
        subprocess.run(['/usr/bin/clang', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(Path(__file__).with_name('task_power.c')), '-o', str(probe)], check=True)
        start, start_wall = time.monotonic(), time.time()
        while True:
            try:
                if process_identity() != identity:
                    raise RuntimeError('Process restarted during measurement')
                battery = battery_sample()
                if require_battery and not battery['available']:
                    raise RuntimeError('Actual battery measurement requires an internal battery')
                if require_battery and (battery['external_power'] or battery['charging']):
                    raise RuntimeError('Actual battery measurement requires unplugged power; AC is connected')
                power = json.loads(subprocess.check_output([str(probe), str(pid)], timeout=5))
                if process_identity() != identity:
                    raise RuntimeError('Process restarted while reading energy counters')
                sample = {'seconds':time.monotonic()-start, 'epoch_seconds':time.time(),
                          'battery':battery, **power}
                if samples and any(sample[k] < samples[-1][k] for k in power):
                    raise RuntimeError('Kernel task counters decreased')
                samples.append(sample)
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as failure:
                error = str(failure)
                break
            measured = sample['seconds'] - samples[0]['seconds']
            if measured >= seconds:
                break
            time.sleep(min(interval, seconds - measured))
    duration = samples[-1]['seconds'] - samples[0]['seconds'] if len(samples) > 1 else 0
    energy = (samples[-1]['task_cpu_energy_nanojoules'] - samples[0]['task_cpu_energy_nanojoules']) / 1e9 if len(samples) > 1 else None
    gpu = samples[-1]['gpu_nanoseconds'] - samples[0]['gpu_nanoseconds'] if len(samples) > 1 else None
    battery = integrate_discharge(samples, interval)
    battery_complete = error is None and duration > 0 and abs(battery['covered_seconds']-duration)<0.001
    if require_battery and error is None and not battery_complete:
        error = 'Battery samples are incomplete: sleep, clock or power-source gaps were excluded'
    result = {'pid':pid, 'process_start_identity':identity,
              'started_at_utc':datetime.fromtimestamp(start_wall,timezone.utc).isoformat(),
              'completed':error is None, 'error':error, 'requested_seconds':seconds,
              'measured_seconds':duration, 'wall_clock_seconds':time.time()-start_wall,
              'sample_interval_seconds':interval, 'sample_count':len(samples),
              'kernel_task_cpu_energy_joules':energy,
              'kernel_task_cpu_energy_average_watts':energy/duration if energy is not None and duration else None,
              'task_gpu_nanoseconds':gpu, 'whole_computer_battery_discharge':battery,
              'battery_measurement_complete':battery_complete,
              'units_sources':[BATTERY_UNITS_SOURCE,TASK_UNITS_SOURCE],
              'limits':['Kernel CPU-energy attribution is not battery drain. OS helpers and WindowServer are excluded.',
                        'Battery current/voltage samples cover the whole computer, including other apps and this measurement tool.',
                        'No per-app battery-life estimate or extrapolation is made. Sleep and AC gaps are excluded.'],
              'samples':samples}
    if output:
        output.write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid',type=int)
    parser.add_argument('--seconds',type=float,default=900)
    parser.add_argument('--interval',type=float,default=15)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--require-battery',action='store_true')
    args = parser.parse_args()
    if not 0 < args.pid <= 2**31-1 or not math.isfinite(args.seconds) or not 0 < args.seconds <= 3600:
        parser.error('Expected a positive PID and --seconds between 0 and 3600')
    if not math.isfinite(args.interval) or not 0 < args.interval <= 60:
        parser.error('--interval must be between 0 and 60')
    report = measure(args.pid,args.seconds,args.interval,args.output,args.require_battery)
    print(json.dumps({k:v for k,v in report.items() if k!='samples'},indent=2))
    raise SystemExit(0 if report['completed'] else 1)
