# Input: $1=Number of vCPUs.
#
function boot_guest {
  local vcpus=$1

  "$c_qemu_binary" \
    -display none -daemonize \
    -pidfile "$c_qemu_pidfile" \
    -machine virt \
    -smp "$vcpus",cores="$vcpus",sockets=1,threads=1 \
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
