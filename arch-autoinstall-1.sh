#!/usr/bin/env bash
# =============================================================================
#  arch-autoinstall.sh  (bare-metal, UEFI, fully automated)
#  Run from the Arch Linux live ISO as root.
#
#  - Wipes + partitions the target disk (GPT: 1G EFI + ext4 root)
#  - Installs base system via archinstall (pacstrap fallback)
#  - root / 1234   and   ethan / 1234 (sudo, passwordless sudo)
#  - Installs git
#  - Reboots into the installed system
# =============================================================================
set -euo pipefail

# ----------------------------- settings --------------------------------------
USERNAME="ethan"
USER_PASS="1234"
ROOT_PASS="1234"
HOSTNAME="archlinux"
TIMEZONE="America/Indianapolis"
PKGS="base-devel git vim nano htop wget curl openssh networkmanager sudo efibootmgr"

MNT=/mnt/archinstall
# -----------------------------------------------------------------------------

log() { printf '\e[1;35m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m!!\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root from the Arch live ISO."

exec > >(tee -a /root/autoinstall.log > /dev/console) 2>&1
set -x

log "##### Arch auto-install starting #####"

# ---- pick target disk ----
DISK=$(lsblk -dpno NAME,TYPE,RO,RM \
       | awk '$2=="disk" && $3==0 && $4==0 && $1 !~ /loop|sr|zram/ {print $1; exit}')
[[ -b "$DISK" ]] || { log "No target disk found"; lsblk; exit 1; }
[[ "$DISK" =~ (nvme|mmcblk) ]] && P="${DISK}p" || P="$DISK"
log "Target disk: $DISK"

log "Starting in 10s — Ctrl+C to abort"
for i in 10 9 8 7 6 5 4 3 2 1; do printf '\r%2s...' "$i"; sleep 1; done; echo

# ---- network, keyring, clock ----
log "Waiting for network"
for i in $(seq 1 60); do ping -c1 -W2 archlinux.org &>/dev/null && break; sleep 5; done
for i in $(seq 1 100); do systemctl is-active --quiet pacman-init.service && break; sleep 3; done
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring archinstall || true

# ---- wipe + partition ----
log "Partitioning $DISK"
umount -R "$MNT" 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:1MiB:+1GiB -t1:EF00 -c1:EFI \
       -n2:0:0        -t2:8304 -c2:root "$DISK"
partprobe "$DISK"; udevadm settle; sleep 2

mkfs.fat -F32 -n EFI "${P}1"
mkfs.ext4 -F -L archroot "${P}2"

mount_target() {
  mountpoint -q "$MNT"      || { mkdir -p "$MNT"; mount "${P}2" "$MNT"; }
  mountpoint -q "$MNT/boot" || mount --mkdir "${P}1" "$MNT/boot"
}
mount_target

# ---- archinstall ----
log "Running archinstall"
HASH_ROOT=$(openssl passwd -6 "$ROOT_PASS")
HASH_USER=$(openssl passwd -6 "$USER_PASS")
PKG_JSON=$(printf '"%s",' $PKGS); PKG_JSON="[${PKG_JSON%,}]"

cat > /root/user_configuration.json <<JSON
{
  "archinstall-language": "English",
  "bootloader": "Grub",
  "bootloader_config": { "bootloader": "Grub", "uki": false, "removable": true },
  "disk_config": { "config_type": "pre_mounted_config", "mountpoint": "$MNT" },
  "hostname": "$HOSTNAME",
  "kernels": ["linux"],
  "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US" },
  "network_config": { "type": "nm" },
  "ntp": true,
  "packages": $PKG_JSON,
  "profile_config": null,
  "swap": true,
  "timezone": "$TIMEZONE",
  "silent": true
}
JSON

cat > /root/user_credentials.json <<JSON
{
  "root_enc_password": "$HASH_ROOT",
  "users": [ { "username": "$USERNAME", "enc_password": "$HASH_USER", "sudo": true, "groups": [] } ]
}
JSON

timeout 2400 archinstall \
  --config /root/user_configuration.json \
  --creds  /root/user_credentials.json \
  --silent < /dev/null || log "archinstall exited non-zero — checking result"

mount_target

# ---- pacstrap fallback ----
if [[ ! -f "$MNT/boot/vmlinuz-linux" || ! -x "$MNT/usr/bin/bash" ]]; then
  log "archinstall did not finish — falling back to pacstrap"
  pacstrap -K "$MNT" base linux linux-firmware grub $PKGS
  arch-chroot "$MNT" /bin/bash -c "
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
    echo LANG=en_US.UTF-8 > /etc/locale.conf
    echo KEYMAP=us > /etc/vconsole.conf
  "
fi

echo "$HOSTNAME" > "$MNT/etc/hostname"
grep -q '[[:space:]]/[[:space:]]' "$MNT/etc/fstab" 2>/dev/null \
  || genfstab -U "$MNT" >> "$MNT/etc/fstab"

# ---- users, services, bootloader ----
log "Configuring users and bootloader"
arch-chroot "$MNT" /bin/bash <<CHROOT
set -x
pacman -S --needed --noconfirm grub efibootmgr sudo networkmanager openssh git
id $USERNAME &>/dev/null || useradd -m -G wheel -s /bin/bash $USERNAME
usermod -aG wheel $USERNAME
echo "root:$ROOT_PASS"      | chpasswd
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/20-$USERNAME-nopasswd
chmod 440 /etc/sudoers.d/20-$USERNAME-nopasswd
systemctl enable NetworkManager sshd
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg
date > /etc/arch-autoinstalled
CHROOT

cp /root/autoinstall.log /root/*.json "$MNT/root/" 2>/dev/null || true
sync
umount -R "$MNT"

log "##### Install complete #####"
log "Login: $USERNAME / $USER_PASS   root / $ROOT_PASS"
sleep 3
systemctl reboot
