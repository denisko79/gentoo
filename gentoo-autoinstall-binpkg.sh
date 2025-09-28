#!/bin/bash
set -euo pipefail

# === Настройки ===
DISK="/dev/sda"
EFI_SIZE="512M"

# Зеркала Gentoo (в порядке приоритета)
MIRRORS=(
    "https://distfiles.gentoo.org"
    "https://mirror.yandex.ru/gentoo-distfiles"
    "https://ftp.fau.de/gentoo"
    "https://gentoo.c3sl.ufpr.br"
)

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# === Подготовка: отключаем swap и размонтируем ===
cleanup() {
    swapoff -a 2>/dev/null || true
    umount /dev/sda* 2>/dev/null || true
    umount /mnt/gentoo* 2>/dev/null || true
}
cleanup

# === Проверка: LiveCD? ===
check_live() {
    ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
    case "$ROOT_FS" in
        squashfs|overlay|tmpfs|ramfs|iso9660|cramfs) ;;
        ext4|btrfs|xfs|zfs|f2fs)
            error "Корневая ФС — $ROOT_FS. Запускайте из LiveCD!"
            ;;
        *)
            warn "Неизвестная ФС: $ROOT_FS. Убедитесь, что вы в LiveCD."
            read -p "Продолжить? (y/N): " -n1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
            ;;
    esac
}
check_live

# === Проверка UEFI ===
[ -d /sys/firmware/efi ] || error "Требуется UEFI."

# === Сеть ===
log "Проверка интернета..."
if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
    error "Нет интернета. Настройте сеть (например: dhcpcd)."
fi
if ! ping -c1 -W3 distfiles.gentoo.org &>/dev/null; then
    warn "DNS работает, но distfiles.gentoo.org не пингуется — возможно, временные проблемы."
fi

# === Выбор конфигурации ===
log "Выберите init-систему:"
select INIT in "systemd" "openrc"; do
    [[ "$INIT" = "systemd" || "$INIT" = "openrc" ]] && break
    echo "Неверный выбор"
done

log "Выберите корневую ФС:"
select FS in "btrfs-subvol" "zfs-root"; do
    [[ "$FS" = "btrfs-subvol" || "$FS" = "zfs-root" ]] && break
    echo "Неверный выбор"
done

# Профиль для stage3
if [ "$INIT" = "systemd" ]; then
    PROFILE="systemd"
    BOOTLOADER="systemd-boot"
else
    PROFILE="openrc"      # ← КЛЮЧЕВОЕ: не "default"!
    BOOTLOADER="efistub"
fi

log "Конфигурация: init=$INIT, profile=$PROFILE, fs=$FS, bootloader=$BOOTLOADER"

# === Разметка диска (без swap) ===
log "Разметка $DISK..."
sgdisk --zap-all "$DISK" &>/dev/null || true
sleep 2

if [ "$FS" = "zfs-root" ]; then
    sgdisk -n1:0:+$EFI_SIZE -t1:ef00 -c1:"EFI" "$DISK"
    sgdisk -n2:0:0       -t2:bf00 -c2:"ZFS" "$DISK"
else
    sgdisk -n1:0:+$EFI_SIZE -t1:ef00 -c1:"EFI" "$DISK"
    sgdisk -n2:0:0        -t2:8300 -c2:"root" "$DISK"
fi

partprobe "$DISK"
sleep 3

# === Форматирование ===
EFI="${DISK}1"
ROOT="${DISK}2"
ZFS_PART="${DISK}2"

if [ "$FS" = "zfs-root" ]; then
    modprobe zfs || error "ZFS не поддерживается в этом LiveCD."
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
    mkfs.vfat -F32 "$EFI"
    mkfs.btrfs -f "$ROOT"
    mkdir -p /mnt/btrfs-tmp
    mount "$ROOT" /mnt/btrfs-tmp
    btrfs subvolume create /mnt/btrfs-tmp/@
    btrfs subvolume create /mnt/btrfs-tmp/@home
    umount /mnt/btrfs-tmp
    rmdir /mnt/btrfs-tmp
    mkdir -p /mnt/gentoo
    mount -o subvol=@,compress=zstd,noatime "$ROOT" /mnt/gentoo
    mkdir -p /mnt/gentoo/home
    mount -o subvol=@home,compress=zstd,noatime "$ROOT" /mnt/gentoo/home
fi

mkdir -p /mnt/gentoo/boot/efi
mount "$EFI" /mnt/gentoo/boot/efi

# === Загрузка stage3 ===
log "Получение списка stage3..."

LISTING_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-${PROFILE}.txt"
LISTING_CONTENT=$(curl -s --max-time 10 "$LISTING_URL")

if [ -z "$LISTING_CONTENT" ]; then
    error "Не удалось загрузить список stage3. Проверьте зеркала:\n$LISTING_URL"
fi

STAGE3_FILE=$(echo "$LISTING_CONTENT" | grep -v '^#' | head -n1 | awk '{print $1}')
[ -z "$STAGE3_FILE" ] && error "Не удалось определить имя stage3."

log "Найден файл: $STAGE3_FILE"

# Скачивание с резервных зеркал
stage3_ok=false
for MIRROR in "${MIRRORS[@]}"; do
    log "Пробую: $MIRROR"
    if wget -q --timeout=15 "$MIRROR/releases/amd64/autobuilds/$STAGE3_FILE" -O /mnt/gentoo/stage3.tar.xz; then
        stage3_ok=true
        break
    fi
done

[ "$stage3_ok" = false ] && error "Не удалось скачать stage3 ни с одного зеркала."

cd /mnt/gentoo
tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm -f stage3.tar.xz
log "Stage3 установлен."

# === fstab ===
cat > /mnt/gentoo/etc/fstab <<EOF
# <device>        <mountpoint>    <type>  <options>               <dump/pass>
EOF

if [ "$FS" = "zfs-root" ]; then
    echo "rpool/ROOT      /               zfs     defaults                0 0" >> /mnt/gentoo/etc/fstab
    echo "rpool/home      /home           zfs     defaults                0 0" >> /mnt/gentoo/etc/fstab
else
    UUID=$(blkid -s UUID -o value "$ROOT")
    echo "UUID=$UUID      /               btrfs   subvol=@,compress=zstd,noatime  0 0" >> /mnt/gentoo/etc/fstab
    echo "UUID=$UUID      /home           btrfs   subvol=@home,compress=zstd,noatime 0 0" >> /mnt/gentoo/etc/fstab
fi

UUID_EFI=$(blkid -s UUID -o value "$EFI")
echo "UUID=$UUID_EFI  /boot/efi       vfat    defaults                0 2" >> /mnt/gentoo/etc/fstab

# === Базовая настройка ===
echo "hostname=\"gentoo\"" > /mnt/gentoo/etc/conf.d/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/gentoo/etc/localtime
mkdir -p /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
echo 'MAKEOPTS="-j$(nproc)"' >> /mnt/gentoo/etc/portage/make.conf

# === Chroot-скрипт ===
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

# Initramfs
if [ "$FS" = "zfs-root" ] || [ "$FS" = "btrfs-subvol" ]; then
    emerge sys-kernel/dracut
    dracut --force --kmoddir /lib/modules/$(uname -r)
fi

emerge -uDU --keep-going @world

# Загрузчик
if [ "$BOOTLOADER" = "systemd-boot" ]; then
    bootctl install
    KVER=$(uname -r)
    UUID=$(blkid -s UUID -o value /dev/sda2)
    cat > /boot/loader/entries/gentoo.conf <<INNEREOF
title Gentoo Linux
linux /vmlinuz-${KVER}
initrd /initramfs-${KVER}.img
options root=UUID=${UUID} rootflags=subvol=@ rw
INNEREOF
    cat > /boot/loader/loader.conf <<INNEREOF
default gentoo
timeout 4
INNEREOF
elif [ "$BOOTLOADER" = "efistub" ]; then
    KVER=$(uname -r)
    UUID=$(blkid -s UUID -o value /dev/sda2)
    efibootmgr --create --disk /dev/sda --part 1 \
        --loader "/vmlinuz-${KVER}" \
        --label "Gentoo" \
        --unicode "root=UUID=${UUID} rootflags=subvol=@ rw initrd=\\\\initramfs-${KVER}.img"
fi

echo "root:gentoo" | chpasswd
log "✅ Установка завершена! Пароль: 'gentoo' (СМЕНИТЕ!)"
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
