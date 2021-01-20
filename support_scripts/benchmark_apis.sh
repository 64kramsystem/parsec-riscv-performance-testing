function create_directories {
  mkdir -p "$c_output_dir"
}

function init_debug_log {
  exec 5> "$c_debug_log_file"
  BASH_XTRACEFD="5"
  set -x
}

function find_host_system_configuration_options {
  local governors
  mapfile -t governors < <(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort -u)

  if [[ ${#governors[@]} -ne 1 ]]; then
    echo "Found unexpected number of processor governors: ${governors[*]}"
    exit 1
  else
    v_previous_scaling_governor=${governors[0]}
  fi

  v_previous_smt_configuration=$(cat /sys/devices/system/cpu/smt/control)
}

# See set_host_system_configuration() for ordering comments.
#
function exit_system_configuration_reset {
  echo "$v_previous_smt_configuration" | sudo tee /sys/devices/system/cpu/smt/control
  echo "$v_previous_scaling_governor" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
}

# Returns the sorted list of threads number.
#
# Sorting is not really required, just nicer looking.
#
function prepare_threads_number_list {
  local thread_numbers_list=""

  for ((threads = c_min_threads; threads <= c_max_threads; threads *= 2)); do
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

  # Really ugly, but standard, bash way creating a sorted array.
  #
  mapfile -t v_thread_numbers_list < <(echo -n "$thread_numbers_list" | sort -n)

  echo "Threads number list: ${v_thread_numbers_list[@]}"
}

# WATCH OUT! If SMT is disabled, all the `/sys/devices/system/cpu/cpu*` files will be still present,
# but raise an error when trying to change the governor. Therefore, we assume that it's ON before, and
# we set the governor before disabling it.
#
# The reset logic actually works for a configuration starting with OFF, but when the governors are reset,
# the output is confusing.
#
function set_host_system_configuration {
  echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
  echo off | sudo tee /sys/devices/system/cpu/smt/control
}

function print_completion_message {
  echo ">>> Results stored as \`$v_output_file_name\`"
}
