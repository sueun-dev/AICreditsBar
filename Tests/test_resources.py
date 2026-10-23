#!/usr/bin/env python3
"""Validate resource accounting against an independent process CPU clock."""
import os
import subprocess
import threading
import time
import unittest

from measure_resources import measure


class ResourceMeasurementTests(unittest.TestCase):
    def test_cpu_units_against_process_clock(self):
        start_work = threading.Event()

        def burn_cpu():
            start_work.wait()
            start = time.process_time()
            while time.process_time() - start < 0.3:
                pass

        worker = threading.Thread(target=burn_cpu)
        worker.start()
        # Let the measurement take its initial sample before applying CPU load.
        timer = threading.Timer(0.1, start_work.set)
        timer.start()
        before = time.process_time()
        try:
            report = measure(os.getpid(), 0.75, interval=0.05)
            reference = time.process_time() - before
        finally:
            start_work.set()
            timer.cancel()
            worker.join()
        self.assertTrue(report['completed'])
        self.assertGreater(reference, 0.29)
        # A missing Mach timebase conversion undercounts by ~41.7x on arm64.
        # The loose tolerance covers sampling/dispatch overhead under host load.
        self.assertAlmostEqual(report['cpu_seconds'] / reference, 1, delta=0.15)

    def test_process_exit_is_incomplete(self):
        child = subprocess.Popen(['/bin/sleep', '0.3'])
        reaper = threading.Thread(target=child.wait)
        reaper.start()
        try:
            report = measure(child.pid, 1, interval=0.05)
        finally:
            reaper.join()
        self.assertFalse(report['completed'])
        self.assertIsNotNone(report['error'])
        self.assertLess(report['seconds'], 1)


if __name__ == '__main__':
    unittest.main()
