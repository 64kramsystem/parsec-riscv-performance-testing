# WATCH OUT! This script assumes that the isolated CPUs are at the beginning, and contiguous!
#
# The semantics of "cpus" is the Linux one - procs are HARTs.
#
# In order to isolate CPUs (and restore):
#
#     perl -i.bak -pe 's/GRUB_CMDLINE_LINUX_DEFAULT.*\K"/ isolcpus=2-31"/' /etc/default/grub
#     update-grub
#
#     perl -i.bak -pe 's/ isolcpus=2-31//' /etc/default/grub
#     update-grub
#
c_qemu_output_log_file=$(basename "${BASH_SOURCE[0]}").out.log

# For simplicity (of code), c_min_threads must be a power of 2, and less than (nproc -1).
#
c_min_threads=2
c_max_threads=128

# 0-based number of the first available CPU.
#
# nproc returns the number of CPUs available to the kernel; in the script conditions, since the result
# is 1-based, it's also the 0-based index of the first unavailable cpu.
#
first_available_cpu=$(nproc)

function count_available_cpus {
  local tot_cpus
  tot_cpus=$(grep -c '^processor' /proc/cpuinfo)

  echo $(( tot_cpus - first_available_cpu ))
}

# Generates threads numbers that exclude one cpu, e.g., for 32: 2, 4, 8, 16, 31, 62 (or 30, 60, depending
# on the SMT being enabled or not.)
#
# There are different approaches to this (previously, a couple were referenced); this is the simplest
# (most st00pid).
#
function prepare_threads_number_list {
  local available_cpus
  available_cpus=$(count_available_cpus)

  v_thread_numbers_list=()

  # WATCH OUT! We ignore the case where (available_cpus > c_max_threads); it would also (likely) be
  # undesirable.
  #
  for ((threads_number = c_min_threads; threads_number < available_cpus; threads_number *= 2)); do
    v_thread_numbers_list+=("$threads_number")
  done

  for ((threads_number = available_cpus; threads_number <= c_max_threads ; threads_number *= 2)); do
    v_thread_numbers_list+=("$threads_number")
  done

  echo "Threads number list: ${v_thread_numbers_list[*]}"
}

# Input: $1=Number of vCPUs.
#
function boot_guest {
  local vcpus=$1
  local pinning_options=()

  local available_cpus
  available_cpus=$(count_available_cpus)

  echo "Affinities:"

  for ((vcpu = 0; vcpu < vcpus; vcpu++)); do
    local assignment="vcpunum=$vcpu,affinity=$(( first_available_cpu + vcpu % available_cpus ))"
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
