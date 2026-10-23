#!/usr/bin/env python3
"""Read macOS per-process counters; no extra packages or administrator access.

Usage: python3 Tests/measure_resources.py PID --seconds 60 --output report.json
CPU is time / wall time on one core. Memory is sampled, not a lifetime maximum.
This does not measure GPU work attributed to WindowServer or battery life.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import time
from pathlib import Path

FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size
resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time
child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins
child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default
cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility
cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive
billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint
instructions cycles billed_energy serviced_energy interval_max_phys_footprint
runnable_time""".split()


class RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in FIELDS]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def mach_timebase():
    """rusage CPU counters use Mach ticks, not nanoseconds on Apple Silicon."""
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    result = MachTimebase()
    if system.mach_timebase_info(ctypes.byref(result)) != 0 or not result.denom:
        raise RuntimeError("mach_timebase_info failed")
    return result


def measure(pid, seconds, interval=5, output=None):
    timebase = mach_timebase()
    seconds_per_tick = timebase.numer / timebase.denom / 1e9
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int

    def read():
        result = RUsage()
        if libproc.proc_pid_rusage(pid, 4, ctypes.byref(result)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
        return result

    before = read()
    start = time.monotonic()
    started_at = datetime.now(timezone.utc).isoformat()
    samples = [(0, before)]
    timeline = []
    last_progress = 0
    error = None

    def report(completed=False):
        elapsed, after = samples[-1]
        delta = lambda name: getattr(after, name) - getattr(before, name)
        cpu_seconds = (delta("user_time") + delta("system_time")) * seconds_per_tick
        return {
            "pid": pid, "requested_seconds": seconds, "seconds": round(elapsed, 3),
            "completed": completed, "error": error, "started_at_utc": started_at,
            "reported_at_utc": datetime.now(timezone.utc).isoformat(),
            "sample_interval_seconds": interval, "sample_count": len(samples),
            "cpu_counter_unit": "mach_absolute_time ticks",
            "mach_timebase": {"numer": timebase.numer, "denom": timebase.denom},
            "cpu_seconds": cpu_seconds,
            "child_cpu_seconds": (delta("child_user_time") + delta("child_system_time")) * seconds_per_tick,
            "cpu_percent_one_core": cpu_seconds / elapsed * 100 if elapsed else 0,
            "idle_wakeups": delta("pkg_idle_wkups"), "interrupt_wakeups": delta("interrupt_wkups"),
            "disk_read_bytes": delta("diskio_bytesread"), "disk_write_bytes": delta("diskio_byteswritten"),
            "logical_write_bytes": delta("logical_writes"),
            "resident_mib_start": before.resident_size / 2**20,
            "resident_mib_end": after.resident_size / 2**20,
            "resident_mib_max": max(s.resident_size for _, s in samples) / 2**20,
            "physical_footprint_mib_start": before.phys_footprint / 2**20,
            "physical_footprint_mib_end": after.phys_footprint / 2**20,
            "physical_footprint_mib_max": max(s.phys_footprint for _, s in samples) / 2**20,
            "timeline": timeline,
            "gpu": "not measured", "battery_life": "not measured",
        }

    def save(value):
        if output:
            temporary = output.with_suffix(output.suffix + ".tmp")
            temporary.write_text(json.dumps(value, indent=2) + "\n")
            temporary.replace(output)

    save(report())
    while samples[-1][0] < seconds:
        time.sleep(min(interval, max(0, seconds - (time.monotonic() - start))))
        try:
            current = read()
            if before.proc_start_abstime != current.proc_start_abstime:
                raise RuntimeError("Process restarted during measurement")
        except (OSError, RuntimeError) as failure:
            error = str(failure)
            break
        elapsed = time.monotonic() - start
        previous_elapsed, previous = samples[-1]
        samples.append((elapsed, current))
        cpu = current.user_time + current.system_time - previous.user_time - previous.system_time
        timeline.append({
            "seconds": round(elapsed, 3),
            "cpu_percent_one_core": cpu * seconds_per_tick / (elapsed - previous_elapsed) * 100,
            "resident_mib": current.resident_size / 2**20,
            "physical_footprint_mib": current.phys_footprint / 2**20,
            "disk_write_bytes": current.diskio_byteswritten - before.diskio_byteswritten,
        })
        if elapsed - last_progress >= 60:
            save(report())
            print(f"{elapsed:.0f}/{seconds:g}s: PID {pid} alive, footprint {current.phys_footprint / 2**20:.2f} MiB", flush=True)
            last_progress = elapsed
    result = report(completed=error is None)
    save(result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--interval", type=float, default=5, help="sampling interval in seconds (default: 5)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 0 < args.seconds <= 3600:
        parser.error("--seconds must be between 0 and 3600")
    if not 0 < args.interval <= 60:
        parser.error("--interval must be between 0 and 60")
    result = measure(args.pid, args.seconds, args.interval, args.output)
    print(json.dumps({key: value for key, value in result.items() if key != "timeline"}, indent=2))
    raise SystemExit(0 if result["completed"] else 1)
