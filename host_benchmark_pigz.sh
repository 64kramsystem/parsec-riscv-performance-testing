#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

####################################################################################################
# VARIABLES/CONSTANTS
####################################################################################################

c_min_threads=2
c_max_threads=128

c_components_dir=$(dirname "$0")/components
c_output_dir=$(dirname "$0")/output

c_input_file_path=$(ls -1 "$c_components_dir"/*.pigz_input)

c_debug_log_file=$(basename "$0").log

c_help='Usage: '"$(basename "$0")"' <test_name> <per_test_runs>

Measures the wall times of `pigz` exections on the input file with different vCPU/thread numbers, and stores the results.

Example usage:

    ./'"$(basename "$0")"' pigz_mytest 1

---

Requires the components built by `setup_system.sh` to be in place.

Powers of two below or equal $c_max_threads are used for each run; the of number of host processors is added if it'\''s not a power of 2.

The output CSV is be stored in the `'"$c_output_dir"'` subdirectory, with name `<test_name>.csv`.
'

# User-defined
#
v_count_runs=  # int

# Computed internally
#
v_previous_scaling_governor=  # string
v_previous_smt_configuration= # string
v_output_file_name=           # string
v_thread_numbers_list=        # array

####################################################################################################
# MAIN FUNCTIONS
####################################################################################################

function decode_cmdline_args {
  # Poor man's options decoding.
  #
  if [[ $# -ne 2 || $1 == "-h" || $1 == "--help" ]]; then
    echo "$c_help"
    exit 0
  fi

  v_output_file_name=$c_output_dir/$1.csv
  v_count_runs=$2
}

function load_includes {
  # shellcheck source=support_scripts/benchmark_apis.sh
  source "$(dirname "$0")/support_scripts/benchmark_apis.sh"
}

function register_exit_handlers {
  trap exit_system_configuration_reset EXIT
}

function run_benchmark {
  echo "threads,run,run_time" > "$v_output_file_name"

  for threads in "${v_thread_numbers_list[@]}"; do
    # Watch out! `time`'s output goes to stderr, and in order to capture it, we must redirect it to
    # stdout. `pigz` makes things a bit confusing, since the output must be necessarily discarded.
    #
    # The host preinstalled pigz is used.
    #
    local benchmark_command="
      cat $c_input_file_path > /dev/null &&
      /usr/bin/time -f '>>> WALLTIME:%e' pigz --stdout --processes $threads $c_input_file_path 2>&1 > /dev/null
    "

    for ((run = 0; run < v_count_runs; run++)); do
      echo "Run $run: threads=$threads..."

      local command_output
      command_output=$(run_local_command "$benchmark_command")

      local run_walltime
      run_walltime=$(echo "$command_output" | perl -ne 'print />>> WALLTIME:(\S+)/')

      if [[ -z $run_walltime ]]; then
        >&2 echo "Walltime message not found!"
        exit 1
      else
        echo "-> TIME=$run_walltime"
      fi

      echo "$threads,$run,$run_walltime" >> "$v_output_file_name"
    done
  done
}

####################################################################################################
# HELPERS
####################################################################################################

# Input: $1=command
#
function run_local_command {
  # If there is an error, the output may never be shown, so we send it to stderr regardless.
  #
  bash -c "$1" | tee /dev/stderr
}

####################################################################################################
# EXECUTION
####################################################################################################

decode_cmdline_args "$@"
load_includes
create_directories
init_debug_log
find_host_system_configuration_options
register_exit_handlers

set_host_system_configuration
prepare_threads_number_list
run_benchmark

print_completion_message
