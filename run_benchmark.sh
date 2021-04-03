#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

####################################################################################################
# VARIABLES/CONSTANTS
####################################################################################################

c_min_threads=1
c_max_threads=128

c_ssh_user=root
c_ssh_password=busybear
c_ssh_host=localhost
c_ssh_port=10000

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_output_dir=$(readlink -f "$(dirname "$0")")/output
c_temp_dir=$(dirname "$(mktemp)")

c_qemu_binary=$c_components_dir/qemu-system-riscv64

# Easier to run on a fresh copy each time, as an image can be easily broken, and leads to problems on
# startup.
#
c_guest_memory=8G
c_guest_image_source=$c_components_dir/busybear.qcow2
c_guest_image_temp=$c_temp_dir/busybear.temp.qcow2 # must be qcow2
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin
c_qemu_pidfile=$c_temp_dir/$(basename "$0").qemu.pid
# see above for the SSH port

c_debug_log_file=$(basename "$0").log

c_help='Usage: '"$(basename "$0")"' [-s|--smt] <bench_name> <runs> <qemu_boot_script> <benchmark_script>

Runs the specified benchmark with different vCPU/thread numbers, and stores the results.

Example usage:

    ./'"$(basename "$0")"' blackscholes_mytest 1 support_scripts/qemu_basic.sh support_scripts/bench_parsec_blackscholes.sh

Options:

- `--smt`: enables SMT (the benchmark disables it by default)

WATCH OUT! It'\''s advisable to lock the CPU clock (typically, this is done in the BIOS), in order to avoid the clock decreasing when the number of threads increase.

---

Requires the components built by `setup_system.sh` to be in place.

Powers of two below or equal $c_max_threads are used for each run; the of number of host processors is added if it'\''s not a power of 2.

The `sshpass` program must be available on the host.

The output CSV is be stored in the `'"$c_output_dir"'` subdirectory, with name `<bench_name>.csv`.

The individual run for each threads number is spread. The rationale is that any relatively long-lasting confounding factor (e.g. system getting increasingly hotter, and reducing the speed) will spread across thread numbers. If the per-thread number cycles were packaged together, any effect would skew the result (more) locally.
'

# User-defined
#
v_count_runs=  # int
v_qemu_script= # string
v_bench_script= # string
v_smt_on=      # boolean (false=blank, true=anything else)

# Computed internally
#
v_previous_smt_configuration= # string
v_output_file_name=           # string
v_thread_numbers_list=        # array

####################################################################################################
# MAIN FUNCTIONS
####################################################################################################

function decode_cmdline_args {
  eval set -- "$(getopt --options hs --long help,smt --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -s|--smt)
        v_smt_on=1
        shift ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -ne 4 ]]; then
    echo "$c_help"
    exit 1
  fi

  v_output_file_name=$c_output_dir/$1.csv
  v_count_runs=$2
  v_qemu_script=$3
  v_bench_script=$4
}

function load_includes {
  # Note that the second may override functions. This is used in one case only though, and it's very
  # specific.

  # shellcheck source=support_scripts/benchmark_apis.sh
  source "$(dirname "$0")/support_scripts/benchmark_apis.sh"
  # shellcheck source=/dev/null
  source "$v_qemu_script"
  # shellcheck source=/dev/null
  source "$v_bench_script"
}

function copy_busybear_image {
  echo "Creating BusyBear run image..."

  qemu-img create -f qcow2 -b "$c_guest_image_source" "$c_guest_image_temp"
}

# Since we copy the image each time, we can just kill QEMU. We leave the run image, if debug is needed.
#
function register_exit_handlers {
  trap '{
    exit_system_configuration_reset

    if [[ -f $c_qemu_pidfile ]]; then
      pkill -F "$c_qemu_pidfile"
      rm -f "$c_qemu_pidfile"
    fi
  }' EXIT
}

function run_benchmark {
  echo "threads,run,run_time" > "$v_output_file_name"

  # See note in the help.
  #
  for ((run = 0; run < v_count_runs; run++)); do
    for threads in "${v_thread_numbers_list[@]}"; do
      echo "Run:$run Threads:$threads..."

      boot_guest "$threads"
      wait_guest_online

      local benchmark_command
      benchmark_command=$(compose_benchmark_command "$threads")

      local command_output
      command_output=$(run_remote_command "$benchmark_command")

      local run_walltime
      run_walltime=$(echo  "$command_output" | perl -ne 'print /^ROI time measured: (\d+[.,]\d+)s/')

      if [[ -z $run_walltime ]]; then
        >&2 echo "Walltime message not found!"
        exit 1
      else
        echo "-> TIME=$run_walltime"
      fi

      # Replaces time comma with dot, it present.
      #
      echo "$threads,$run,${run_walltime/,/.}" >> "$v_output_file_name"

      shutdown_guest
    done
  done
}

####################################################################################################
# HELPERS
####################################################################################################

# Input: $@=ssh params
#
function run_remote_command {
  # If there is an error, the output may never be shown, so we send it to stderr regardless.
  #
  # Disabling the host checking is required, both because sshpass doesn't get along with the host checking
  # prompt, and because if the guest is changed (reset), SSH will complain.
  #
  #
  sshpass -p "$c_ssh_password" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p "$c_ssh_port" "$c_ssh_user"@"$c_ssh_host" "$@" | tee /dev/stderr
}

# Tricky, for a simple concept:
#
# - waiting for the port to be open is not enough, as QEMU leaves it open regardless;
# - we can't use a single attempt with a long timeout (due to the first SSH connection being slower);
#   in some cases, the connection times out - possibly this is due to QEMU receving the packets before
#   the SSH server is up, and discarding them instead of queuing them.
#
function wait_guest_online {
  while ! nc -z localhost "$c_ssh_port"; do sleep 1; done

  SECONDS=0
  local single_attempt_timeout=2
  local wait_time=60

  while (( SECONDS < wait_time )); do
    if run_remote_command -o ConnectTimeout="$single_attempt_timeout" exit 2> /dev/null; then
      return
    fi
  done

  >&2 echo "Couldn't connect to the VM within $wait_time seconds"
  exit 1
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
