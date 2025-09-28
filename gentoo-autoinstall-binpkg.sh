#!/bin/bash
set -euo pipefail

# === Настройки ===
DISK="/dev/sda"
EFI_SIZE="512M"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === Отключаем swap и размонтируем старые разделы (для повторного запуска) ===
swapoff -a 2>/dev/null || true
umount /dev/sda* 2>/dev/null || true
umount /mnt/gentoo* 2>/dev/null || true

# === Проверка: LiveCD или установленная система? ===
detect_live_environment() {
    ROOT_FS_TYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
    log "Тип корневой ФС: $ROOT_FS_TYPE"

    case "$ROOT_FS_TYPE" in
        squashfs|overlay|tmpfs|ramfs|cramfs|iso9660)
            log "✅ Обнаружена LiveCD-среда — продолжаем."
            ;;
        ext4|ext3|btrfs|xfs|zfs|f2fs)
            error "Корневая ФС — $ROOT_FS_TYPE. Это НЕ LiveCD! Загрузитесь с установочного носителя."
            ;;
        *)
            warn "Неизвестный тип ФС: $ROOT_FS_TYPE. Убедитесь, что вы в LiveCD."
            read -p "Продолжить установку (весь $DISK будет стёрт)? (y/N): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
            ;;
    esac
}

detect_live_environment

# === Проверка UEFI ===
if [ ! -d /sys/firmware/efi ]; then
    error "Требуется UEFI. Legacy BIOS не поддерживается."
fi

# === Выбор конфигурации ===
log "Выберите init-систему:"
select INIT in "systemd" "openrc"; do
    [[ "$INIT" == "systemd" || "$INIT" == "openrc" ]] && break
    echo "Неверный выбор"
done

log "Выберите тип корневой ФС:"
select FS in "btrfs-subvol" "zfs-root"; do
    [[ "$FS" == "btrfs-subvol" || "$FS" == "zfs-root" ]] && break
    echo "Неверный выбор"
done

if [ "$INIT" = "systemd" ]; then
    BOOTLOADER="systemd-boot"
else
    BOOTLOADER="efistub"
fi

log "Конфигурация: init=$INIT, fs=$FS, bootloader=$BOOTLOADER"

# === 1. Разметка диска (БЕЗ swap) ===
log "Очистка и разметка $DISK (только EFI + корень)..."

sgdisk --zap-all "$DISK" &>/dev/null || true
sleep 2

if [ "$FS" = "zfs-root" ]; then
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:0       -t 2:bf00 -c 2:"ZFS" "$DISK"
else
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:0        -t 2:8300 -c 2:"root" "$DISK"
fi

partprobe "$DISK"
sleep 3

# === 2. Форматирование и монтирование (БЕЗ swap) ===
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
ZFS_PART="${DISK}2"

if [ "$FS" = "zfs-root" ]; then
    log "Создание ZFS pool..."
    if ! modprobe zfs 2>/dev/null; then
        error "Модуль ZFS недоступен. Используйте ZFS-совместимый LiveCD (например, SystemRescue)."
    fi
    zpool create -f -o ashift=12 \
        -O compression=zstd -O atime=off -O xattr=sa -O normalization=formD \
        -O mountpoint=none rpool "$ZFS_PART"

    zfs create -o mountpoint=legacy rpool/ROOT
    zfs create -o mountpoint=legacy rpool/home

    mkdir -p /mnt/gentoo
    mount -t zfs rpool/ROOT /mnt/gentoo
    mkdir -p /mnt/gentoo/home
    mount -t zfs rpool/home /mnt/gentoo/home
else
    mkfs.vfat -F32 "$EFI_PART"
    mkfs.btrfs -f "$ROOT_PART"

    mkdir -p /mnt/btrfs-tmp
    mount "$ROOT_PART" /mnt/btrfs-tmp

    btrfs subvolume create /mnt/btrfs-tmp/@
    btrfs subvolume create /mnt/btrfs-tmp/@home
    umount /mnt/btrfs-tmp
    rmdir /mnt/btrfs-tmp

    mkdir -p /mnt/gentoo
    mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo
    mkdir -p /mnt/gentoo/home
    mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo/home
fi

mkdir -p /mnt/gentoo/boot/efi
mount "$EFI_PART" /mnt/gentoo/boot/efi

# === 3. Загрузка stage3 ===
log "Загрузка stage3..."

cd /mnt/gentoo

PROFILE="default"
[ "$INIT" = "systemd" ] && PROFILE="systemd"

LISTING_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-${PROFILE}.txt"
STAGE3_FILE=$(curl -s "$LISTING_URL" | grep -v "^#" | head -n1 | cut -d' ' -f1)
[ -z "$STAGE3_FILE" ] && error "Не удалось получить URL stage3"

wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3_FILE" -O stage3.tar.xz
tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3.tar.xz

# === 4. fstab и базовая настройка ===
cat > /mnt/gentoo/etc/fstab <<EOF
# <device>        <mountpoint>    <type>  <options>               <dump/pass>
EOF

if [ "$FS" = "zfs-root" ]; then
    echo "rpool/ROOT      /               zfs     defaults                0 0" >> /mnt/gentoo/etc/fstab
    echo "rpool/home      /home           zfs     defaults                0 0" >> /mnt/gentoo/etc/fstab
else
    UUID=$(blkid -s UUID -o value "$ROOT_PART")
    echo "UUID=$UUID      /               btrfs   subvol=@,compress=zstd,noatime  0 0" >> /mnt/gentoo/etc/fstab
    echo "UUID=$UUID      /home           btrfs   subvol=@home,compress=zstd,noatime 0 0" >> /mnt/gentoo/etc/fstab
fi

UUID_EFI=$(blkid -s UUID -o value "$EFI_PART")
echo "UUID=$UUID_EFI  /boot/efi       vfat    defaults                0 2" >> /mnt/gentoo/etc/fstab

echo "hostname=\"gentoo\"" > /mnt/gentoo/etc/conf.d/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/gentoo/etc/localtime

mkdir -p /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
echo 'MAKEOPTS="-j$(nproc)"' >> /mnt/gentoo/etc/portage/make.conf

# === 5. Chroot-скрипт ===
cat > /mnt/gentoo/root/install-chroot.sh <<'EOF'
#!/bin/bash
set -euo pipefail

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

emerge --sync --quiet

emerge sys-kernel/gentoo-sources sys-apps/pciutils

cd /usr/src/linux
make defconfig

scripts/config --enable CONFIG_MODULES
scripts/config --enable CONFIG_EFI
scripts/config --enable CONFIG_EFI_STUB
scripts/config --enable CONFIG_BINFMT_SCRIPT

if [ "$FS" = "zfs-root" ]; then
    scripts/config --module CONFIG_ZFS
    emerge sys-fs/zfs
elif [ "$FS" = "btrfs-subvol" ]; then
    scripts/config --enable CONFIG_BTRFS_FS
fi

make -j$(nproc) modules_prepare
make -j$(nproc) modules
make modules_install
make install

# Initramfs обязателен для btrfs subvol и ZFS
if [ "$FS" = "zfs-root" ] || [ "$FS" = "btrfs-subvol" ]; then
    emerge sys-kernel/dracut
    dracut --force --kmoddir /lib/modules/$(uname -r)
fi

emerge -uDU --keep-going @world

if [ "$BOOTLOADER" = "systemd-boot" ]; then
    bootctl install
    KVER=$(uname -r)
    UUID_ROOT=$(blkid -s UUID -o value /dev/sda2)
    cat > /boot/loader/entries/gentoo.conf <<INNEREOF
title Gentoo Linux
linux /vmlinuz-${KVER}
initrd /initramfs-${KVER}.img
options root=UUID=${UUID_ROOT} rootflags=subvol=@ rw
INNEREOF
    cat > /boot/loader/loader.conf <<INNEREOF
default gentoo
timeout 4
INNEREOF
elif [ "$BOOTLOADER" = "efistub" ]; then
    KVER=$(uname -r)
    UUID_ROOT=$(blkid -s UUID -o value /dev/sda2)
    efibootmgr --create --disk /dev/sda --part 1 \
        --loader "/vmlinuz-${KVER}" \
        --label "Gentoo" \
        --unicode "root=UUID=${UUID_ROOT} rootflags=subvol=@ rw initrd=\\\\initramfs-${KVER}.img"
fi

echo "root:gentoo" | chpasswd
log "✅ Установка завершена! Пароль root: 'gentoo' (СМЕНИТЕ ПОСЛЕ ВХОДА!)"
EOF

chmod +x /mnt/gentoo/root/install-chroot.sh

# Передача переменных
cat > /mnt/gentoo/root/env.sh <<EOF
export FS='$FS'
export BOOTLOADER='$BOOTLOADER'
EOF

# Монтируем псевдо-ФС
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
cp -L /etc/resolv.conf /mnt/gentoo/etc/

# Запуск
chroot /mnt/gentoo /bin/bash -c "source /root/env.sh && /root/install-chroot.sh"

log "✅ Установка Gentoo завершена!"
log "🔁 Выполните:"
log "   umount -R /mnt/gentoo"
log "   reboot"
