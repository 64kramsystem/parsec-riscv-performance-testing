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

# Hung twice
#./run_benchmark.sh  "${test_prefix}_barnes"        "$runs" "$qemu_script" support_scripts/bench_parsec_barnes.sh

./run_benchmark.sh  "${test_prefix}_dedup"         "$runs" "$qemu_script" support_scripts/bench_parsec_dedup.sh
./run_benchmark.sh  "${test_prefix}_fmm"           "$runs" "$qemu_script" support_scripts/bench_parsec_fmm.sh
./run_benchmark.sh  "${test_prefix}_ocean_ncp"     "$runs" "$qemu_script" support_scripts/bench_parsec_ocean_ncp.sh
./run_benchmark.sh  "${test_prefix}_radiosity"     "$runs" "$qemu_script" support_scripts/bench_parsec_radiosity.sh
./run_benchmark.sh  "${test_prefix}_radix"         "$runs" "$qemu_script" support_scripts/bench_parsec_radix.sh
./run_benchmark.sh  "${test_prefix}_raytrace"      "$runs" "$qemu_script" support_scripts/bench_parsec_raytrace.sh
./run_benchmark.sh  "${test_prefix}_streamcluster" "$runs" "$qemu_script" support_scripts/bench_parsec_streamcluster.sh
./run_benchmark.sh  "${test_prefix}_vips"          "$runs" "$qemu_script" support_scripts/bench_parsec_vips.sh
./run_benchmark.sh  "${test_prefix}_volrend"       "$runs" "$qemu_script" support_scripts/bench_parsec_volrend.sh
