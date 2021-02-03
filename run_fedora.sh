#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

vcpus=$(nproc)

local_ssh_port=10000

c_components_dir=$(readlink -f "$(dirname "$0")")/components

qemu_binary=$c_components_dir/qemu-system-riscv64
memory=8G
source_image=$c_components_dir/Fedora-Minimal-Rawhide-20200108.n.0-sda.qcow2
kernel_image=$c_components_dir/Image
bios_image=$c_components_dir/fw_dynamic.bin

# Original Fedora configuration; requires `-append` to be removed.
#
# kernel_image=$c_components_dir/Fedora-Minimal-Rawhide-20200108.n.0-fw_payload-uboot-qemu-virt-smode.elf
# bios_image=none

diff_image=${source_image/.qcow2/.diff.qcow2}

qemu-img create -f qcow2 -b "$source_image" "$diff_image"

echo 'Credentials (user:pwd) = riscv:fedora_rocks!'

"$qemu_binary" \
   -nographic \
   -machine virt \
   -smp "$vcpus",cores="$vcpus",sockets=1,threads=1 \
   -accel tcg,thread=multi \
   -m "$memory" \
   -kernel "$kernel_image" \
   -bios "$bios_image" \
   -append "root=/dev/vda4 ro console=ttyS0" \
   -object rng-random,filename=/dev/urandom,id=rng0 \
   -device virtio-rng-device,rng=rng0 \
   -device virtio-blk-device,drive=hd0 \
   -drive file="$diff_image",format=qcow2,id=hd0 \
   -device virtio-net-device,netdev=usernet \
   -netdev user,id=usernet,hostfwd=tcp::"$local_ssh_port"-:22
