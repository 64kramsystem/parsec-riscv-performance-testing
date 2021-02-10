c_pigz_input_file_path=$(ls -1 "$c_components_dir"/*.pigz_input)
c_pigz_input_file_basename=$(basename "$c_pigz_input_file_path")

# Input: $1=Number of threads.
#
function compose_benchmark_command {
  local threads=$1

  # Watch out! `time`'s output goes to stderr, and in order to capture it, we must redirect it to
  # stdout. `pigz` makes things a bit confusing, since the output must be necessarily discarded.
  #
  # Note that this returns the time in format `000.00s`, instead of `000,00s`, but `run_benchmark` accepts
  # both.
  #
  echo "
    cat $c_pigz_input_file_basename > /dev/null &&
    /usr/bin/time -f 'ROI time measured: %es' ./pigz --stdout --processes $threads $c_pigz_input_file_basename 2>&1 > /dev/null
  "
}
