function create_directories {
  mkdir -p "$c_output_dir"
}

function init_debug_log {
  exec 5> "$c_debug_log_file"
  BASH_XTRACEFD="5"
  set -x
}

function find_host_system_configuration_options {
  v_previous_smt_configuration=$(cat /sys/devices/system/cpu/smt/control)
}

function exit_system_configuration_reset {
  if [[ -n $v_disable_smt ]]; then
    echo "Restoring previous SMT setting ($v_previous_smt_configuration)..."
    echo "$v_previous_smt_configuration" | sudo tee /sys/devices/system/cpu/smt/control
  fi
}

# Compute and set $v_available_processors.
#
function prepare_isolated_processors_list {
  local isolcpu_descriptions=()

  mapfile -td, isolcpu_descriptions < <(perl -pe 'chomp if eof' /sys/devices/system/cpu/isolated)

  for isolcpu_description in "${isolcpu_descriptions[@]}"; do
    local start_processor=${isolcpu_description%-*}
    local end_processor=${isolcpu_description#*-}
    local end_processor=${end_processor:-$start_processor}

    for ((i = start_processor; i <= end_processor; i++)); do
      v_isolated_processors+=("$i")
    done
  done

  # Just in case, this is a convenient way to find the processors available to the kernel.
  #
  # local all_processors_count=
  # all_processors_count=$(nproc --all)
  # for ((i = 0; i < all_processors_count; i++)); do
  #   if [[ ! ${v_isolated_processors[*]} =~ $(echo "\b$i\b") ]]; then
  #     v_available_processors+=("$i")
  #   fi
  # done
}

# Returns the sorted list of threads number.
#
# Sorting is not really required, just nicer looking.
#
function prepare_threads_number_list {
  local thread_numbers_list=""

  for ((threads = v_min_threads; threads <= v_max_threads; threads *= 2)); do
    thread_numbers_list+="$threads
"
  done

  local c_num_procs
  c_num_procs=$(nproc)

  # Bitwise testing if a number is not a power of two.
  #
  if (( (c_num_procs & (c_num_procs - 1)) != 0 )); then
    thread_numbers_list+="$c_num_procs
"
  fi

  # Really ugly, but standard, bash way of creating a sorted array.
  #
  mapfile -t v_thread_numbers_list < <(echo -n "$thread_numbers_list" | sort -n)

  echo "Threads number list: ${v_thread_numbers_list[*]}"
}

# WATCH OUT! If SMT is disabled, all the `/sys/devices/system/cpu/cpu*` files will be still present,
# but raise an error when trying to change the governor (`cpufreq/scaling_governor`).
#
function set_host_system_configuration {
  if [[ -n $v_disable_smt ]]; then
    echo "Disabling SMT..."
    echo off | sudo tee /sys/devices/system/cpu/smt/control
  fi
}
