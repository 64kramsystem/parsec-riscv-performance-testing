#!/bin/bash

set -o errexit
set -o nounset

if [[ $# -ne 2 || $1 == "--help" || $1 == "-h" ]]; then
  echo '$1: directory 1; $2: directory 2'
  echo 'The name and number of files must match'
  exit 1
fi

dir_1=$1
dir_2=$2

cd "$(readlink -f "$(dirname "$0")")"/..

if [[ $(ls -1 "$dir_1") != $(ls -1 "$dir_2") ]]; then
  echo "The dirs content doesn't match"
  exit 1
fi

for file_1 in "$dir_1"/*; do
  file_2=$dir_2/$(basename "$file_1")

  ./plot_diagram.sh --dir "$file_1" "$file_2"
done
