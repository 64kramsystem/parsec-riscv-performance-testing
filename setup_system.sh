#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

####################################################################################################
# VARIABLES/CONSTANTS
####################################################################################################

c_components_dir=$(readlink -f "$(dirname "$0")")/components
c_projects_dir=$(readlink -f "$(dirname "$0")")/projects

c_debug_log_file=$(basename "$0").log

c_toolchain_address=https://github.com/riscv/riscv-gnu-toolchain.git
c_linux_repo_address=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
c_fedora_image_address=https://dl.fedoraproject.org/pub/alt/risc-v/repo/virt-builder-images/images/Fedora-Minimal-Rawhide-20200108.n.0-sda.raw.xz
c_opensbi_tarball_address=https://github.com/riscv/opensbi/releases/download/v0.9/opensbi-0.9-rv-bin.tar.xz
c_busybear_repo_address=https://github.com/michaeljclark/busybear-linux.git
c_qemu_repo_address=https://github.com/saveriomiroddi/qemu-pinning.git
c_parsec_benchmark_address=git@github.com:saveriomiroddi/parsec-benchmark-tweaked.git
c_parsec_inputs_address=http://parsec.cs.princeton.edu/download/3.0/parsec-3.0-input-sim.tar.gz
c_zlib_repo_address=https://github.com/madler/zlib.git
c_pigz_repo_address=https://github.com/madler/pigz.git

# The file_path can be anything, as long as it ends with '.pigz_input', so that it's picked up by the
# benchmark script.
c_pigz_input_file_address=https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-10.7.0-amd64-mate.iso

c_busybear_image=$c_components_dir/busybear.bin
c_busybear_image_mount_path=/mnt
export c_busybear_image_size=5120 # integer; number of megabytes
c_fedora_image_size=20G
c_fedora_run_memory=8G
c_local_ssh_port=10000
c_local_fedora_raw_image_path=$c_projects_dir/$(echo "$c_fedora_image_address" | perl -ne 'print /([^\/]+)\.xz$/')
c_local_fedora_prepared_image_path="${c_local_fedora_raw_image_path/.raw/.prepared.qcow2}"
c_fedora_temp_expanded_image_path=$(dirname "$(mktemp)")/fedora.temp.expanded.raw
c_fedora_temp_build_image_path=$(dirname "$(mktemp)")/fedora.temp.build.raw
c_local_parsec_inputs_path=$c_projects_dir/$(basename "$c_parsec_inputs_address")
c_qemu_binary=$c_projects_dir/qemu-pinning/bin/debug/native/qemu-system-riscv64
c_qemu_pidfile=${XDG_RUNTIME_DIR:-/tmp}/$(basename "$0").qemu.pid

c_compiler_binary=$c_projects_dir/riscv-gnu-toolchain/build/bin/riscv64-unknown-linux-gnu-gcc
c_riscv_firmware_file=share/opensbi/lp64/generic/firmware/fw_dynamic.bin # relative
c_pigz_input_file=$c_components_dir/$(basename "$c_pigz_input_file_address").pigz_input
c_pigz_binary_file=$c_projects_dir/pigz/pigz
c_libz_file=$c_projects_dir/zlib/libz.so.1

c_help='Usage: $(basename "$0")

Downloads/compiles all the components required for a benchmark run: toolchain, Linux kernel, Busybear, QEMU, benchmarked programs and their data.

Components are stored in `'"$c_components_dir"'`, and projects in `'"$c_projects_dir"'`; if any component is present, it'\''s not downloaded/compiled again.

The toolchain project is very large. If existing already on the machine, building can be avoided by symlinking the repo under `'"$c_projects_dir"'`.

Prepares the image with the required files (stored in the root home).
'

####################################################################################################
# MAIN FUNCTIONS
####################################################################################################

function decode_cmdline_args {
  # Poor man's options decoding.
  #
  if [[ $# -ne 0 ]]; then
    echo "$c_help"
    exit 0
  fi
}

function create_directories {
  mkdir -p "$c_components_dir"
  mkdir -p "$c_projects_dir"
}

function init_debug_log {
  exec 5> "$c_debug_log_file"
  BASH_XTRACEFD="5"
  set -x
}

# Ask sudo permissions only once over the runtime of the script.
#
function cache_sudo {
  sudo -v

  while true; do
    sleep 60
    kill -0 "$$" || exit
    sudo -nv
  done 2>/dev/null &
}

function add_toolchain_binaries_to_path {
  export PATH="$c_projects_dir/riscv-gnu-toolchain/build/bin:$PATH"
}

function install_base_packages {
  sudo apt update
  sudo apt install -y git build-essential sshpass pigz gnuplot libguestfs-tools
}

function download_projects {
  local project_addresses=(
    "$c_toolchain_address"
    "$c_linux_repo_address"
    "$c_busybear_repo_address"
    "$c_qemu_repo_address"
    "$c_parsec_benchmark_address"
    "$c_zlib_repo_address"
    "$c_pigz_repo_address"
  )

  cd "$c_projects_dir"

  for project_address in "${project_addresses[@]}"; do
    project_basename=$(echo "$project_address" | perl -ne 'print /([^\/]+)\.git$/')

    if [[ -d $project_basename ]]; then
      echo "\`$project_basename\` project found; not cloning..."
    else
      if [[ $project_basename == "busybear-linux" || $project_basename == "riscv-gnu-toolchain" ]]; then
        git clone --recursive "$project_address"
      else
        git clone "$project_address"
      fi
    fi
  done

  # Tarballs

  if [[ -f $c_local_fedora_raw_image_path ]]; then
    echo "\`$(basename "$c_local_fedora_raw_image_path")\` image found; not downloading..."
  else
    wget --output-document=/dev/stdout "$c_fedora_image_address" | xz -d > "$c_local_fedora_raw_image_path"
  fi

  local opensbi_project_basename
  opensbi_project_basename=$(echo "$c_opensbi_tarball_address" | perl -ne 'print /([^\/]+)\.tar.\w+$/')

  if [[ -d $c_projects_dir/$opensbi_project_basename ]]; then
    echo "\`$opensbi_project_basename\` project found; not downloading..."
  else
    wget --output-document=/dev/stdout "$c_opensbi_tarball_address" | tar xJ --directory="$c_projects_dir"
  fi
}

function build_toolchain {
  sudo apt install -y autoconf automake autotools-dev curl python3 libmpc-dev libmpfr-dev libgmp-dev gawk \
           bison flex texinfo gperf libtool patchutils bc zlib1g-dev libexpat1-dev

  cd "$c_projects_dir/riscv-gnu-toolchain"

  ./configure --prefix="$PWD/build"
  make linux
}

# This step is required by Busybear; see https://github.com/michaeljclark/busybear-linux/issues/10.
#
function prepare_toolchain {
  echo "Preparing the toolchain..."

  cd "$c_projects_dir/riscv-gnu-toolchain/build/sysroot/usr/include/gnu"

  if [[ ! -e stubs-lp64.h ]]; then
    ln -s stubs-lp64d.h stubs-lp64.h
  fi
}

function prepare_linux_kernel {
  echo "Preparing the Linux kernel..."

  # Some required packages are installed ahead (flex, bison...).

  cd "$c_projects_dir/linux-stable"

  git checkout arch/riscv/Kconfig

  git checkout v5.9.6

  patch -p0 << DIFF
--- arch/riscv/Kconfig	2021-01-31 13:34:53.745703592 +0100
+++ arch/riscv/Kconfig.256cpus	2021-01-31 13:42:50.703249777 +0100
@@ -271,8 +271,8 @@
 	  If you don't know what to do here, say N.
 
 config NR_CPUS
-	int "Maximum number of CPUs (2-32)"
-	range 2 32
+	int "Maximum number of CPUs (2-256)"
+	range 2 256
 	depends on SMP
 	default "8"
DIFF

  make CC="$c_compiler_binary" ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- defconfig

  # Changes:
  #
  # - timer frequency: 100 Hz
  # - max cpus: 256
  #
  patch -p0 << DIFF
--- .config	2021-01-29 22:47:04.394433735 +0100
+++ .config.100hz_256cpus	2021-01-29 22:46:43.262537170 +0100
@@ -245,7 +245,7 @@
 # CONFIG_MAXPHYSMEM_2GB is not set
 CONFIG_MAXPHYSMEM_128GB=y
 CONFIG_SMP=y
-CONFIG_NR_CPUS=8
+CONFIG_NR_CPUS=256
 # CONFIG_HOTPLUG_CPU is not set
 CONFIG_TUNE_GENERIC=y
 CONFIG_RISCV_ISA_C=y
@@ -255,11 +255,11 @@
 #
 # Kernel features
 #
-# CONFIG_HZ_100 is not set
-CONFIG_HZ_250=y
+CONFIG_HZ_100=y
+# CONFIG_HZ_250 is not set
 # CONFIG_HZ_300 is not set
 # CONFIG_HZ_1000 is not set
-CONFIG_HZ=250
+CONFIG_HZ=100
 CONFIG_SCHED_HRTICK=y
 # CONFIG_SECCOMP is not set
 CONFIG_RISCV_SBI_V01=y
DIFF
}

function prepare_busybear {
  echo "Preparing BusyBear..."

  cd "$c_projects_dir/busybear-linux"

  # 100 MB ought to be enough for everybody, but raise it to $c_busybear_image_size anyway.
  #
  perl -i -pe "s/^IMAGE_SIZE=\K.*/$c_busybear_image_size/" conf/busybear.config

  # Correct the networking to use QEMU's user networking. Busybear's default networking setup (bridging)
  # is overkill and generally not working.
  #
  cat > etc/network/interfaces << CFG
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
        address 10.0.2.15
        netmask 255.255.255.0
        broadcast 10.0.2.255
        gateway 10.0.2.2
CFG
}

function prepare_qemu {
  echo "Preparing QEMU..."

  cd "$c_projects_dir/qemu-pinning"

  git checkout include/hw/riscv/virt.h

  git checkout v5.2.0-pinning

  # Allow more than v8 CPUs for the RISC-V virt machine.
  #
  perl -i -pe 's/^#define VIRT_(CPU|SOCKET)S_MAX \K.*/256/' include/hw/riscv/virt.h
}

function build_linux_kernel {
  cd "$c_projects_dir/linux-stable"

  linux_kernel_file=arch/riscv/boot/Image

  if [[ -f $linux_kernel_file ]]; then
    echo "Compiled Linux kernel found; not compiling/copying..."
  else
    make ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- -j "$(nproc)"

    cp "$linux_kernel_file" "$c_components_dir"/
  fi
}

function build_busybear {
  cd "$c_projects_dir/busybear-linux"

  busybear_image_file=busybear.bin

  if [[ -f $busybear_image_file ]]; then
    echo "Busybear image found; not making/copying..."
  else
    echo 'WATCH OUT!! Busybear may fail without useful messages. If this happens, add `set -x` on top of its `build.sh` script.'

    make

    cp "$busybear_image_file" "$c_components_dir"/
  fi
}

function build_qemu {
  cd "$c_projects_dir/qemu-pinning"

  if [[ -f $c_qemu_binary ]]; then
    echo "QEMU binary found; not compiling/copying..."
  else
    ./build_pinning_qemu_binary.sh --target=riscv64 --yes

    cp "$c_qemu_binary" "$c_components_dir"/
  fi
}

# Depends on QEMU.
#
function prepare_fedora {
  echo "Preparing Fedora..."

  # Chunky procedure, so don't redo it if the file exists.
  #
  if [[ -f $c_local_fedora_prepared_image_path ]]; then
    echo "Prepared fedora image found; not processing..."
  else
    ####################################
    # Extend image
    ####################################

    rm -f "$c_fedora_temp_expanded_image_path"

    truncate -s "$c_fedora_image_size" "$c_fedora_temp_expanded_image_path"
    sudo virt-resize -v -x --expand /dev/sda4 "$c_local_fedora_raw_image_path" "$c_fedora_temp_expanded_image_path"

    ######################################
    # Set passwordless sudo
    ######################################

    local local_mount_dir=/mnt

    local loop_device
    loop_device=$(sudo losetup --show --find --partscan "$c_fedora_temp_expanded_image_path")

    # Watch out, must mount partition 4
    sudo mount "${loop_device}p4" "$local_mount_dir"

    # Sud-bye!
    sudo sed -i '/%wheel.*NOPASSWD: ALL/ s/^# //' "$local_mount_dir/etc/sudoers"

    sudo umount "$local_mount_dir"
    sudo losetup -d "$loop_device"

    ####################################
    # Start Fedora
    ####################################

    # Make sure there's no zombie around.
    #
    pkill -f "$(basename "$c_qemu_binary")" || true

    start_fedora "$c_fedora_temp_expanded_image_path"

    ####################################
    # Disable long-running service
    ####################################

    run_fedora_command 'sudo systemctl mask man-db-cache-update'

    ####################################
    # Install packages and copy PARSEC
    ####################################

    run_fedora_command 'sudo dnf groupinstall -y "Development Tools" "Development Libraries"'
    run_fedora_command 'sudo dnf install -y tar gcc-c++ texinfo parallel'
    # To replace with xargs once the script is releasable.
    run_fedora_command 'echo "will cite" | parallel --citation || true'

    tar c --directory "$c_projects_dir" --exclude=parsec-benchmark/.git parsec-benchmark | run_fedora_command "tar xv" | grep '/$'

    shutdown_fedora

    ####################################
    # Compress and cleanup
    ####################################

    sudo virt-sparsify --convert qcow2 --compress "$c_fedora_temp_expanded_image_path" "$c_local_fedora_prepared_image_path"
    sudo chown "$USER": "$c_local_fedora_prepared_image_path"

    # Don't bother with exit traps, but at least delete it on script restart, if present.
    #
    rm "$c_fedora_temp_expanded_image_path"
  fi
}

function copy_opensbi_firmware {
  cd "$c_projects_dir"/opensbi-*-rv-bin/

  cp "$c_riscv_firmware_file" "$c_components_dir"/
}

function build_pigz {
  if [[ -f $c_pigz_binary_file ]]; then
    echo "pigz binary found; not compiling/copying..."
  else
    cd "$c_projects_dir/zlib"

    # For the zlib project included in the RISC-V toolchain, append `--host=x86_64`.
    #
    CC="$c_compiler_binary" ./configure
    make

    cd "$c_projects_dir/pigz"

    make "CC=$c_compiler_binary -I $c_projects_dir/zlib -L $c_projects_dir/zlib"

    cp "$c_pigz_binary_file" "$c_components_dir"/
  fi
}

function build_parsec {
  # double check the name
  #
  local sample_built_package=$c_projects_dir/parsec-benchmark/pkgs/apps/blackscholes/inst/riscv64-linux.gcc/bin/blackscholes

  if [[ -f $sample_built_package ]]; then
    echo "Sample PARSEC package found ($(basename "$sample_built_package")); not building..."
  else
    # Technically, we could leave the QEMU hanging around and copy directly from the VM to the BusyBear
    # image in the appropriate stage, but better to separate stages very clearly.
    #
    echo "Building PARSEC suite in the Fedora VM, and copying it back..."

    # Make sure there's no zombie around.
    #
    pkill -f "$(basename "$c_qemu_binary")" || true

    cp "$c_local_fedora_prepared_image_path" "$c_fedora_temp_build_image_path"

    start_fedora "$c_fedora_temp_build_image_path"

    # Some packages depend on zlib, so we build it first.
    #
    run_fedora_command "
      cd parsec-benchmark &&
      bin/parsecmgmt -a build -p zlib &&
      parallel bin/parsecmgmt -a build -p ::: parmacs gsl libjpeg libxml2
    "

    local parsec_packages=(
      parsec.blackscholes
      parsec.bodytrack
      parsec.dedup
      parsec.facesim
      parsec.ferret
      parsec.fluidanimate
      parsec.freqmine
      parsec.streamcluster
      parsec.swaptions
      parsec.vips
      splash2x.barnes
      splash2x.cholesky
      splash2x.fft
      splash2x.fmm
      splash2x.lu_cb
      splash2x.lu_ncb
      splash2x.ocean_cp
      splash2x.ocean_ncp
      splash2x.radiosity
      splash2x.radix
      splash2x.raytrace
      splash2x.volrend
      splash2x.water_nsquared
      splash2x.water_spatial
    )

    # The optimal number of parallel processes can't be easily assessed. Considering that each build
    # has nproc max jobs, and that builds work in bursts, 12.5% builds/nproc (e.g. 4 on 32) should be
    # reasonable.
    # The build time is dominated anyway by `vips`, which is significantly longer than the other ones.

    run_fedora_command "
      cd parsec-benchmark &&
      parallel --max-procs=12.5% bin/parsecmgmt -a build -p ::: ${parsec_packages[*]}
    "

    run_fedora_command "tar c parsec-benchmark" | tar xv --directory="$c_projects_dir" | grep '/$'

    shutdown_fedora
  fi
}

function download_pigz_input_file {
  if [[ -f $c_pigz_input_file ]]; then
    echo "Pigz input file found; not downloading..."
  else
    wget "$c_pigz_input_file_address" -O "$c_pigz_input_file"
  fi
}

# For simplicity, just run it without checking if the files already exist.
#
function copy_data_to_guest_image {
  local source_files=(
    "$c_pigz_input_file"
    "$c_pigz_binary_file"
  )

  local loop_device
  loop_device=$(sudo losetup --show --find --partscan "$c_busybear_image")

  sudo mount "$loop_device" "$c_busybear_image_mount_path"

  for source_file in "${source_files[@]}"; do
    local destination_file
    destination_file=$c_busybear_image_mount_path/root/$(basename "$source_file")

    if [[ -f $destination_file ]]; then
      echo "Skipping $source_file (existing in guest image)..."
    else
      echo "Copying $source_file to guest image..."
      sudo cp "$source_file" "$c_busybear_image_mount_path"/
    fi
  done

  # This goes into a different directory. It's small, so we copy it regardless.
  #
  echo "Copying $(basename "$c_libz_file") to guest image (regardless)..."
  sudo cp "$c_libz_file" "$c_busybear_image_mount_path"/lib/

  sudo umount "$c_busybear_image_mount_path"

  sudo losetup -d "$loop_device"
}

function print_completion_message {
  echo "Preparation completed!"
}

####################################################################################################
# HELPERS
####################################################################################################

# $1: disk image
#
function start_fedora {
  local kernel_image=$c_components_dir/Image
  local bios_image=$c_components_dir/fw_dynamic.bin
  local disk_image=$1
  local image_format=${disk_image##*.}

  "$c_qemu_binary" \
    -daemonize \
    -display none \
    -pidfile "$c_qemu_pidfile" \
    -machine virt \
    -smp "$(nproc)",cores="$(nproc)",sockets=1,threads=1 \
    -accel tcg,thread=multi \
    -m "$c_fedora_run_memory" \
    -kernel "$kernel_image" \
    -bios "$bios_image" \
    -append "root=/dev/vda4 ro console=ttyS0" \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0 \
    -device virtio-blk-device,drive=hd0 \
    -drive file="$disk_image",format="$image_format",id=hd0 \
    -device virtio-net-device,netdev=usernet \
    -netdev user,id=usernet,hostfwd=tcp::"$c_local_ssh_port"-:22

  while ! nc -z localhost "$c_local_ssh_port"; do sleep 1; done

  run_fedora_command -o ConnectTimeout=30 exit

  # Something's odd going on here. One minute or two into the installation of the development packages,
  # the VM connection would drop, causing dnf to fail, and the port on the host to stay open, but without
  # the SSH service starting the handshake. This points either to the QEMU networking having some issue,
  # or to some internal Fedora service dropping the connection, although the latter seems unlikely,
  # as repeated connection to the port shouldn't prevent the problem it to happen.
  #
  set +x
  {
    while nc -z localhost "$c_local_ssh_port"; do
      curl localhost:"$c_local_ssh_port" 2> /dev/null || true
      sleep 1
    done
  } &
  set -x
}

# $@: ssh params
#
function run_fedora_command {
  sshpass -p 'fedora_rocks!' \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p "$c_local_ssh_port" riscv@localhost "$@"
}

function shutdown_fedora {
  # Watch out - halting via ssh causes an error, since the connection is truncated.
  #
  run_fedora_command "sudo halt" || true

  # Shutdown is asynchronous, so just wait for the pidfile to go.
  #
  while [[ -f $c_qemu_pidfile ]]; do
    sleep 0.5
  done
}

####################################################################################################
# EXECUTION
####################################################################################################

decode_cmdline_args "$@"
create_directories
init_debug_log
cache_sudo

install_base_packages
add_toolchain_binaries_to_path

download_projects

# This needs to be built in advance, due to the kernel configuration.
build_toolchain

prepare_toolchain
prepare_linux_kernel
prepare_busybear
prepare_qemu

build_linux_kernel
build_busybear
copy_opensbi_firmware
build_qemu

# This needs to be prepared late, due the QEMU binary dependency.
prepare_fedora

build_parsec
build_pigz

download_pigz_input_file
copy_data_to_guest_image

print_completion_message
