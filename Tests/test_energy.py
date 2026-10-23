#!/usr/bin/env python3
"""Check measurement units and reject invalid battery-attribution conditions."""
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from measure_energy import battery_sample, integrate_discharge, measure, signed_current


def sample(seconds, watts, wall=None):
    return {'seconds':seconds,'epoch_seconds':seconds if wall is None else wall,
            'battery':{'battery_discharge_w':watts}}


class EnergyMeasurementTests(unittest.TestCase):
    def test_machine_without_battery(self):
        with patch('measure_energy.subprocess.check_output',return_value=plistlib.dumps([])):
            battery = battery_sample()
        self.assertFalse(battery['available'])
        self.assertIsNone(battery['battery_discharge_w'])
        with tempfile.TemporaryDirectory() as tmp, patch('measure_energy.battery_sample',return_value=battery):
            result = measure(os.getpid(),0.1,0.05,Path(tmp)/'result.json')
            refused = measure(os.getpid(),0.1,0.05,Path(tmp)/'battery.json',require_battery=True)
        self.assertTrue(result['completed'])
        self.assertFalse(result['battery_measurement_complete'])
        self.assertIsNone(result['whole_computer_battery_discharge']['sampled_wh'])
        self.assertFalse(refused['completed'])

    def test_live_counter_interval(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = measure(os.getpid(),0.1,0.05,Path(tmp)/'result.json')
        self.assertTrue(result['completed'])
        self.assertGreaterEqual(result['sample_count'],2)
        self.assertGreaterEqual(result['measured_seconds'],0.1)
        self.assertGreaterEqual(result['kernel_task_cpu_energy_joules'],0)
        self.assertGreaterEqual(result['task_gpu_nanoseconds'],0)

    def test_signed_registry_current(self):
        for raw in (-1200, 2**32-1200, 2**64-1200):
            self.assertEqual(signed_current(raw), -1200)
        for invalid in (True, None, 1.5, 2**64, 500_000):
            with self.assertRaises(ValueError):
                signed_current(invalid)

    def test_known_watt_hour_integral(self):
        # 10 W for 30 minutes is 5 Wh, independent of sampler implementation.
        result = integrate_discharge([sample(t,10) for t in range(0,1801,60)], 60)
        self.assertAlmostEqual(result['sampled_wh'], 5)
        self.assertEqual(result['covered_seconds'], 1800)

    def test_ac_sleep_and_clock_gaps_are_not_battery_data(self):
        for points in ([sample(0,None),sample(15,None)],
                       [sample(0,10),sample(15,None)],
                       [sample(0,10),sample(15,10,wall=300)],
                       [sample(0,10),sample(120,10)]):
            result = integrate_discharge(points,15)
            self.assertIsNone(result['sampled_wh'])
            self.assertEqual(result['covered_seconds'],0)

    def test_required_battery_fails_on_ac(self):
        with tempfile.TemporaryDirectory() as tmp, patch('measure_energy.battery_sample',
                return_value={'available':True,'external_power':True,'charging':False}):
            result = measure(os.getpid(),0.1,0.05,Path(tmp)/'result.json',require_battery=True)
        self.assertFalse(result['completed'])
        self.assertFalse(result['battery_measurement_complete'])
        self.assertEqual(result['sample_count'],0)
        self.assertIsNone(result['whole_computer_battery_discharge']['sampled_wh'])


if __name__ == '__main__':
    unittest.main()
