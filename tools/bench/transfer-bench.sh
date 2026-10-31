#!/bin/sh
# FAKE-SERVER upload benchmark: legacy whole-file PUT vs fixed 64 MiB x 2 parts vs tuned parts, through the
# in-process fake device listener behind an emulated link (20 Mbit/s + 80 ms, 1 Gbit/s + 1 ms). Loopback TLS with a
# token-bucket throttle, not a real network: compare the strategies with each other, not with a real link.
#   VH_BENCH_SLOW_MIB  file size on the slow link (default 40)
#   VH_BENCH_FAST_MIB  file size on the fast link (default 1024)
set -eu
cd "$(dirname "$0")/../.."
VH_BENCH=1 swift test --filter TransferBenchmark 2>&1 | sed -n '/FAKE-SERVER BENCHMARK/,/^ideal/p'
