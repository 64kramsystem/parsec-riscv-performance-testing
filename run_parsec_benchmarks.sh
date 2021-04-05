#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_scripts_dir=$(readlink -f "$(dirname "$0")")/support_scripts
c_scripts_name_prefix=bench_parsec_
c_qemu_script_name=$c_scripts_dir/qemu_basic.sh
c_run_benchmark_script=$(dirname "$0")/run_benchmark.sh

c_help="Usage: $(basename "$0") [-s|--no-smt] <system_name> <per_benchmark_threads_runs>

Runs all the parsec benchmarks, appending the <system_name> to the benchmark name(s).

- \`--no-smt\`: Disables SMT
- \`per_benchmark_threads_runs\`: Runs for each test and number of threads"

v_smt_option=()               # array
v_system_name=                # string
v_per_benchmark_threads_runs= # int

function decode_cmdline_args {
  eval set -- "$(getopt --options hs --long help,no-smt --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -s|--no-smt)
        v_smt_option=(--no-smt)
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
  v_per_benchmark_threads_runs=$2
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
  for benchmark_script in "$c_scripts_dir/$c_scripts_name_prefix"*; do
    # Strip path, name prefix and extension.
    #
    local bare_benchmark_name
    bare_benchmark_name=${benchmark_script/"$c_scripts_dir/$c_scripts_name_prefix"}
    bare_benchmark_name=${bare_benchmark_name%.sh}

    "$c_run_benchmark_script" "${v_smt_option[@]}" "${bare_benchmark_name}_${v_system_name}" "$v_per_benchmark_threads_runs" "$c_qemu_script_name" "$benchmark_script"
  done
}

decode_cmdline_args "$@"
cache_sudo
run_suites
