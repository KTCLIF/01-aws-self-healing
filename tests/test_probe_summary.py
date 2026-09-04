import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "experiments" / "web-host-loss" / "summarize_probes.py"
SPEC = importlib.util.spec_from_file_location("probe_summary", MODULE_PATH)
SUMMARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUMMARY)


class ProbeSummaryTest(unittest.TestCase):
    def test_counts_errors_and_longest_failure_window(self):
        samples = SUMMARY.parse_lines([
            "900\tt0\t1\tworker-a\n",
            "1000\tt1\t1\tworker-a\n",
            "1100\tt2\t0\t\n",
            "1200\tt3\t0\t\n",
            "1300\tt4\t1\tworker-b\n",
            "1400\tt5\t1\tworker-c\n",
            "1500\tt6\t1\tworker-c\n",
        ])
        result = SUMMARY.summarize(samples, 1000, 1400, 100)
        self.assertEqual(result["total_requests"], 7)
        self.assertEqual(result["failed_requests"], 2)
        self.assertEqual(result["failure_window_requests"], 5)
        self.assertEqual(result["failure_window_error_rate_percent"], 40.0)
        self.assertEqual(result["max_consecutive_failures"], 2)
        self.assertEqual(result["max_unavailable_duration_seconds"], 0.2)
        self.assertEqual(result["observed_average_start_interval_ms"], 100.0)
        self.assertEqual(result["observed_median_start_interval_ms"], 100.0)
        self.assertEqual(result["observed_max_start_interval_ms"], 100)
        self.assertEqual(result["serving_nodes_before_failure"], ["worker-a"])
        self.assertEqual(result["serving_nodes_after_convergence"], ["worker-c"])

    def test_zero_errors_is_not_claimed_before_observation(self):
        samples = SUMMARY.parse_lines([
            "1000\tt1\t1\tworker-a\n",
            "1100\tt2\t1\tworker-b\n",
        ])
        result = SUMMARY.summarize(samples, 1000, 1100, 100)
        self.assertEqual(result["failure_window_error_rate_percent"], 0.0)
        self.assertEqual(result["max_consecutive_failures"], 0)
        self.assertEqual(result["max_unavailable_duration_seconds"], 0.0)


if __name__ == "__main__":
    unittest.main()
