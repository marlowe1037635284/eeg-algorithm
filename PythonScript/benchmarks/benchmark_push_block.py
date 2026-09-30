"""Run with the eeg-algorithm environment to inspect Python-only block latency."""

from timeit import timeit

print("Use examples/online_processing_demo.py as the benchmark setup for the target channel count.")
print("Empty Python call baseline (us):", timeit("None", number=100000) / 100000 * 1e6)

