c_input_type=simlarge

if ((v_min_threads < 2)); then
  # With NTHREADS=1, on riscv crashes, and on amd64 it doesn't show the ROI.
  #
  echo "> WARNING! This benchmark has a forced minimum of 2 threads."

  v_min_threads=2
fi

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p splash2x.volrend -i $c_input_type -n $threads
  "
}
