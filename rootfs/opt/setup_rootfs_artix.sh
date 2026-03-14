#!/bin/bash

#setup the artix linux rootfs
#this is meant to be run within the chroot created by build_rootfs.sh

set -e

DEBUG="$1"
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2"
packages="$3"
hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"

init_system="${release_name:-openrc}"

log() { echo "==> $*"; }

resolve_desktop_packages() {
  local task="$1"
  local de

  if echo "$task" | grep -q "^task-"; then
    de="$(echo "$task" | sed 's/^task-//; s/-desktop$//')"
  else
    DESKTOP_PACKAGES="$task"
    DISPLAY_MANAGER="lightdm"
    DM_SERVICE="lightdm"
    return
  fi

  case "$de" in
    xfce)
      DESKTOP_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
    kde)
      DESKTOP_PACKAGES="plasma plasma-wayland-session kde-applications sddm"
      DISPLAY_MANAGER="sddm"
      DM_SERVICE="sddm"
      ;;
    gnome)
      DESKTOP_PACKAGES="gnome gnome-extra gdm"
      DISPLAY_MANAGER="gdm"
      DM_SERVICE="gdm"
      ;;
    lxde)
      DESKTOP_PACKAGES="lxde lxde-common lxsession openbox lightdm lightdm-gtk-greeter"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
    lxqt)
      DESKTOP_PACKAGES="lxqt breeze-icons sddm"
      DISPLAY_MANAGER="sddm"
      DM_SERVICE="sddm"
      ;;
    mate)
      DESKTOP_PACKAGES="mate mate-extra lightdm lightdm-gtk-greeter"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
    cinnamon)
      DESKTOP_PACKAGES="cinnamon lightdm lightdm-gtk-greeter"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
    gnome-flashback)
      DESKTOP_PACKAGES="gnome-flashback gnome-panel lightdm lightdm-gtk-greeter"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
    *)
      log "warning: unknown desktop '$de', passing through as raw package list"
      DESKTOP_PACKAGES="$task"
      DISPLAY_MANAGER="lightdm"
      DM_SERVICE="lightdm"
      ;;
  esac
}

#add universe repo for openrc-wrapped packages
if ! grep -q "\[universe\]" /etc/pacman.conf; then
  cat >> /etc/pacman.conf << 'EOF'

[universe]
Server = https://universe.artixlinux.org/$arch
EOF
fi

pacman -Sy --noconfirm

resolve_desktop_packages "$packages"

DM_OPENRC_PKG="${DISPLAY_MANAGER}-openrc"

#install desktop environment
pacman -S --noconfirm --needed $DESKTOP_PACKAGES $DM_OPENRC_PKG

#install base packages
if [ -z "$disable_base_pkgs" ]; then
  pacman -S --noconfirm --needed \
    networkmanager networkmanager-openrc \
    wpa_supplicant wpa_supplicant-openrc \
    dbus dbus-openrc \
    elogind elogind-openrc \
    polkit \
    sudo \
    bash-completion \
    nano \
    curl wget \
    fuse3 fuse2 \
    cronie cronie-openrc \
    syslog-ng syslog-ng-openrc \
    cloud-utils \
    kmod \
    iwd

  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/wifi-backend.conf << 'NMEOF'
[device]
wifi.backend=iwd
NMEOF

  cat > /etc/NetworkManager/conf.d/any-user.conf << 'NMEOF'
[main]
auth-polkit=false
NMEOF

  #set up zram
  cat > /etc/init.d/zram-swap << 'ORCEOF'
#!/sbin/openrc-run

description="Set up zram-based compressed swap"

depend() {
  need localmount
  before swap
}

start() {
  ebegin "Starting zram swap"
  local mem_kb
  mem_kb=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
  local zram_size_kb=$(( mem_kb / 2 ))

  modprobe zram || { ewarn "failed to load zram module"; eend 1; return; }
  echo lzo > /sys/block/zram0/comp_algorithm
  echo "${zram_size_kb}K" > /sys/block/zram0/disksize
  mkswap /dev/zram0 >/dev/null
  swapon -p 10 /dev/zram0
  eend $?
}

stop() {
  ebegin "Stopping zram swap"
  swapoff /dev/zram0 2>/dev/null || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true
  rmmod zram 2>/dev/null || true
  eend 0
}
ORCEOF
  chmod +x /etc/init.d/zram-swap
fi

#add service to kill frecon
cat > /etc/init.d/kill-frecon << 'ORCEOF'
#!/sbin/openrc-run

description="Kill frecon-lite so the display manager can take the VT"

depend() {
  need devfs
  before xdm lightdm sddm gdm display-manager
}

start() {
  ebegin "Killing frecon-lite"
  pkill frecon-lite 2>/dev/null || true
  eend 0
}
ORCEOF
chmod +x /etc/init.d/kill-frecon

#openrc doesnt work with /etc/modules-load.d so we need to copy those to /etc/modules
if [ -d /etc/modules-load.d ]; then
  for mod_file in /etc/modules-load.d/*.conf; do
    [ -f "$mod_file" ] || continue
    cat "$mod_file" >> /etc/modules
    echo >> /etc/modules
  done
fi

#enable services
for svc in devfs dmesg udev hwdrivers; do
  rc-update add "$svc" sysinit 2>/dev/null || true
done

for svc in hostname modules bootmisc hwclock syslog-ng seedrng; do
  rc-update add "$svc" boot 2>/dev/null || true
done

for svc in dbus elogind networkmanager cronie; do
  rc-update add "$svc" default 2>/dev/null || true
done
rc-update add kill-frecon default
rc-update add "$DM_SERVICE" default

if [ -z "$disable_base_pkgs" ]; then
  rc-update add zram-swap default
fi

for svc in mount-ro killprocs savecache; do
  rc-update add "$svc" shutdown 2>/dev/null || true
done

#set up hostname
if [ -z "$hostname" ]; then
  read -p "Enter the hostname for the system: " hostname
fi

echo "$hostname" > /etc/hostname
cat > /etc/hosts << HOSTSEOF
127.0.0.1  localhost
127.0.1.1  ${hostname}

::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
HOSTSEOF

mkdir -p /etc/conf.d
echo "hostname=\"${hostname}\"" > /etc/conf.d/hostname

#set up username
if [ -z "$username" ]; then
  read -p "Enter the username for the user account: " username
fi

userdel -r armtix 2>/dev/null || true
useradd -m -s /bin/bash "$username"

for grp in wheel video audio input plugdev netdev; do
  groupadd -f "$grp"
  usermod -aG "$grp" "$username"
done

echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

set_password() {
  local user="$1"
  local password="$2"
  if [ -z "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    echo "${user}:${password}" | chpasswd
  fi
}

if [ -n "$enable_root" ]; then
  set_password root "$root_passwd"
else
  passwd -l root
fi

set_password "$username" "$user_passwd"

#set up locales
if pacman -Q glibc &>/dev/null; then
  if [ -f /etc/locale.gen ]; then
    sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
    locale-gen 2>/dev/null || true
  fi
  echo "LANG=en_US.UTF-8" > /etc/locale.conf
fi

#enable bash greeter
if [ -f /usr/local/bin/shimboot_greeter ]; then
  echo "/usr/local/bin/shimboot_greeter" >> "/home/${username}/.bashrc"
fi

#clean pacman cache
pacman -Sc --noconfirm
