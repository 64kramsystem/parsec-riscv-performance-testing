c_input_type=simlarge

echo '> WARNING! The ferret program is unstable (see script).'

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  # When running multiple times in sequence, sometimes this program fails with:
  #
  #     emd: Unexpected error in findBasicVariables!
  #     This typically happens when the EPSILON defined in
  #     emd.h is not right for the scale of the problem.
  #     emd: errr in findBasicVariables
  #
  # It's not clear why this happens (without looking at the source).
  #
  echo "
    cd parsec-benchmark &&
    HOSTTYPE=riscv64 bin/parsecmgmt -a run -p ferret -i $c_input_type -n $threads
  "
}
