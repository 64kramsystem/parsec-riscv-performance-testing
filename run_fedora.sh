#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_components_dir=$(readlink -f "$(dirname "$0")")/components

c_local_ssh_port=10000

c_qemu_binary=$c_components_dir/qemu-system-riscv64
c_vcpus=$(nproc)
c_guest_memory=8G
c_guest_image_source=$c_components_dir/Fedora-Minimal-Rawhide-20200108.n.0-sda.qcow2
c_guest_image_diff=${c_guest_image_source/.qcow2/.diff.qcow2}
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin

# Original Fedora configuration; requires `-append` to be removed.
#
# c_kernel_image=$c_components_dir/Fedora-Minimal-Rawhide-20200108.n.0-fw_payload-uboot-qemu-virt-smode.elf
# c_bios_image=none

qemu-img create -f qcow2 -b "$c_guest_image_source" "$c_guest_image_diff"

echo 'Credentials (user:pwd) = riscv:fedora_rocks!'

"$c_qemu_binary" \
   -nographic \
   -machine virt \
   -smp "$c_vcpus",cores="$c_vcpus",sockets=1,threads=1 \
   -accel tcg,thread=multi \
   -m "$c_guest_memory" \
   -kernel "$c_kernel_image" \
   -bios "$c_bios_image" \
   -append "root=/dev/vda4 ro console=ttyS0" \
   -object rng-random,filename=/dev/urandom,id=rng0 \
   -device virtio-rng-device,rng=rng0 \
   -device virtio-blk-device,drive=hd0 \
   -drive file="$c_guest_image_diff",format=qcow2,id=hd0 \
   -device virtio-net-device,netdev=usernet \
   -netdev user,id=usernet,hostfwd=tcp::"$c_local_ssh_port"-:22
