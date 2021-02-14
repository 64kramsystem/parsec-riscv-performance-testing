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
c_qemu_output_log_file=$(readlink -f "$(dirname "$0")")/qemu.out.log

c_toolchain_address=https://github.com/riscv/riscv-gnu-toolchain.git
c_linux_repo_address=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
c_fedora_image_address=https://dl.fedoraproject.org/pub/alt/risc-v/repo/virt-builder-images/images/Fedora-Minimal-Rawhide-20200108.n.0-sda.raw.xz
c_opensbi_tarball_address=https://github.com/riscv/opensbi/releases/download/v0.9/opensbi-0.9-rv-bin.tar.xz
c_busybear_repo_address=https://github.com/michaeljclark/busybear-linux.git
c_qemu_repo_address=https://github.com/saveriomiroddi/qemu-pinning.git
c_parsec_benchmark_address=https://github.com/saveriomiroddi/parsec-benchmark-tweaked.git
c_parsec_sim_inputs_address=https://parsec.cs.princeton.edu/download/3.0/parsec-3.0-input-sim.tar.gz
c_parsec_native_inputs_address=https://parsec.cs.princeton.edu/download/3.0/parsec-3.0-input-native.tar.gz
c_zlib_repo_address=https://github.com/madler/zlib.git
c_pigz_repo_address=https://github.com/madler/pigz.git
# Bash v5.1 (make) has a bug on parallel compilation (see https://gitweb.gentoo.org/repo/gentoo.git/commit/?id=4c2ebbf4b8bc660beb98cc2d845c73375d6e4f50).
# It can be patched, but it's not worth the hassle.
c_bash_tarball_address=https://ftp.gnu.org/gnu/bash/bash-5.0.tar.gz

# The file_path can be anything, as long as it ends with '.pigz_input', so that it's picked up by the
# benchmark script.
c_pigz_input_file_address=https://cdimage.debian.org/mirror/cdimage/archive/10.7.0-live/amd64/iso-hybrid/debian-live-10.7.0-amd64-mate.iso

# See note in prepare_fedora() about the iamge formats.
c_working_images_size=20G
c_busybear_raw_image_path=$c_projects_dir/busybear-linux/busybear.bin
c_busybear_prepared_image_path=$c_components_dir/busybear.qcow2
c_fedora_run_memory=8G
c_local_ssh_port=10000
c_local_fedora_raw_image_path=$c_projects_dir/$(echo "$c_fedora_image_address" | perl -ne 'print /([^\/]+)\.xz$/')
c_local_fedora_prepared_image_path="${c_local_fedora_raw_image_path/.raw/.prepared.qcow2}"
c_fedora_temp_build_image_path=$(dirname "$(mktemp)")/fedora.temp.build.qcow2
c_local_parsec_inputs_path=$c_projects_dir/parsec-inputs
c_local_parsec_benchmark_path=$c_projects_dir/parsec-benchmark
c_qemu_binary=$c_projects_dir/qemu-pinning/bin/debug/native/qemu-system-riscv64
c_qemu_pidfile=${XDG_RUNTIME_DIR:-/tmp}/$(basename "$0").qemu.pid
c_bash_binary=$c_projects_dir/$(echo "$c_bash_tarball_address" | perl -ne 'print /([^\/]+)\.tar.\w+$/')/bash
c_local_mount_dir=/mnt

c_compiler_binary=$c_projects_dir/riscv-gnu-toolchain/build/bin/riscv64-unknown-linux-gnu-gcc
c_riscv_firmware_file=share/opensbi/lp64/generic/firmware/fw_dynamic.bin # relative
c_pigz_input_file=$c_components_dir/$(basename "$c_pigz_input_file_address").pigz_input
c_pigz_binary_file=$c_projects_dir/pigz/pigz

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

function register_exit_hook {
  function _exit_hook {
    pkill -f "$(basename "$c_qemu_binary")" || true
    rm -f "$c_qemu_pidfile"

    rm -f "$c_fedora_temp_build_image_path"

    # On exit, we don't care about async; see umount_image().
    #
    if sudo mountpoint -q "$c_local_mount_dir"; then
      sudo guestunmount -q "$c_local_mount_dir"
    fi
  }

  trap _exit_hook EXIT
}

function add_toolchain_binaries_to_path {
  export PATH="$c_projects_dir/riscv-gnu-toolchain/build/bin:$PATH"
}

function install_base_packages {
  print_header "Installing required packages..."

  sudo apt update
  sudo apt install -y git build-essential flex sshpass pigz gnuplot libguestfs-tools
}

function download_projects {
  print_header "Downloading projects..."

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
    local project_basename

    if [[ $project_address == *"parsec-benchmark-tweaked"* ]]; then
      project_basename=$(basename "$c_local_parsec_benchmark_path")
    else
      project_basename=$(echo "$project_address" | perl -ne 'print /([^\/]+)\.git$/')
    fi

    if [[ $project_basename == "busybear-linux" || $project_basename == "riscv-gnu-toolchain" ]]; then
      local recursive_option=(--recursive)
    else
      local recursive_option=()
    fi

    if [[ -d $project_basename ]]; then
      echo "\`$project_basename\` project found; not cloning..."
    else
      git clone "${recursive_option[@]}" "$project_address" "$project_basename"
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

  if [[ -d $c_local_parsec_inputs_path ]]; then
    echo "Parsec inputs project found; not downloading..."
  else
    wget --output-document=/dev/stdout "$c_parsec_sim_inputs_address" |
      tar xz --directory="$c_projects_dir" --transform="s/^parsec-3.0/$(basename "$c_local_parsec_inputs_path")/"

    wget --output-document=/dev/stdout "$c_parsec_native_inputs_address" |
      tar xz --directory="$c_projects_dir" --transform="s/^parsec-3.0/$(basename "$c_local_parsec_inputs_path")/"
  fi

  if [[ -d $(dirname "$c_bash_binary") ]]; then
    echo "Bash project found; not downloading..."
  else
    wget --output-document=/dev/stdout "$c_bash_tarball_address" | tar xz --directory="$c_projects_dir"
  fi

  # Pigz input

  if [[ -f $c_pigz_input_file ]]; then
    echo "Pigz input file found; not downloading..."
  else
    wget "$c_pigz_input_file_address" -O "$c_pigz_input_file"
  fi
}

# In theory, the Ubuntu-provided toolchain could be used, but it lacks some libraries (e.g. libcrypt),
# which make the setup complicated.
#
function build_toolchain {
  sudo apt install -y autoconf automake autotools-dev curl python3 libmpc-dev libmpfr-dev libgmp-dev gawk \
           bison flex texinfo gperf libtool patchutils bc zlib1g-dev libexpat1-dev

  cd "$c_projects_dir/riscv-gnu-toolchain"

  ./configure --prefix="$PWD/build"
  make -j "$(nproc)" linux
}

# This step is required by Busybear; see https://github.com/michaeljclark/busybear-linux/issues/10.
#
function adjust_toolchain {
  print_header "Preparing the toolchain..."

  cd "$c_projects_dir/riscv-gnu-toolchain/build/sysroot/usr/include/gnu"

  if [[ ! -e stubs-lp64.h ]]; then
    ln -s stubs-lp64d.h stubs-lp64.h
  fi
}

function prepare_linux_kernel {
  print_header "Preparing the Linux kernel..."

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

  make CC="$c_compiler_binary" ARCH=riscv CROSS_COMPILE="$(basename "${c_compiler_binary%gcc}")" defconfig

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
  print_header "Preparing BusyBear..."

  cd "$c_projects_dir/busybear-linux"

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
  print_header "Preparing QEMU..."

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
    print_header "Compiled Linux kernel found; not compiling/copying..."
  else
    print_header "Compiling Linux kernel..."

    make ARCH=riscv CROSS_COMPILE="$(basename "${c_compiler_binary%gcc}")" -j "$(nproc)"

    cp "$linux_kernel_file" "$c_components_dir"/
  fi
}

function build_busybear {
  cd "$c_projects_dir/busybear-linux"

  if [[ -f $c_busybear_raw_image_path ]]; then
    print_header "Busybear image found; not building..."
  else
    print_header "Building BusyBear..."
    echo 'WATCH OUT!! Busybear may fail without useful messages. If this happens, add `set -x` on top of its `build.sh` script.'

    make
  fi
}

# Using the Ubuntu-provided QEMU for preparing Fedora would make the script cleaner, but it hangs on
# boot (20.04 ships QEMU 4.2).
#
function build_qemu {
  cd "$c_projects_dir/qemu-pinning"

  if [[ -f $c_qemu_binary ]]; then
    print_header "QEMU binary found; not compiling/copying..."
  else
    print_header "Building QEMU..."

    ./build_pinning_qemu_binary.sh --target=riscv64 --yes

    cp "$c_qemu_binary" "$c_components_dir"/
  fi
}

function build_bash {
  cd "$(dirname "$c_bash_binary")"

  if [[ -f $c_bash_binary ]]; then
    print_header "Bash binary found; not compiling..."
  else
    print_header "Building Bash..."

    # See http://www.linuxfromscratch.org/lfs/view/development/chapter06/bash.html.
    #
    # $LFS_TGT is blank, so it's not set, and we're not performing the install, either.
    #
    ./configure --host="$(support/config.guess)" CC="$(basename "$c_compiler_binary")" --enable-static-link --without-bash-malloc

    make -j "$(nproc)"
  fi
}

# Depends on QEMU.
#
# Using raw as image format [for the prepare image] caused a nutty issue on slow disks (e.g. running
# in a VM or on a flash key); on Fedora's boot, some services would take a very long time (more than
# a few minutes), causing on the host a very large amount of kworker(flush) activity. Placing the image
# on a fast disk or on /run/user/$ID (which is a tmpfs, therefore, partially in memory), or using a
# qcow2 diff image, doesn't manifest the problem.
# It's not clear what this is, as the difference in speed doesn't justify the two orders of magnitude
# of difference, but it's certainly due to some frantic write activity.
#
function prepare_fedora {
  # Chunky procedure, so don't redo it if the file exists.
  #
  if [[ -f $c_local_fedora_prepared_image_path ]]; then
    print_header "Prepared fedora image found; not processing..."
  else
    print_header "Preparing Fedora..."

    ####################################
    # Create extend image
    ####################################

    # Using a backing image and setting the size is allowed by qemu-img, and there's no mention in the
    # manpage against doing so. But it causes crashes on the guest :rolling_eyes:.
    #
    # qemu-img create -f qcow2 -b "$c_local_fedora_raw_image_path" "$c_local_fedora_prepared_image_path" "$c_working_images_size"

    qemu-img create -f qcow2 "$c_local_fedora_prepared_image_path" "$c_working_images_size"
    sudo virt-resize -v -x --expand /dev/sda4 "$c_local_fedora_raw_image_path" "$c_local_fedora_prepared_image_path"

    ######################################
    # Set passwordless sudo
    ######################################

    mount_image "$c_local_fedora_prepared_image_path" 4

    # Sud-bye!
    sudo sed -i '/%wheel.*NOPASSWD: ALL/ s/^# //' "$c_local_mount_dir/etc/sudoers"

    umount_image "$c_local_fedora_prepared_image_path"

    ####################################
    # Start Fedora
    ####################################

    start_fedora "$c_local_fedora_prepared_image_path"

    ####################################
    # Disable long-running service
    ####################################

    run_fedora_command 'sudo systemctl mask man-db-cache-update'

    ####################################
    # Install packages and copy PARSEC
    ####################################

    run_fedora_command 'sudo dnf groupinstall -y "Development Tools" "Development Libraries"'
    run_fedora_command 'sudo dnf install -y tar gcc-c++ texinfo parallel rsync'
    # If vips finds liblzma in the system libraries, it will link dynamically, making it troublesome
    # to run on other systems. It's possible to compile statically (see https://lists.cs.princeton.edu/pipermail/parsec-users/2008-April/000081.html),
    # but this solution is simpler.
    run_fedora_command 'sudo dnf remove -y xz-devel'
    # To replace with xargs once the script is releasable.
    run_fedora_command 'echo "will cite" | parallel --citation || true'
    # Conveniences
    run_fedora_command 'sudo dnf install -y vim pv zstd the_silver_searcher rsync htop'

    shutdown_fedora

    # This (and other occurrences) could trivially be copied via SSH, but QEMU hangs if so (see note
    # in start_fedora()).
    #
    mount_image "$c_local_fedora_prepared_image_path" 4
    sudo rsync -av --info=progress2 --no-inc-recursive --exclude=.git "$c_local_parsec_benchmark_path" "$c_local_mount_dir"/home/riscv/ | grep '/$'
    umount_image "$c_local_fedora_prepared_image_path"
  fi
}

function copy_opensbi_firmware {
  print_header "Copying OpenSBI firmware..."

  cd "$c_projects_dir"/opensbi-*-rv-bin/

  cp "$c_riscv_firmware_file" "$c_components_dir"/
}

function build_pigz {
  if [[ -f $c_pigz_binary_file ]]; then
    print_header "pigz binary found; not compiling/copying..."
  else
    print_header "Building pigz..."

    cd "$c_projects_dir/zlib"

    # For the zlib project included in the RISC-V toolchain, append `--host=x86_64`.
    #
    CC="$c_compiler_binary" ./configure
    make -j "$(nproc)"

    cd "$c_projects_dir/pigz"

    make "LDFLAGS=-static" "CC=$c_compiler_binary -I $c_projects_dir/zlib -L $c_projects_dir/zlib" -j "$(nproc)"
  fi
}

function build_parsec {
  # double check the name
  #
  local sample_built_package=$c_projects_dir/parsec-benchmark/pkgs/apps/blackscholes/inst/riscv64-linux.gcc/bin/blackscholes

  if [[ -f $sample_built_package ]]; then
    print_header "Sample PARSEC package found ($(basename "$sample_built_package")); not building..."
  else
    # Technically, we could leave the QEMU hanging around and copy directly from the VM to the BusyBear
    # image in the appropriate stage, but better to separate stages very clearly.
    #
    print_header "Building PARSEC suite in the Fedora VM, and copying it back..."

    qemu-img create -f qcow2 -b "$c_local_fedora_prepared_image_path" "$c_fedora_temp_build_image_path"

    start_fedora "$c_fedora_temp_build_image_path"

    # Build packages without dependencies first. Once, an error occurred while building libxml2 in parallel
    # with gsl and others, so for safety, gsl and libxml2 are built serially.
    #
    run_fedora_command "
      cd parsec-benchmark &&
      parallel bin/parsecmgmt -a build -p ::: zlib parmacs libjpeg &&
      bin/parsecmgmt -a build -p libxml2 &&
      bin/parsecmgmt -a build -p gsl
    "

    # vips is by far the slowest, so we start compiling it first.
    #
    # Packages excluded:
    #
    # - canneal (ASM)
    # - raytrace (ASM)
    # - x264 (ASM)
    # - facesim (segfaults; has ASM but it's not compiled)
    #
    local parsec_packages=(
      parsec.vips
      parsec.blackscholes
      parsec.bodytrack
      parsec.dedup
      parsec.ferret
      parsec.fluidanimate
      parsec.freqmine
      parsec.streamcluster
      parsec.swaptions
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

    shutdown_fedora

    mount_image "$c_fedora_temp_build_image_path" 4

    # Will include also other directories matching 'bin', but they won't be re-synced.
    # We can't just `sudo rsync **/bin`, because the glob is expanded before sudo, and it won't find
    # anything, due to permissions.
    #
    sudo bash -c "
      shopt -s globstar
      cd $c_local_mount_dir/home/riscv/parsec-benchmark
      rsync -av --info=progress2 --no-inc-recursive --relative ./ext/**/bin ./pkgs/**/bin "$c_local_parsec_benchmark_path"
    "

    umount_image "$c_fedora_temp_build_image_path"
  fi
}

# For simplicity, just run it without checking if the files already exist.
#
# Note that libs are better copied rather than rsync'd, since they are often symlinks.
#
function prepare_final_image {
  print_header "Preparing final image..."

  if [[ ! -f $c_busybear_prepared_image_path ]]; then
    # Only need to set the size, without resizing the partition, as the image is not partitioned.
    #
    qemu-img convert -p -O qcow2 "$c_busybear_raw_image_path" "$c_busybear_prepared_image_path"
    qemu-img resize "$c_busybear_prepared_image_path" "$c_working_images_size"
  fi

  mount_image "$c_busybear_prepared_image_path"

  # Pigz(-related)
  #
  sudo rsync -av                     "$c_pigz_binary_file" "$c_local_mount_dir"/root/
  sudo rsync -av --append --progress "$c_pigz_input_file"  "$c_local_mount_dir"/root/

  # PARSEC + Inputs
  #
  sudo rsync -av --exclude={.git,src,obj} \
    "$c_local_parsec_benchmark_path" "$c_local_mount_dir"/root/ |
    grep '/$'

  sudo rsync -av --append \
    "$c_local_parsec_inputs_path"/ "$c_local_mount_dir"/root/parsec-benchmark/ |
    grep '/$'

  # Bash (also set as default shell)

  sudo cp "$c_bash_binary" "$c_local_mount_dir"/bin/
  sudo ln -sf bash "$c_local_mount_dir"/bin/sh

  # Done!

  umount_image "$c_busybear_prepared_image_path"
}

function print_completion_message {
  print_header "Preparation completed!"
}

####################################################################################################
# HELPERS
####################################################################################################

# $1: message
#
function print_header {
  echo '####################################################################################################'
  echo "# $1"
  echo '####################################################################################################'
}

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
    -serial file:"$c_qemu_output_log_file" \
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

  # The default timeout (the system one) is long. 90 seconds should be more than enough also for relatively
  # slow hosts, but longer timeouts implies that the host is too slow, or that there is a problem.
  #
  run_fedora_command -o ConnectTimeout=90 exit

  # Something's odd going on here. One minute or two into the installation of the development packages,
  # the VM connection drops, causing dnf to fail, while the port on the host stays open, but without
  # the SSH service starting the handshake. The guest prints kernel errors which explicitly mention
  # a bug, so there must be one across the stack.
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

# $1: image, $2 (optional): partition number
#
function mount_image {
  local image=$1
  local block_device=/dev/sda${2:-}

  sudo guestmount -a "$image" -m "$block_device" "$c_local_mount_dir"
}

function umount_image {
  local image=$1

  if sudo mountpoint -q "$c_local_mount_dir"; then
    # The libguestfs stack is functionally poor.
    # Unmounting (also via umount), causes an odd `fuse: mountpoint is not empty` error; the guestunmount
    # help seems to acknowledge this (ie. retries option), so we don't display errors.
    # Additionally, on unmount, the sync is tentative, so need to manually check that the file is closed.
    #
    sudo guestunmount -q "$c_local_mount_dir"

    # Just ignore the gvfs warning.
    while [[ -n $(sudo lsof -e "$XDG_RUNTIME_DIR/gvfs" "$1" 2> /dev/null) ]]; do
      sleep 0.5
    done
  fi
}

####################################################################################################
# EXECUTION
####################################################################################################

decode_cmdline_args "$@"
create_directories
init_debug_log
cache_sudo
register_exit_hook

install_base_packages
add_toolchain_binaries_to_path

download_projects

build_toolchain
adjust_toolchain

prepare_linux_kernel
build_linux_kernel

prepare_busybear
build_busybear

build_bash

copy_opensbi_firmware

prepare_qemu
build_qemu

prepare_fedora

build_parsec
build_pigz

prepare_final_image

print_completion_message
