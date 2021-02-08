#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_projects_dir=$(readlink -f "$(dirname "$0")")/projects
c_temp_dir=$(dirname "$(mktemp)")

c_local_ssh_port=10000

c_qemu_binary=$c_components_dir/qemu-system-riscv64
c_vcpus=$(nproc)
c_guest_memory=14G
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin

c_original_image=$c_projects_dir/Fedora-Minimal-Rawhide-20200108.n.0-sda.raw
c_prepared_image=$c_projects_dir/Fedora-Minimal-Rawhide-20200108.n.0-sda.prepared.qcow2
c_run_image=$c_temp_dir/fedora.run.qcow2

c_help="Usage: $(basename "$0") [-p|--prepared]"

v_use_prepared_image= # boolean (blank: false, anything else: true)
v_use_temp_image=1    # boolean (blank: false, anything else: true)

function decode_cmdline_options {
  eval set -- "$(getopt --options hpn --long help,prepared,no-temp --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -p|--prepared)
        v_use_prepared_image=1
        shift ;;
      -n|--no-temp)
        v_use_temp_image=
        shift ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -ne 0 ]]; then
    echo "$c_help"
    exit 1
  fi
}

function prepare_run_image {
  if [[ -n $v_use_prepared_image ]]; then
    local source_image=$c_prepared_image
  else
    local source_image=$c_original_image
  fi

  if [[ -n $v_use_temp_image ]]; then
    qemu-img create -f qcow2 -b "$source_image" "$c_run_image"
  else
    c_run_image=$source_image

    echo ">>> Warning: running with source image: $(basename "$c_run_image")"
    read -rsn1
  fi
}

function run_qemu {
  # Original Fedora configuration; requires `-append` to be removed.
  #
  # c_kernel_image=$c_components_dir/Fedora-Minimal-Rawhide-20200108.n.0-fw_payload-uboot-qemu-virt-smode.elf
  # c_bios_image=none

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
    -drive file="$c_run_image",format=qcow2,id=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_local_ssh_port"-:22
}

decode_cmdline_options "$@"
prepare_run_image
run_qemu
