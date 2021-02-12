c_input_type=simlarge

# Hung on 128 threads
#
c_max_threads=64

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p splash2x.radiosity -i $c_input_type -n $threads
  "
}
