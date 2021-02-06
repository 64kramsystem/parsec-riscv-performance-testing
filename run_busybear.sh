#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_temp_dir=$(dirname "$(mktemp)")

c_local_ssh_port=10000

c_qemu_binary=$c_components_dir/qemu-system-riscv64
c_vcpus=$(nproc)
c_guest_memory=14G
c_guest_image_source=$c_components_dir/busybear.bin
c_guest_image_run=$c_temp_dir/busybear.run.qcow2
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin

function create_temp_image {
  qemu-img create -f qcow2 -b "$c_guest_image_source" "$c_guest_image_run"
}

function run_qemu {
  "$c_qemu_binary" \
    -nographic \
    -machine virt \
    -smp "$c_vcpus",cores="$c_vcpus",sockets=1,threads=1 \
    -accel tcg,thread=multi \
    -m "$c_guest_memory" \
    -kernel "$c_kernel_image" \
    -bios "$c_bios_image" \
    -append "root=/dev/vda ro console=ttyS0" \
    -drive file="$c_guest_image_run",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_local_ssh_port"-:22
}

create_temp_image
run_qemu
