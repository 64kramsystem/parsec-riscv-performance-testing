c_input_type=simlarge

# The benchmark accepts only threads == 2ⁿ.
#
function prepare_threads_number_list {
  local thread_numbers_list=""

  for ((threads = c_min_threads; threads <= c_max_threads; threads *= 2)); do
    thread_numbers_list+="$threads
"
  done

  mapfile -t v_thread_numbers_list < <(echo -n "$thread_numbers_list" | sort -n)

  echo "Threads number list: ${v_thread_numbers_list[*]}"
}

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p fluidanimate -i $c_input_type -n $threads
  "
}