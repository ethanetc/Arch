#!/usr/bin/env bash
# =============================================================================
#  arch-autoinstall.sh  —  bare-metal, UEFI, fully automated
#  Boot the Arch Linux live ISO, then run:  bash arch-autoinstall.sh
#
#  What it does:
#    1. Auto-detects your disk (sda / nvme0n1 / etc.)
#    2. Wipes it, creates GPT: 1 GB EFI  +  rest ext4 root
#    3. pacstrap base system + git and essentials
#    4. Configures locale, timezone, hostname, bootloader (GRUB UEFI)
#    5. Creates user ethan (passwordless sudo) and sets passwords
#    6. Enables NetworkManager + sshd
#    7. Reboots into the installed system
# =============================================================================
set -euo pipefail

# ─────────────────────────── settings ────────────────────────────────────────
USERNAME="ethan"
USER_PASS="1234"
ROOT_PASS="1234"
HOSTNAME="archlinux"
TIMEZONE="America/Indianapolis"
LOCALE="en_US.UTF-8"
KEYMAP="us"

BASE_PKGS=(
  base base-devel linux linux-firmware
  grub efibootmgr
  networkmanager openssh
  sudo git vim nano htop wget curl
)

MNT=/mnt/arch
# ─────────────────────────────────────────────────────────────────────────────

log() { printf '\n\e[1;35m==> %s\e[0m\n' "$*"; }
die() { printf '\n\e[1;31m!! %s\e[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root."

# ── log everything to file and console ───────────────────────────────────────
exec > >(tee /root/autoinstall.log) 2>&1

# ── pick target disk ─────────────────────────────────────────────────────────
log "Detecting disk"
DISK=$(lsblk -dpno NAME,TYPE,RO,RM \
  | awk '$2=="disk" && $3=="0" && $4=="0" && $1 !~ /loop|sr|zram/ {print $1; exit}')
[[ -b "$DISK" ]] || die "No suitable disk found — check: lsblk"
log "Target disk: $DISK"
lsblk "$DISK"

# ── 10 s abort window ────────────────────────────────────────────────────────
echo ""
printf '\e[1;31mWARNING: %s will be completely wiped.\e[0m\n' "$DISK"
for i in 10 9 8 7 6 5 4 3 2 1; do
  printf '\rStarting in %d s — Ctrl+C to abort ... ' "$i"; sleep 1
done
echo ""

# ── sync clock ───────────────────────────────────────────────────────────────
log "Syncing clock"
timedatectl set-ntp true

# ── wait for pacman-init (keyring) ───────────────────────────────────────────
log "Waiting for pacman keyring init"
for i in $(seq 1 60); do
  systemctl is-active --quiet pacman-init.service && break
  sleep 3
done

# ── update package databases ─────────────────────────────────────────────────
log "Updating package databases"
pacman -Sy --noconfirm

# ── unmount anything on this disk ────────────────────────────────────────────
log "Unmounting $DISK"
umount -R "$MNT" 2>/dev/null || true
# unmount any partition on this disk that might be mounted elsewhere
for part in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
  umount -R "$part" 2>/dev/null || true
done
swapoff -a 2>/dev/null || true

# ── wipe + partition ─────────────────────────────────────────────────────────
log "Wiping $DISK"
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

log "Partitioning $DISK (GPT: 1G EFI + rest ext4)"
sgdisk \
  -n1:1MiB:+1GiB  -t1:EF00 -c1:EFI \
  -n2:0:0          -t2:8300 -c2:root \
  "$DISK"

# ── force kernel to re-read the new partition table ──────────────────────────
log "Re-reading partition table"
# Try multiple methods — one of them will succeed on real hardware
partprobe "$DISK"      2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true
udevadm settle
sleep 5   # give the kernel a moment to create the new block devices

# Confirm the partitions actually exist before formatting
[[ "$DISK" =~ (nvme|mmcblk) ]] && P="${DISK}p" || P="$DISK"
[[ -b "${P}1" ]] || die "Partition ${P}1 did not appear — reboot the live ISO and retry"
[[ -b "${P}2" ]] || die "Partition ${P}2 did not appear — reboot the live ISO and retry"

# ── format ───────────────────────────────────────────────────────────────────
log "Formatting EFI  ${P}1"
mkfs.fat -F32 -n EFI "${P}1"

log "Formatting root ${P}2"
mkfs.ext4 -F -L archroot "${P}2"

# ── mount ────────────────────────────────────────────────────────────────────
log "Mounting"
mkdir -p "$MNT"
mount "${P}2" "$MNT"
mkdir -p "$MNT/boot"
mount "${P}1" "$MNT/boot"

# ── install base system ──────────────────────────────────────────────────────
log "Running pacstrap (this takes a few minutes)"
pacstrap -K "$MNT" "${BASE_PKGS[@]}"

# ── fstab ────────────────────────────────────────────────────────────────────
log "Generating fstab"
genfstab -U "$MNT" > "$MNT/etc/fstab"
cat "$MNT/etc/fstab"

# ── chroot configuration ─────────────────────────────────────────────────────
log "Configuring installed system"
arch-chroot "$MNT" /bin/bash <<CHROOT
set -euo pipefail

# timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# locale
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# users
useradd -m -G wheel -s /bin/bash ${USERNAME} 2>/dev/null || true
echo "root:${ROOT_PASS}"       | chpasswd
echo "${USERNAME}:${USER_PASS}" | chpasswd

# sudo
echo '%wheel ALL=(ALL:ALL) ALL'                    > /etc/sudoers.d/10-wheel
echo '${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL'     > /etc/sudoers.d/20-${USERNAME}-nopasswd
chmod 440 /etc/sudoers.d/10-wheel /etc/sudoers.d/20-${USERNAME}-nopasswd

# services
systemctl enable NetworkManager
systemctl enable sshd

# GRUB (UEFI)
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot \
  --bootloader-id=GRUB \
  --recheck
# also install to removable path so the BIOS can always find it
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot \
  --bootloader-id=GRUB \
  --removable \
  --recheck || true
grub-mkconfig -o /boot/grub/grub.cfg

echo "chroot config done — $(date)" > /etc/arch-autoinstalled
CHROOT

# ── copy install log into new system ─────────────────────────────────────────
cp /root/autoinstall.log "$MNT/root/autoinstall.log" 2>/dev/null || true

# ── unmount and reboot ───────────────────────────────────────────────────────
log "Unmounting"
sync
umount -R "$MNT"

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Install complete!"
log "  root   password: ${ROOT_PASS}"
log "  ${USERNAME} password: ${USER_PASS}"
log "  Remove the USB/ISO before the system reboots."
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 5
systemctl reboot
