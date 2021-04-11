# The help is wrong; it states `-ns [number of swaptions (should be > number of threads]`, however,
# it's actually `ns >= threads`.
#
# The `native` dataset sets `-ns 128`, `simlarge` sets `-ns 64`.
#
c_input_type=simlarge

if ((v_max_threads > 64)); then
  # Hung on 128 threads
  #
  echo "> WARNING! This benchmark is capped at 64 max threads."

  # In order to test with 128 threads, the `native` input is required, which is inconsistent with the
  # others (all `simlarge`).
  #
  v_max_threads=64
fi

# The benchmark accepts only threads == 2ⁿ.
#
function prepare_threads_number_list {
  local thread_numbers_list=""

  for ((threads = v_min_threads; threads <= v_max_threads; threads *= 2)); do
    thread_numbers_list+="$threads
"
  done

  mapfile -t v_thread_numbers_list < <(echo -n "$thread_numbers_list" | sort -n)
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
