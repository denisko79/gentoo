#!/bin/bash
set -euo pipefail

# === Настройки ===
DISK="/dev/sda"
EFI_SIZE="512M"
SWAP_SIZE="4G"  # Измените при необходимости

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === Проверка: запущен ли из LiveCD? ===
check_live_environment() {
    # Проверка: корневая ФС — это диск? (тогда точно не LiveCD)
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")
    if [[ "$ROOT_DEV" == /dev/sda* ]] || [[ "$ROOT_DEV" == /dev/nvme0n1p* ]] || [[ "$ROOT_DEV" == /dev/mmcblk0p* ]]; then
        error "Корневая ФС — $ROOT_DEV. Скрипт должен запускаться из LiveCD/USB!"
    fi

    # Проверка chroot: inode / != inode /proc/1/root
    if [ -d /proc/1/root ] && command -v stat >/dev/null 2>&1; then
        ROOT_INODE=$(stat -c '%d:%i' /)
        INIT_ROOT_INODE=$(stat -c '%d:%i' /proc/1/root/ 2>/dev/null || echo "0:0")
        if [ "$ROOT_INODE" != "$INIT_ROOT_INODE" ]; then
            error "Обнаружен chroot. Запускайте скрипт из LiveCD!"
        fi
    fi

    # Предупреждение, если Gentoo-специфичные файлы есть (но не ошибка)
    if [ -f /etc/gentoo-release ]; then
        warn "Обнаружен /etc/gentoo-release — убедитесь, что вы в LiveCD!"
        read -p "Продолжить установку (весь $DISK будет стёрт)? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

check_live_environment

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

# === 1. Разметка диска ===
log "Очистка и разметка $DISK..."

# Очистка
sgdisk --zap-all "$DISK" &>/dev/null || true
sleep 2

if [ "$FS" = "zfs-root" ]; then
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:0       -t 2:bf00 -c 2:"ZFS" "$DISK"
else
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:+$SWAP_SIZE -t 2:8200 -c 2:"swap" "$DISK"
    sgdisk -n 3:0:0        -t 3:8300 -c 3:"root" "$DISK"
fi

partprobe "$DISK"
sleep 3

# === 2. Форматирование ===
EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"
ZFS_PART="${DISK}2"

if [ "$FS" = "zfs-root" ]; then
    log "Создание ZFS pool..."
    modprobe zfs || error "Модуль ZFS не загружен. Используйте ZFS-совместимый LiveCD (например, SystemRescue)."
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
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
    mkfs.btrfs -f "$ROOT_PART"
    mount "$ROOT_PART" /mnt/btrfs-tmp

    btrfs subvolume create /mnt/btrfs-tmp/@
    btrfs subvolume create /mnt/btrfs-tmp/@home
    umount /mnt/btrfs-tmp

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

# Получаем актуальный stage3 (на 2025)
LISTING_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-${PROFILE}.txt"
STAGE3_FILE=$(curl -s "$LISTING_URL" | grep -v "^#" | head -n1 | cut -d' ' -f1)
[ -z "$STAGE3_FILE" ] && error "Не удалось определить URL stage3"

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

if [ "$FS" != "zfs-root" ]; then
    UUID_SWAP=$(blkid -s UUID -o value "$SWAP_PART")
    echo "UUID=$UUID_SWAP none            swap    sw                      0 0" >> /mnt/gentoo/etc/fstab
fi

# Сетевые настройки
echo "hostname=\"gentoo\"" > /mnt/gentoo/etc/conf.d/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/gentoo/etc/localtime

# Зеркала
mkdir -p /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf 2>/dev/null || true
echo 'MAKEOPTS="-j$(nproc)"' >> /mnt/gentoo/etc/portage/make.conf

# === 5. Chroot-скрипт ===
cat > /mnt/gentoo/root/install-chroot.sh <<'EOF'
#!/bin/bash
set -euo pipefail

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

# Синхронизация
emerge --sync --quiet

# Ядро
emerge sys-kernel/gentoo-sources sys-apps/pciutils

# Конфигурация ядра
cd /usr/src/linux
make defconfig

# Включаем обязательные опции
scripts/config --enable CONFIG_MODULES
scripts/config --enable CONFIG_EFI
scripts/config --enable CONFIG_EFI_STUB
scripts/config --enable CONFIG_BINFMT_SCRIPT

# ФС
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

# Initramfs (для ZFS и btrfs subvol нужен)
if [ "$FS" = "zfs-root" ] || [ "$FS" = "btrfs-subvol" ]; then
    emerge sys-kernel/dracut
    dracut --force --kmoddir /lib/modules/$(uname -r)
fi

# Обновление системы
emerge -uDU --keep-going @world

# Загрузчик
if [ "$BOOTLOADER" = "systemd-boot" ]; then
    bootctl install
    KVER=$(uname -r)
    cat > /boot/loader/entries/gentoo.conf <<INNEREOF
title Gentoo Linux
linux /vmlinuz-${KVER}
initrd /initramfs-${KVER}.img
options root=UUID=$(blkid -s UUID -o value /dev/sda3) rootflags=subvol=@ rw
INNEREOF
    cat > /boot/loader/loader.conf <<INNEREOF
default gentoo
timeout 4
INNEREOF
elif [ "$BOOTLOADER" = "efistub" ]; then
    KVER=$(uname -r)
    UUID_ROOT=$(blkid -s UUID -o value /dev/sda3)
    efibootmgr --create --disk /dev/sda --part 1 \
        --loader "/vmlinuz-${KVER}" \
        --label "Gentoo" \
        --unicode "root=UUID=${UUID_ROOT} rootflags=subvol=@ rw initrd=\\\\initramfs-${KVER}.img"
fi

# Пароль root (ИЗМЕНИТЕ ПОСЛЕ УСТАНОВКИ!)
echo "root:gentoo" | chpasswd

log "Установка завершена! Перезагрузитесь."
EOF

chmod +x /mnt/gentoo/root/install-chroot.sh

# Передача переменных в chroot
cat > /mnt/gentoo/root/env.sh <<EOF
export INIT='$INIT'
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

# Запуск chroot
chroot /mnt/gentoo /bin/bash -c "source /root/env.sh && /root/install-chroot.sh"

log "✅ Установка Gentoo завершена!"
log "🔁 Выполните: umount -R /mnt/gentoo && reboot"
