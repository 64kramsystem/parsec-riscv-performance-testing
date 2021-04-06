#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_scripts_dir=$(readlink -f "$(dirname "$0")")/support_scripts
c_scripts_name_prefix=bench_parsec_
c_program_names=(
  blackscholes
  bodytrack
  cholesky
  ferret
  fft
  fluidanimate
  freqmine
  lu_cb
  lu_ncb
  ocean_cp
  radix
  swaptions
  water_nsquared
  water_spatial
)
c_qemu_script_name=$c_scripts_dir/qemu_basic.sh
c_run_benchmark_script=$(dirname "$0")/run_benchmark.sh

c_help="Usage: $(basename "$0") [-s|--no-smt] [-p|--perf] <system_name> <runs>

Runs the PARSEC programs used in the paper, appending the <system_name> to the program name(s).

For the options, see \`run_benchmark.sh\`."

v_run_script_args=()          # array
v_system_name=                # string
v_count_runs=                 # int

function decode_cmdline_args {
  eval set -- "$(getopt --options hsp --long help,no-smt,perf --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -s|--no-smt)
        v_run_script_args+=(--no-smt)
        shift ;;
      -p|--perf)
        v_run_script_args+=(--perf)
        shift ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -ne 2 ]]; then
    echo "$c_help"
    exit 1
  fi

  v_system_name=$1
  v_count_runs=$2
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
  for program_name in "${c_program_names[@]}"; do
    local benchmark_script=$c_scripts_dir/${c_scripts_name_prefix}$program_name.sh

    "$c_run_benchmark_script" "${v_run_script_args[@]}" "${program_name}_${v_system_name}" "$v_count_runs" "$c_qemu_script_name" "$benchmark_script"
  done
}

decode_cmdline_args "$@"
cache_sudo
run_suites
