#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_scripts_dir=$(readlink -f "$(dirname "$0")")
c_help="Usage: $(basename "$0") <system_name> <per_test_runs>

Runs all the benchmarks, appending the <system_name> to the test name(s)."

# User-defined
#
v_system_name=   # string
v_per_test_runs= # int

function decode_cmdline_args {
  if [[ $# -ne 2 || $1 == "-h" || $1 == "--help" ]]; then
    echo "$c_help"
    exit 0
  fi

  v_system_name=$1
  v_per_test_runs=$2
}

# Ask sudo permissions only once over the runtime of the script.
#
function cache_sudo {
  sudo -v

  while true; do
    sleep 60
    kill -0 "$$" || exit
    sudo -nv
  done 2>/dev/null &
}

function run_suites {
  # Special, ignore.
  #
  # "$c_scripts_dir/guest_benchmark_pigz.sh"       "pigz_guest_isol_pin_$v_system_name" "$v_per_test_runs" support_scripts/qemu_isol_pin.sh

  "$c_scripts_dir/host_benchmark_pigz.sh"        "pigz_host_no_smt_$v_system_name"    "$v_per_test_runs"
  "$c_scripts_dir/host_benchmark_pigz.sh"  --smt "pigz_host_smt_$v_system_name"       "$v_per_test_runs"
  "$c_scripts_dir/guest_benchmark_pigz.sh"       "pigz_guest_no_smt_$v_system_name"   "$v_per_test_runs" support_scripts/qemu_basic.sh
  "$c_scripts_dir/guest_benchmark_pigz.sh" --smt "pigz_guest_smt_$v_system_name"      "$v_per_test_runs" support_scripts/qemu_basic.sh
}

decode_cmdline_args "$@"
cache_sudo
run_suites
