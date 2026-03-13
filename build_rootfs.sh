#!/bin/bash

#build the debian rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be either 'debian' or 'alpine'."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_deps "realpath debootstrap findmnt wget pcregrep tar"
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
packages="${args['custom_packages']-task-xfce-desktop}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
chroot_mounts="proc sys dev run"

mkdir -p $rootfs_dir

unmount_all() {
  for mountpoint in $chroot_mounts; do
    umount -l "$rootfs_dir/$mountpoint"
  done
}

need_remount() {
  local target="$1"
  local mnt_options="$(findmnt -T "$target" | tail -n1 | rev | cut -f1 -d' '| rev)"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint="$(findmnt -T "$target" | tail -n1 | cut -f1 -d' ')"
  mount -o remount,dev,exec "$mountpoint"
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then 
  print_info "bootstraping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else 
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcregrep -o1 '"(.+?.apk)"')"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstraping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then 
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "artix" ]; then
  assert_deps "zstd"

  init_system="${release_name:-openrc}"
  if [ "$init_system" != "openrc" ] && [ "$init_system" != "runit" ] && [ "$init_system" != "s6" ] && [ "$init_system" != "dinit" ]; then
    print_error "invalid init system '$init_system' for artix. valid values: openrc, runit, s6, dinit"
    exit 1
  fi
  if [ "$init_system" != "openrc" ]; then
    print_error "warning: only openrc has been tested with shimboot. other init systems may not work correctly."
    sleep 2
  fi

  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then
    real_arch="aarch64"
  fi

  bootstrap_mirror="https://mirror.artixlinux.org/bootstrap/"
  print_info "finding latest artix bootstrap tarball"
  bootstrap_file="$(wget -qO- "$bootstrap_mirror" | pcregrep -o1 '"(artix-bootstrap-[0-9]+-x86_64\.tar\.zst)"' | tail -n1)"

  if [ -z "$bootstrap_file" ]; then
    print_error "could not find an artix bootstrap tarball at $bootstrap_mirror"
    exit 1
  fi

  bootstrap_url="${bootstrap_mirror}${bootstrap_file}"
  bootstrap_extract_dir="/tmp/artix-bootstrap-$$"
  bootstrap_tarball="/tmp/artix-bootstrap-$$.tar.zst"

  rm -rf "$bootstrap_extract_dir"
  mkdir -p "$bootstrap_extract_dir"

  print_info "downloading artix bootstrap: $bootstrap_url"
  wget -q --show-progress "$bootstrap_url" -O "$bootstrap_tarball"

  print_info "extracting artix bootstrap"
  tar --zstd -xf "$bootstrap_tarball" -C "$bootstrap_extract_dir"
  rm -f "$bootstrap_tarball"

  bootstrap_root="$(find "$bootstrap_extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

  if [ -z "$bootstrap_root" ]; then
    print_error "failed to find extracted bootstrap directory"
    rm -rf "$bootstrap_extract_dir"
    exit 1
  fi

  print_info "preparing bootstrap environment"
  cp /etc/resolv.conf "$bootstrap_root/etc/resolv.conf"
  for mnt in proc sys dev; do
    mount --bind "/$mnt" "$bootstrap_root/$mnt"
  done
  mount --bind /dev/pts "$bootstrap_root/dev/pts"

  chroot "$bootstrap_root" pacman-key --init
  chroot "$bootstrap_root" pacman-key --populate artix

  if [ "$arch" = "arm64" ]; then
    print_info "configuring bootstrap for arm64 cross-installation"

    if grep -q "^Architecture" "$bootstrap_root/etc/pacman.conf"; then
      sed -i "s/^Architecture\s*=.*/Architecture = aarch64/" "$bootstrap_root/etc/pacman.conf"
    else
      sed -i "/\[options\]/a Architecture = aarch64" "$bootstrap_root/etc/pacman.conf"
    fi

    cat >> "$bootstrap_root/etc/pacman.conf" << 'PACMAN_REPOS'

[artixarm-system]
Server = https://mirror.artixlinux.org/artixarm/system/$arch/

[artixarm-world]
Server = https://mirror.artixlinux.org/artixarm/world/$arch/

[artixarm-galaxy]
Server = https://mirror.artixlinux.org/artixarm/galaxy/$arch/

[alarm]
Server = https://mirror.archlinuxarm.org/$arch/$repo
PACMAN_REPOS

    chroot "$bootstrap_root" pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 || true
    chroot "$bootstrap_root" pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6 || true
  fi

  mkdir -p "$bootstrap_root/mnt/target"
  mount --bind "$rootfs_dir" "$bootstrap_root/mnt/target"

  print_info "running pacstrap to install artix base system (this may take a while)"
  chroot "$bootstrap_root" pacstrap /mnt/target \
    base base-devel openrc elogind-openrc

  umount "$bootstrap_root/mnt/target"
  umount "$bootstrap_root/dev/pts"
  for mnt in dev sys proc; do
    umount "$bootstrap_root/$mnt"
  done
  rm -rf "$bootstrap_extract_dir"

  chroot_script="/opt/setup_rootfs_artix.sh"

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

print_info "copying rootfs setup scripts"
cp -arv rootfs/* "$rootfs_dir"
cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"

print_info "creating bind mounts for chroot"
trap unmount_all EXIT
for mountpoint in $chroot_mounts; do
  mount --make-rslave --rbind "/${mountpoint}" "${rootfs_dir}/$mountpoint"
done

hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch'" 

LC_ALL=C chroot $rootfs_dir /bin/sh -c "${chroot_command}"

trap - EXIT
unmount_all

print_info "rootfs has been created"