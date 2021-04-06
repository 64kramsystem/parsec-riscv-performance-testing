# The help is wrong; it states `-ns [number of swaptions (should be > number of threads]`, however,
# it's actually `ns >= threads`.
#
# The `native` dataset sets `-ns 128`, `simlarge` sets `-ns 64`.
#
c_input_type=simlarge

# In order to test with 128 threads, the `native` input is required, however, that makes the 1-thread
# run way too long.
#
v_max_threads=64

# The benchmark accepts only threads == 2ⁿ.
#
function prepare_threads_number_list {
  local thread_numbers_list=""

  for ((threads = v_min_threads; threads <= v_max_threads; threads *= 2)); do
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
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p swaptions -i $c_input_type -n $threads
  "
}
