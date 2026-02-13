#!/bin/bash

#setup the artix linux rootfs
#this is meant to be run within the chroot created by build_rootfs.sh

DEBUG="$1"
set -e
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

if [ "$arch" = "amd64" ]; then
  real_arch="x86_64"
else
  real_arch="$arch"
fi

if [ ! "$hostname" ]; then
  read -p "Enter the hostname for the system: " hostname
fi
echo "$hostname" > /etc/hostname
cat > /etc/hosts <<END
127.0.0.1 localhost
127.0.1.1 ${hostname}

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
END

cat > /etc/pacman.d/mirrorlist <<END
Server = https://mirror1.artixlinux.org/\$repo/os/$real_arch
Server = https://mirror.pascalpuffke.de/artix-linux/\$repo/os/$real_arch
END

pacman-key --init || true
pacman-key --populate artix archlinux || pacman-key --populate artix
pacman -Syy --noconfirm

#add service to kill frecon
cat > /etc/init.d/kill-frecon <<'END'
#!/sbin/openrc-run

command='/usr/bin/pkill frecon-lite'
END
chmod +x /etc/init.d/kill-frecon

#install desktop environment or custom packages
if echo "$packages" | grep "task-" >/dev/null; then
  desktop="$(echo "$packages" | cut -d'-' -f2)"

  if [ "$desktop" = "xfce" ]; then
    pacman -S --needed --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  elif [ "$desktop" = "kde" ]; then
    pacman -S --needed --noconfirm plasma-meta sddm konsole dolphin
  elif [ "$desktop" = "gnome" ]; then
    pacman -S --needed --noconfirm gnome gdm
  elif [ "$desktop" = "lxde" ]; then
    pacman -S --needed --noconfirm lxde lightdm lightdm-gtk-greeter
  elif [ "$desktop" = "gnome-flashback" ]; then
    pacman -S --needed --noconfirm gnome-flashback gnome-session gdm
  elif [ "$desktop" = "cinnamon" ]; then
    pacman -S --needed --noconfirm cinnamon lightdm lightdm-gtk-greeter
  elif [ "$desktop" = "mate" ]; then
    pacman -S --needed --noconfirm mate mate-extra lightdm lightdm-gtk-greeter
  elif [ "$desktop" = "lxqt" ]; then
    pacman -S --needed --noconfirm lxqt sddm
  else
    echo "Unknown desktop '$desktop', defaulting to XFCE"
    pacman -S --needed --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  fi
else
  pacman -S --needed --noconfirm $packages
fi

if [ -z "$disable_base_pkgs" ]; then
  pacman -S --needed --noconfirm sudo networkmanager networkmanager-openrc wpa_supplicant dbus dbus-openrc elogind-openrc polkit cloud-utils nano
fi

#enable services
rc-update add bootmisc boot || true
rc-update add hostname boot || true
rc-update add modules boot || true
rc-update add networking boot || true
rc-update add dbus default || true
rc-update add NetworkManager default || true
rc-update add elogind default || true
rc-update add kill-frecon boot || true

if [ ! "$username" ]; then
  read -p "Enter the username for the user account: " username
fi
useradd -m -s /bin/bash "$username"

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    echo "$user:$password" | chpasswd
  fi
}

if [ "$enable_root" ]; then
  echo "Enter a root password:"
  set_password root "$root_passwd"
else
  passwd -l root || true
fi

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
usermod -aG wheel "$username"

echo "Enter a user password:"
set_password "$username" "$user_passwd"

#enable bash greeter
echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc"
