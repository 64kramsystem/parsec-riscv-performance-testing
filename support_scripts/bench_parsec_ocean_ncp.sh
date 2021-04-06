c_input_type=simlarge

if ((v_max_threads >= 64)); then
  # Hung on 128 threads
  #
  echo "> WARNING! This benchmark is very slow after 64 threads."
fi

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p splash2x.ocean_ncp -i $c_input_type -n $threads
  "
}
