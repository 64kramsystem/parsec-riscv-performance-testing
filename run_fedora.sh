#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

qemu_binary=qemu-system-riscv64-pin
smp_options=(
  -smp 8,cores=4,sockets=1,threads=2
  -vcpu vcpunum=0,affinity=0
  -vcpu vcpunum=1,affinity=1
  -vcpu vcpunum=2,affinity=2
  -vcpu vcpunum=3,affinity=3
  -vcpu vcpunum=4,affinity=4
  -vcpu vcpunum=5,affinity=5
  -vcpu vcpunum=6,affinity=6
  -vcpu vcpunum=7,affinity=7
)
memory=8G
source_image=Fedora-Minimal-Rawhide-20200108.n.0-sda.qcow2
local_ssh_port=10000

diff_image=${source_image/.qcow2/.diff.qcow2}

# qemu-img create -f qcow2 -b "$source_image" "$diff_image"
echo ">>> diff image not reset"
sleep 3

echo 'Credentials (user:pwd) = riscv:fedora_rocks!'

"$qemu_binary" \
   -nographic \
   -machine virt \
   "${smp_options[@]}" \
   -accel tcg,thread=multi \
   -m "$memory" \
   -kernel Fedora-Minimal-Rawhide-20200108.n.0-fw_payload-uboot-qemu-virt-smode.elf \
   -bios none \
   -object rng-random,filename=/dev/urandom,id=rng0 \
   -device virtio-rng-device,rng=rng0 \
   -device virtio-blk-device,drive=hd0 \
   -drive file="$diff_image",format=qcow2,id=hd0 \
   -device virtio-net-device,netdev=usernet \
   -netdev user,id=usernet,hostfwd=tcp::"$local_ssh_port"-:22 \
   # -daemonize \
