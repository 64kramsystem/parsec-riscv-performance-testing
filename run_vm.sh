#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_temp_dir=$(dirname "$(mktemp)")
c_temp_image=$c_temp_dir/guest.temp.qcow2

c_local_ssh_port=10000

c_qemu_binary=$c_components_dir/qemu-system-riscv64
c_vcpus=$(nproc)
c_guest_memory=14G
c_kernel_image=$c_components_dir/Image
c_bios_image=$c_components_dir/fw_dynamic.bin
c_default_boot_block_device=/dev/vda

c_help="Usage: $(basename "$0") [-n|--no-temp] <image> [<boot_block_device>]

Examples:

    $(basename "$0") components/busybear.qcow2
    $(basename "$0") projects/Fedora-Minimal-Rawhide-20200108.n.0-sda.raw /dev/vda4
"

# User-defined variables

v_image=              # string
v_use_temp_image=1    # boolean (blank: false, anything else: true)

# Computed variables

v_run_image=                 # string
v_run_image_format=          # string
v_run_boot_block_device=     # string

function decode_cmdline_options {
  eval set -- "$(getopt --options hn --long help,no-temp --name "$(basename "$0")" -- "$@")"

  while true ; do
    case "$1" in
      -h|--help)
        echo "$c_help"
        exit 0 ;;
      -n|--no-temp)
        v_use_temp_image=
        shift ;;
      --)
        shift
        break ;;
    esac
  done

  if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "$c_help"
    exit 1
  fi

  v_image=$(readlink -f "$1")
  v_run_boot_block_device=${2:-$c_default_boot_block_device}
}

function prepare_run_image_metadata {
  if [[ -n $v_use_temp_image ]]; then
    qemu-img create -f qcow2 -b "$v_image" "$c_temp_image"

    v_run_image=$c_temp_image
    v_run_image_format=qcow2
  else
    v_run_image=$v_image

    # Simplistic format test
    #
    if [[ $v_run_image == *.qcow2 || $(file "$v_run_image") == *"QEMU QCOW2 Image"* ]]; then
      v_run_image_format=qcow2
    else
      v_run_image_format=raw
    fi

    echo ">>> Warning: running with source image: $(basename "$v_image")"
    read -rsn1
  fi

  # The boot block device could be gathered via `virt-filesystems`, but it requires a very rough heuristic,
  # since the partition flags (e.g. `boot) are not provided.
}

function register_exit_hook {
  function _exit_hook {
    if [[ -n $v_use_temp_image ]]; then
      rm -f "$v_run_image"
    fi
  }

  trap _exit_hook EXIT
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
    -append "root=$v_run_boot_block_device ro console=ttyS0" \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0 \
    -device virtio-blk-device,drive=hd0 \
    -drive file="$v_run_image",format="$v_run_image_format",id=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_local_ssh_port"-:22
}

decode_cmdline_options "$@"
prepare_run_image_metadata
register_exit_hook
run_qemu
