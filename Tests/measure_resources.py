#!/usr/bin/env python3
"""Read macOS per-process counters; no extra packages or administrator access.

Usage: python3 Tests/measure_resources.py PID --seconds 60 --output report.json
CPU is time / wall time on one core. Memory is sampled, not a lifetime maximum.
This does not measure GPU work attributed to WindowServer or battery life.
"""
import argparse
import ctypes
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


def measure(pid, seconds):
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int

    def read():
        result = RUsage()
        if libproc.proc_pid_rusage(pid, 4, ctypes.byref(result)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
        return result

    start = time.monotonic()
    before = read()
    samples = [before]
    while time.monotonic() - start < seconds:
        time.sleep(min(5, max(0, seconds - (time.monotonic() - start))))
        samples.append(read())
    elapsed = time.monotonic() - start
    after = samples[-1]
    if before.proc_start_abstime != after.proc_start_abstime:
        raise RuntimeError("Process restarted during measurement")
    delta = lambda name: getattr(after, name) - getattr(before, name)
    return {
        "pid": pid, "seconds": round(elapsed, 3),
        "cpu_seconds": (delta("user_time") + delta("system_time")) / 1e9,
        "cpu_percent_one_core": (delta("user_time") + delta("system_time")) / 1e9 / elapsed * 100,
        "idle_wakeups": delta("pkg_idle_wkups"), "interrupt_wakeups": delta("interrupt_wkups"),
        "disk_read_bytes": delta("diskio_bytesread"), "disk_write_bytes": delta("diskio_byteswritten"),
        "logical_write_bytes": delta("logical_writes"),
        "resident_mib_max": max(s.resident_size for s in samples) / 2**20,
        "physical_footprint_mib_max": max(s.phys_footprint for s in samples) / 2**20,
        "gpu": "not measured", "battery_life": "not measured",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 0 < args.seconds <= 3600:
        parser.error("--seconds must be between 0 and 3600")
    report = json.dumps(measure(args.pid, args.seconds), indent=2)
    if args.output:
        args.output.write_text(report + "\n")
    print(report)
