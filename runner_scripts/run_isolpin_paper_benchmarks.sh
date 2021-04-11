#!/bin/bash

# No errexit; continue on error!
set -o nounset

if [[ $# -ne 2 || $1 == "--help" || $1 == "-h" ]]; then
  echo '$1: runs, $2:qemu script'
  exit 1
fi

runs=$1
qemu_script=$2
test_prefix=$(perl -ne 'print /qemu_(.+).sh/' <<< "$qemu_script")

# shellcheck disable=SC2164
cd "$(readlink -f "$(dirname "$0")")"/..

# ferret is unstable
./run_benchmark.sh  "${test_prefix}_blackscholes"   "$runs" "$qemu_script" support_scripts/bench_parsec_blackscholes.sh
./run_benchmark.sh  "${test_prefix}_bodytrack"      "$runs" "$qemu_script" support_scripts/bench_parsec_bodytrack.sh
./run_benchmark.sh  "${test_prefix}_cholesky"       "$runs" "$qemu_script" support_scripts/bench_parsec_cholesky.sh
./run_benchmark.sh  "${test_prefix}_freqmine"       "$runs" "$qemu_script" support_scripts/bench_parsec_freqmine.sh
./run_benchmark.sh  "${test_prefix}_lu_cb"          "$runs" "$qemu_script" support_scripts/bench_parsec_lu_cb.sh
./run_benchmark.sh  "${test_prefix}_lu_ncb"         "$runs" "$qemu_script" support_scripts/bench_parsec_lu_ncb.sh
./run_benchmark.sh  "${test_prefix}_water_nsquared" "$runs" "$qemu_script" support_scripts/bench_parsec_water_nsquared.sh
./run_benchmark.sh  "${test_prefix}_water_spatial"  "$runs" "$qemu_script" support_scripts/bench_parsec_water_spatial.sh
