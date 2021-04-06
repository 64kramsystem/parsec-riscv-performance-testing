# WATCH OUT! This script assumes that the isolated CPUs are at the beginning, and contiguous!
#
# The semantics of "cpus" is the Linux one - procs are HARTs.
#
# In order to isolate CPUs (and restore):
#
#     perl -i.bak -pe 's/GRUB_CMDLINE_LINUX_DEFAULT.*\K"/ isolcpus=1-15,17-31"/' /etc/default/grub
#     update-grub
#
#     perl -i.bak -pe 's/ ?isolcpus=[0-9,-]+//' /etc/default/grub
#     update-grub
#

# Generates threads numbers that exclude one cpu, e.g., for 32: 2, 4, 8, 16, 31, 62 (or 30, 60, depending
# on the SMT being enabled or not.)
#
# There are different approaches to this (previously, a couple were referenced); this is the simplest
# (most st00pid).
#
function prepare_threads_number_list {
  local isolated_cores=${#v_isolated_processors[@]}

  if [[ -n v_disable_smt ]]; then
    isolated_cores=$((isolated_cores / 2))
  fi

  # WATCH OUT! We ignore the case where (isolated_cores > v_max_threads); it would also (likely) be
  # undesirable.
  #
  for ((threads_number = v_min_threads; threads_number < isolated_cores; threads_number *= 2)); do
    v_thread_numbers_list+=("$threads_number")
  done

  for ((threads_number = isolated_cores; threads_number <= v_max_threads ; threads_number *= 2)); do
    if ((threads_number >= v_min_threads)); then
      v_thread_numbers_list+=("$threads_number")
    fi
  done

  echo "Threads number list: ${v_thread_numbers_list[*]}"
}

# Input: $1=Number of vCPUs.
#
function boot_guest {
  local vcpus=$1
  local pinning_options=()

  echo "Affinities:"
  for ((vcpu = 0; vcpu < vcpus; vcpu++)); do
    local isolated_processor_i=$((vcpu % ${#v_isolated_processors[@]}))
    local assignment="vcpunum=$vcpu,affinity=${v_isolated_processors[$isolated_processor_i]}"
    pinning_options+=( -vcpu "$assignment")
    echo "  $assignment"
  done

  "$c_qemu_binary" \
    -display none -daemonize \
    -serial file:"$c_qemu_output_log_file" \
    -pidfile "$c_qemu_pidfile" \
    -machine virt \
    -smp "$vcpus",cores="$vcpus",sockets=1,threads=1 \
    "${pinning_options[@]}" \
    -accel tcg,thread=multi \
    -m "$c_guest_memory" \
    -kernel "$c_kernel_image" \
    -bios "$c_bios_image" \
    -append "root=/dev/vda ro console=ttyS0" \
    -drive file="$c_guest_image_temp",format=qcow2,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_ssh_port"-:22
}
