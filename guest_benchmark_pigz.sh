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

c_ssh_user=root
c_ssh_password=busybear
c_ssh_host=localhost
c_ssh_port=10000

c_components_dir=$(dirname "$0")/components
c_output_dir=$(dirname "$0")/output

c_input_file_path=$(ls -1 "$c_components_dir"/*.pigz_input)
c_qemu_binary=$c_components_dir/qemu-system-riscv64

# Easier to run on a fresh copy each time, as an image can be easily broken, and leads to problems on
# startup.
#
c_guest_memory=8G
c_guest_image_source=$c_components_dir/busybear.bin
c_guest_image_run=$c_components_dir/busybear.run.bin
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin
c_qemu_pidfile=${XDG_RUNTIME_DIR:-/tmp}/$(basename "$0").qemu.pid
# see above for the SSH port

c_debug_log_file=$(basename "$0").log

c_help='Usage: '"$(basename "$0")"' <test_name> <per_test_runs> <qemu_boot_script>

Measures the wall times of `pigz` exections on the input file with different vCPU/thread numbers, and stores the results.

Example usage:

    ./'"$(basename "$0")"' pigz_mytest 1 support_scripts/qemu_basic.sh

---

Requires the components built by `setup_system.sh` to be in place.

Powers of two below or equal $c_max_threads are used for each run; the of number of host processors is added if it'\''s not a power of 2.

The `sshpass` program must be available on the host.

The output CSV is be stored in the `'"$c_output_dir"'` subdirectory, with name `<test_name>.csv`.
'

# User-defined
#
v_count_runs=  # int
v_qemu_script= # string

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
  if [[ $# -ne 3 || $1 == "-h" || $1 == "--help" ]]; then
    echo "$c_help"
    exit 0
  fi

  v_output_file_name=$c_output_dir/$1.csv
  v_count_runs=$2
  v_qemu_script=$3
}

function load_includes {
  # Note that the second may override functions. This is used in one case only though, and it's very
  # specific.

  # shellcheck source=support_scripts/benchmark_apis.sh
  source "$(dirname "$0")/support_scripts/benchmark_apis.sh"
  # shellcheck source=/dev/null
  source "$v_qemu_script"
}

function copy_busybear_image {
  echo "Copying fresh BusyBear image..."

  cp "$c_guest_image_source" "$c_guest_image_run"
}

# Since we copy the image each time, we can just kill QEMU. We leave the run image, if debug is needed.
#
function register_exit_handlers {
  trap '{
    exit_system_configuration_reset

    if [[ -f $c_qemu_pidfile ]]; then
      pkill -F "$c_qemu_pidfile"
    fi
  }' EXIT
}

function run_benchmark {
  local input_file_basename
  input_file_basename=$(basename "$c_input_file_path")

  echo "threads,run,run_time" > "$v_output_file_name"

  for threads in "${v_thread_numbers_list[@]}"; do
    boot_guest "$threads"
    wait_guest_online

    # Watch out! `time`'s output goes to stderr, and in order to capture it, we must redirect it to
    # stdout. `pigz` makes things a bit confusing, since the output must be necessarily discarded.
    #
    local benchmark_command="
      cat $input_file_basename > /dev/null &&
      /usr/bin/time -f '>>> WALLTIME:%e' ./pigz --stdout --processes $threads $input_file_basename 2>&1 > /dev/null
    "

    for ((run = 0; run < v_count_runs; run++)); do
      echo "Run $run: threads=$threads..."

      local command_output
      command_output=$(run_remote_command "$benchmark_command")

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

    shutdown_guest
  done
}

####################################################################################################
# HELPERS
####################################################################################################

# Input: $1=command
#
function run_remote_command {
  # If there is an error, the output may never be shown, so we send it to stderr regardless.
  # The timeout is also relatively small - if busybear hangs, QEMU still listens to the port, so the
  # timeout fails earlier and cleaner.
  #
  sshpass -p "$c_ssh_password" ssh -o ConnectTimeout=15 -p "$c_ssh_port" "$c_ssh_user"@"$c_ssh_host" "$1" | tee /dev/stderr
}

# Simplistically assumes that once the SSH port is available, the system is ready (including, from a
# performance perspective).
#
function wait_guest_online {
  while ! nc -z localhost "$c_ssh_port"; do sleep 1; done
}

# The guest may not (for RISC-V, it won't) respond to an ACPI shutdown, so the QEMU monitor strategy
# is not suitable.
#
function shutdown_guest {
  run_remote_command "/sbin/halt"

  # Shutdown is asynchronous, so just wait for the pidfile to go.
  #
  while [[ -f $c_qemu_pidfile ]]; do
    sleep 0.5
  done
}

####################################################################################################
# EXECUTION
####################################################################################################

decode_cmdline_args "$@"
load_includes
create_directories
copy_busybear_image
init_debug_log
find_host_system_configuration_options
register_exit_handlers

set_host_system_configuration
prepare_threads_number_list
run_benchmark

print_completion_message
