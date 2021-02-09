c_input_type=simlarge

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  echo "
    cd parsec-benchmark &&
    bin/parsecmgmt -a run -p blackscholes -i $c_input_type -n $threads
  "
}
