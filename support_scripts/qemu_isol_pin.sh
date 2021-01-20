# For simplicity (of code), c_min_threads must be a power of 2, and less than (nproc -1).
#
c_min_threads=2
c_max_threads=128

# nproc doesn't work with isolcpus - it counts only the processors used by the kernel.
#
# The output of `/sys/devices/system/cpu/online` is in the format `0-15`.
#
function find_num_proc_isolcpu {
  awk -F- '{ print ($2 + 1) }' /sys/devices/system/cpu/online
}

# Generates threads numbers that exclude one cpu, e.g., for 32: 2, 4, 8, 16, 31, 62.
#
# For nproc that are a power of 2, the math is:
#
# - 2^n                       for n <  log₂(nproc)
# - 2^n - 2^(n-log₂(nproc))   for n >= log₂(nproc)
#
# However, procedural logic is simpler and also covers nproc that are not a power of 2.
#
function prepare_threads_number_list {
  local num_proc=$(find_num_proc_isolcpu)

  v_thread_numbers_list=()
  exceeded_host_procs=

  for ((threads_number = c_min_threads; threads_number <= c_max_threads; threads_number *= 2)); do
    if ((threads_number >= num_proc && !exceeded_host_procs)); then
      threads_number=$(( num_proc - 1))
      exceeded_host_procs=1
    fi

    v_thread_numbers_list+=("$threads_number")
  done

  echo "Threads number list: ${v_thread_numbers_list[@]}"
}

# Input: $1=Number of vCPUs.
#
function boot_guest {
  vcpus=$1
  pinning_options=()

  local num_proc=$(find_num_proc_isolcpu)

  echo "Affinities:"

  for ((vcpu = 0; vcpu < vcpus; vcpu++)); do
    local assignment="vcpunum=$vcpu,affinity=$(( 1 + vcpu % (num_proc - 1) ))"
    pinning_options+=( -vcpu "$assignment")
    echo "  $assignment"
  done

  "$c_qemu_binary" \
    -display none -daemonize \
    -pidfile "$c_qemu_pidfile" \
    -machine virt \
    -smp "$vcpus",cores="$vcpus",sockets=1,threads=1 \
    "${pinning_options[@]}" \
    -accel tcg,thread=multi \
    -m "$c_guest_memory" \
    -kernel "$c_kernel_image" \
    -bios "$c_bios_image" \
    -append "root=/dev/vda ro console=ttyS0" \
    -drive file="$c_guest_image_run",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_ssh_port"-:22
}
