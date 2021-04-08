#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

####################################################################################################
# VARIABLES/CONSTANTS
####################################################################################################

v_min_threads=2
v_max_threads=128

c_ssh_user=root
c_ssh_password=busybear
c_ssh_host=localhost
c_ssh_port=10000

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_output_dir=$(readlink -f "$(dirname "$0")")/output
c_temp_dir=$(dirname "$(mktemp)")

c_qemu_binary=$c_components_dir/qemu-system-riscv64
c_qemu_debug_file=$(basename "$0").qemu_debug.log
c_qemu_output_log_file=$(basename "$0").qemu_out.log

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

c_perf_stat_events=L1-dcache-load-misses,context-switches,migrations,cycles,sched:sched_switch
c_perf_record_events=cpu-cycles

c_debug_log_file=$(basename "$0").log

c_help='Usage: '"$(basename "$0")"' [-s|--no-smt] [-p|--perf-stat] [-P|--perf-record] [-m|--min <threads>] [-M|--max <threads>] <bench_name> <runs> <qemu_boot_script> <benchmark_script>

Runs the specified benchmark with different vCPU/thread numbers, and stores the results.

Example usage:

    ./'"$(basename "$0")"' blackscholes_mytest 1 support_scripts/qemu_basic.sh support_scripts/bench_parsec_blackscholes.sh

Options:

- `--no-smt`: Disables SMT
- `--perf-stat`: Run perf stat; when enabled, the timings file is not written
- `--perf-record`: Run perf record; when enabled, the timings file is not written
- `--min <threads>`: Set the minimum amount of threads to start; defaults to '"$v_min_threads"'
- `--max <threads>`: Set the threads maximum threshold; defaults to '"$v_max_threads"'

Some benchmarks may override the min/max for different reasons (they will print a warning).

WATCH OUT! Enabling both perf options will cause the runs to be doubled (as they presumably can'\''t be run in parallel).

WATCH OUT! It'\''s advisable to lock the CPU clock (typically, this is done in the BIOS), in order to avoid the clock decreasing when the number of threads increase.

Perf stat events recorded: '"$c_perf_stat_events"'
Perf record events recorded: '"$c_perf_record_events"'

---

Requires the components built by `setup_system.sh` to be in place.

Powers of two below or equal $v_max_threads are used for each run; the of number of host processors is added if it'\''s not a power of 2.

The `sshpass` program must be available on the host.

The output CSV is be stored in the `'"$c_output_dir"'` subdirectory, with name `<bench_name>.csv`.
'

# User-defined
#
v_count_runs=     # int
v_qemu_script=    # string
v_bench_script=   # string
v_enable_perf_stat=  # boolean (false=blank, true=anything else)
v_enable_perf_record=   # boolean (false=blank, true=anything else)
v_disable_smt=    # boolean (false=blank, true=anything else)

# Computed internally
#
v_previous_smt_configuration=   # string
v_isolated_processors=()        # array
v_thread_numbers_list=()        # array

####################################################################################################
# MAIN FUNCTIONS
####################################################################################################

function decode_cmdline_args {
  eval set -- "$(getopt --options hspPm:M: --long help,no-smt,perf-stat,perf-record,min:,max: --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -s|--no-smt)
        v_disable_smt=1
        shift ;;
      -p|--perf-stat)
        v_enable_perf_stat=1
        shift ;;
      -P|--perf-record)
        v_enable_perf_record=1
        shift ;;
      -m|--min)
        v_min_threads=$2
        shift 2 ;;
      -M|--max)
        v_max_threads=$2
        shift 2 ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -ne 4 ]]; then
    echo "$c_help"
    exit 1
  fi

  v_bench_name=$1
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

function clear_existing_data {
  rm -f "$c_output_dir/$v_bench_name."*
}

function run_benchmark {
  local benchmark_log_file_name=$c_output_dir/$v_bench_name.log

  true > "$benchmark_log_file_name"

  # See note in the help.
  #
  # Originally, the strategy was to use the run number in the outer cycle, with the rationale that variations
  # between runs would not cluster across a number of threads (inner cycle).
  # Later, the nesting has been reversed; this has been made possible by giving the guideline of setting
  # a fixed CPU clock.
  #
  for threads in "${v_thread_numbers_list[@]}"; do
    boot_guest "$threads"
    wait_guest_online

    echo "
################################################################################
> Threads: $threads ($v_bench_name)
################################################################################
" | tee -a "$benchmark_log_file_name"

    # The `cd` is for simulating a new session.
    #
    local benchmark_command
    benchmark_command=$(compose_benchmark_command "$threads")
    benchmark_command="for ((run=0; run < $v_count_runs; run++)); do
${benchmark_command}
cd
done"

    if [[ -z $v_enable_perf_stat && -z $v_enable_perf_record ]]; then
      local standard_timing_file_name="$c_output_dir/$v_bench_name.timings.csv"
      local perf_pid=
      run_benchmark_thread_group "$benchmark_command" "$perf_pid" "$threads" "$benchmark_log_file_name" "$standard_timing_file_name"
    fi

    # perf is killed inside the run_benchmark_thread_group() function, as we want to run profiling as
    # tightly as around the benchmark execution.

    if [[ -n $v_enable_perf_stat ]]; then
      local perf_stat_timing_file_name="$c_output_dir/$v_bench_name.perf_stat.timings.csv"
      local perf_pid
      perf_pid=$(start_perf_stat "$threads")

      # We don't need this in perf record, which is not per-thread.
      #
      store_vcpu_pids "$threads"

      run_benchmark_thread_group "$benchmark_command" "$perf_pid" "$threads" "$benchmark_log_file_name" "$perf_stat_timing_file_name"
    fi

    if [[ -n $v_enable_perf_record ]]; then
      local perf_record_timing_file_name="$c_output_dir/$v_bench_name.perf_record.timings.csv"
      local perf_pid
      perf_pid=$(start_perf_record "$threads")

      run_benchmark_thread_group "$benchmark_command" "$perf_pid" "$threads" "$benchmark_log_file_name" "$perf_record_timing_file_name"
    fi

    shutdown_guest
  done

  echo "> Benchmark completed."
}

####################################################################################################
# INNER FUNCTIONS
####################################################################################################

function run_benchmark_thread_group {
  local benchmark_command=$1
  local perf_pid=$2
  local threads=$3
  local benchmark_log_file_name=$4
  local timings_file_name=$5

  if [[ ! -s $timings_file_name ]]; then
    echo "threads,run,run_time" > "$timings_file_name"
  fi

  # Don't store the output in the script debug log - too verbose, and it has its own log.
  #
  set +x

  local command_output
  command_output=$(run_remote_command "$benchmark_command")

  if [[ -n $perf_pid ]]; then
    sudo pkill -INT -P "$perf_pid"
  fi

  echo "$command_output" >> "$benchmark_log_file_name"

  local run_walltimes
  run_walltimes=$(extract_run_walltimes "$command_output")

  echo "
> TIMES: $(echo -n "$run_walltimes" | tr $'\n' ',')
" | tee -a "$benchmark_log_file_name"

  store_timings "$threads" "$run_walltimes" "$timings_file_name"

  # Restore logging.
  #
  set -x
}

function store_vcpu_pids {
  local threads=$1

  local output_file_name="$c_output_dir/$v_bench_name.pids.$(printf %03d "$threads").txt"

  # Sample lines:
  #
  #     Creating thread 'worker' -> PID 11042
  #     Creating thread 'CPU 0/TCG' -> PID 11043
  #
  local vcpu_pids
  mapfile -t vcpu_pids < <(perl -lne 'print $1 if /CPU.+PID (\d+)/' "$c_qemu_debug_file")

  if ((${#vcpu_pids[@]} != threads)); then
    >&2 echo "Unexpected number of QEMU vCPU thread PIDS found: ${vcpu_pids[*]}"
    exit 1
  fi

  printf '%s\n' "${vcpu_pids[@]}" > "$output_file_name"
}

# Returns (prints) the perf process pid.
#
function start_perf_stat {
  local threads=$1

  local output_file_name="$c_output_dir/$v_bench_name.perf_stat.data.$(printf %03d "$threads").csv"

  sudo perf stat -e "$c_perf_stat_events" --per-thread -p "$(< "$c_qemu_pidfile")" --field-separator "," 2> "$output_file_name" > /dev/null &

  echo -n "$!"
}

# Returns (prints) the perf process pid.
#
function start_perf_record {
  local threads=$1

  local output_file_name="$c_output_dir/$v_bench_name.perf_record.data.$(printf %03d "$threads").dat"

  sudo perf record -e "$c_perf_record_events" -g -p "$(< "$c_qemu_pidfile")" -o "$output_file_name" > /dev/null &

  echo -n "$!"
}

# Returns (prints) the run walltimes (one per line).
#
# Watch out: The last newline is stripped; this avoids makes it simpler to handle it, due to commands
# generally appending a newline (echo, <<<), but it must not be forgotten.
#
function extract_run_walltimes {
  local command_output=$1

  local run_walltimes
  run_walltimes=$(echo "$command_output" | perl -lne 'print $1 if /^ROI time measured: (\d+[.,]\d+)s/' | perl -pe 'chomp if eof')

  local count_run_walltimes
  count_run_walltimes=$(wc -l <<< "$run_walltimes")

  if (( count_run_walltimes != v_count_runs )); then
    >&2 echo "Unexpected number of walltimes found: $count_run_walltimes ($v_count_runs expected)"
    exit 1
  fi

  echo -n "$run_walltimes"
}

function store_timings {
  local threads=$1
  local run_walltimes=$2
  local timings_file_name=$3

  local run=0
  while IFS= read -r -a run_walltime; do
    # Replace time comma with dot, it present.
    #
    echo "$threads,$run,${run_walltime/,/.}" >> "$timings_file_name"
    (( ++run ))
  done <<< "$run_walltimes"
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
  # Set the ERROR log level, in order to skipt the warning about the host added to the known list
  #
  sshpass -p "$c_ssh_password" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
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
  # In some cases (unclear why, for PARSEC freqmine), the image file would still be locked by the next
  # thread group, implying that QEMU is still on. For this reason, an extra check is needed.
  #
  while [[ -f $c_qemu_pidfile || $(lsof "$c_guest_image_temp" 2> /dev/null || true) != "" ]]; do
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
prepare_isolated_processors_list
prepare_threads_number_list
clear_existing_data
run_benchmark
