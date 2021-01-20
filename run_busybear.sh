#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

vcpus=$(nproc)

c_ssh_port=10000

c_components_dir=$(readlink -f "$(dirname "$0")")/components

c_qemu_binary=$c_components_dir/qemu-system-riscv64

c_guest_memory=8G
c_guest_image_source=$c_components_dir/busybear.bin
c_guest_image_run=$c_components_dir/busybear.run.bin
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin

cp "$c_guest_image_source" "$c_guest_image_run"

"$c_qemu_binary" \
  -nographic \
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
