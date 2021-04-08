#!/bin/bash

set -o errexit
set -o nounset

if [[ $# -ne 1 || $1 == "--help" || $1 == "-h" ]]; then
  echo '$1: on|off'
  exit 1
fi

new_state=$1

case $new_state in
on)
  sudo perl -i.bak -pe 's/GRUB_CMDLINE_LINUX_DEFAULT.*\K"/ isolcpus=1-15,17-31"/' /etc/default/grub
  sudo update-grub
  ;;
off)
  sudo perl -i.bak -pe 's/ ?isolcpus=[0-9,-]+//' /etc/default/grub
  sudo update-grub
  ;;
*)
  echo "Invalid: $new_state"
  ;;
esac
