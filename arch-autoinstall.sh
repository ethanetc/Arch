#!/usr/bin/env bash
# =============================================================================
#  arch-autoinstall.sh   (bare-metal, UEFI)
#  Run from the Arch Linux live ISO as root.
#
#  1. Wipes + partitions the target disk (GPT: 1G EFI + ext4 root)
#  2. archinstall (falls back to pacstrap automatically)
#  3. root / 1234   and   ethan / 1234 (sudo, passwordless sudo)
#  4. Autologin on tty1
#  5. First boot: clones github.com/ethanetc/dotfiles, runs dots.sh,
#     reboots straight into i3
# =============================================================================
set -euo pipefail

# ----------------------------- settings --------------------------------------
USERNAME="ethan"
USER_PASS="1234"
ROOT_PASS="1234"
GUEST_HOSTNAME="archlinux"
TIMEZONE="America/Indianapolis"
EXTRA_PKGS="base-devel git vim nano htop wget curl openssh networkmanager sudo efibootmgr"

MNT=/mnt/archinstall
# -----------------------------------------------------------------------------

log() { printf '\e[1;35m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m!!\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (you are in the Arch live ISO)."

exec > >(tee -a /root/autoinstall.log > /dev/console) 2>&1
set -x

log "##### Arch auto-install starting #####"

# ---- pick the target disk (first real, writable, non-removable disk) ----
DISK=$(lsblk -dpno NAME,TYPE,RO,RM \
       | awk '$2=="disk" && $3==0 && $4==0 && $1 !~ /loop|sr|zram/ {print $1; exit}')
[[ -b "$DISK" ]] || { log "!!! No target disk found"; lsblk; exit 1; }
if [[ "$DISK" =~ (nvme|mmcblk) ]]; then P="${DISK}p"; else P="$DISK"; fi
log "Target disk: $DISK"

echo
printf '\e[1;31mWARNING:\e[0m This will WIPE %s entirely.\n' "$DISK"
for i in 10 9 8 7 6 5 4 3 2 1; do
  printf '\rStarting in %2s s (Ctrl+C to abort)...' "$i"; sleep 1
done
echo; echo

# ---- wait for network, keyring, clock ----
log "Waiting for network…"
for i in $(seq 1 60); do ping -c1 -W2 archlinux.org &>/dev/null && break; sleep 5; done
log "Waiting for pacman-init…"
for i in $(seq 1 100); do systemctl is-active --quiet pacman-init.service && break; sleep 3; done
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring archinstall || true

# ---- partition + format (UEFI: 1G ESP + ext4 root) ----
log "Partitioning $DISK"
umount -R "$MNT" 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:1MiB:+1GiB -t1:EF00 -c1:EFI \
       -n2:0:0        -t2:8304 -c2:root "$DISK"
partprobe "$DISK"; udevadm settle; sleep 2

log "Formatting partitions"
mkfs.fat -F32 -n EFI "${P}1"
mkfs.ext4 -F -L archroot "${P}2"

mount_target() {
  mountpoint -q "$MNT"      || { mkdir -p "$MNT"; mount "${P}2" "$MNT"; }
  mountpoint -q "$MNT/boot" || mount --mkdir "${P}1" "$MNT/boot"
}
mount_target

# ---- archinstall config ----
log "Building archinstall config"
HASH_ROOT=$(openssl passwd -6 "$ROOT_PASS")
HASH_USER=$(openssl passwd -6 "$USER_PASS")
PKG_JSON=$(printf '"%s",' $EXTRA_PKGS); PKG_JSON="[${PKG_JSON%,}]"

cat > /root/user_configuration.json <<JSON
{
  "archinstall-language": "English",
  "bootloader": "Grub",
  "bootloader_config": { "bootloader": "Grub", "uki": false, "removable": true },
  "disk_config": { "config_type": "pre_mounted_config", "mountpoint": "$MNT" },
  "hostname": "$GUEST_HOSTNAME",
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

log "Running archinstall"
timeout 2400 archinstall \
  --config /root/user_configuration.json \
  --creds  /root/user_credentials.json \
  --silent < /dev/null || log "archinstall exited non-zero — checking result"

# archinstall may unmount on exit — remount
mount_target

# ---- fallback: plain pacstrap if archinstall didn't finish ----
if [[ ! -f "$MNT/boot/vmlinuz-linux" || ! -x "$MNT/usr/bin/bash" ]]; then
  log "##### archinstall did not finish — falling back to pacstrap #####"
  pacstrap -K "$MNT" base linux linux-firmware grub $EXTRA_PKGS
  arch-chroot "$MNT" /bin/bash -c "
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime; hwclock --systohc
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; locale-gen
    echo LANG=en_US.UTF-8 > /etc/locale.conf
    echo KEYMAP=us > /etc/vconsole.conf
  "
fi

echo "$GUEST_HOSTNAME" > "$MNT/etc/hostname"
grep -q '[[:space:]]/[[:space:]]' "$MNT/etc/fstab" 2>/dev/null \
  || genfstab -U "$MNT" >> "$MNT/etc/fstab"

# ---- always: users, passwords, services, bootloader ----
log "Configuring chroot"
arch-chroot "$MNT" /bin/bash <<CHROOT
set -x
pacman -S --needed --noconfirm grub efibootmgr sudo networkmanager openssh
id $USERNAME &>/dev/null || useradd -m -G wheel -s /bin/bash $USERNAME
usermod -aG wheel $USERNAME
echo "root:$ROOT_PASS"      | chpasswd
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
systemctl enable NetworkManager sshd
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg
date > /etc/arch-autoinstalled
CHROOT

# ---- passwordless sudo for ethan ----
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$MNT/etc/sudoers.d/20-$USERNAME-nopasswd"
chmod 440 "$MNT/etc/sudoers.d/20-$USERNAME-nopasswd"

# ---- autologin ethan on tty1 ----
mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
cat > "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<UNIT
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
UNIT

# ---- first-boot dotfiles service ----
cat > "$MNT/usr/local/bin/dots-firstboot.sh" <<'FB'
#!/bin/bash
U="${DOTS_USER:-ethan}"
H="/home/$U"
REPO="${DOTS_REPO:-https://github.com/ethanetc/dotfiles.git}"
LOG="$H/dots-install.log"
DONE=/var/lib/dots-firstboot.done
echo "##### dots-firstboot: installing $REPO for $U #####"

for i in $(seq 1 60); do ping -c1 -W2 github.com >/dev/null 2>&1 && break; sleep 5; done

as_user() { runuser -u "$U" -- env HOME="$H" USER="$U" LOGNAME="$U" SHELL=/bin/bash \
            GIT_TERMINAL_PROMPT=0 "$@"; }

rm -rf "$H/dotfiles"
ok=0
for i in 1 2 3 4 5; do
  as_user git clone --depth 1 "$REPO" "$H/dotfiles" && { ok=1; break; }
  sleep 15
done
if (( ! ok )); then
  echo "!!! could not clone $REPO — will retry next boot"
  exit 1
fi

chown -R "$U:$U" "$H/dotfiles"
chmod +x "$H/dotfiles/dots.sh"
as_user bash -c "cd '$H/dotfiles' && ./dots.sh" </dev/null 2>&1 | tee -a "$LOG"
chown "$U:$U" "$LOG"

# auto-start X (i3) on tty1
for f in .zprofile .bash_profile; do
  if ! grep -q 'exec startx' "$H/$f" 2>/dev/null; then
    cat >> "$H/$f" <<'X'

# auto-start X (i3) on tty1 — added by dots-firstboot
if [[ -z $DISPLAY && $(tty) == /dev/tty1 ]]; then exec startx; fi
X
    chown "$U:$U" "$H/$f"
  fi
done

touch "$DONE"
systemctl disable dots-firstboot.service
echo "##### dots-firstboot: done — rebooting into i3 #####"
sleep 5
systemctl reboot
FB
chmod 755 "$MNT/usr/local/bin/dots-firstboot.sh"

cat > "$MNT/etc/systemd/system/dots-firstboot.service" <<UNIT
[Unit]
Description=First boot: install $USERNAME's dotfiles (dots.sh)
Wants=network-online.target
After=network-online.target NetworkManager.service
Before=getty@tty1.service
ConditionPathExists=!/var/lib/dots-firstboot.done

[Service]
Type=oneshot
Environment=DOTS_USER=$USERNAME
ExecStart=/usr/local/bin/dots-firstboot.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
arch-chroot "$MNT" systemctl enable dots-firstboot.service NetworkManager-wait-online.service

cp /root/autoinstall.log /root/*.json "$MNT/root/" 2>/dev/null || true
sync
umount -R "$MNT"

log "##### Install complete — rebooting into installed system #####"
log "Login: $USERNAME / $USER_PASS   root / $ROOT_PASS"
log "dots.sh runs on first boot then reboots into i3 automatically."
sleep 5
systemctl reboot
