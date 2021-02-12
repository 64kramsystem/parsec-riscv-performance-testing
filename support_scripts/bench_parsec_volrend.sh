c_input_type=simlarge

# Crashes with NTHREADS=1
#
c_min_threads=2

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p splash2x.volrend -i $c_input_type -n $threads
  "
}
