#!/bin/bash
set -euo pipefail

# Целевой диск
DISK="/dev/sda"
EFI_SIZE="512M"
SWAP_SIZE="4G"  # Настройте по необходимости

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Проверка: запущен ли в chroot?
if [ -f /etc/gentoo-release ]; then
    error "Скрипт должен запускаться из LiveCD/USB, а не из chroot!"
fi

# Проверка UEFI
if [ ! -d /sys/firmware/efi ]; then
    error "Требуется UEFI. Legacy BIOS не поддерживается этим скриптом."
fi

# Выбор init-системы
PS3="Выберите init-систему: "
select INIT in "systemd" "openrc"; do
    case $INIT in
        systemd|openrc) break ;;
        *) echo "Неверный выбор";;
    esac
done

# Выбор файловой системы
PS3="Выберите тип корневой ФС: "
select FS in "btrfs-subvol" "zfs-root"; do
    case $FS in
        "btrfs-subvol"|"zfs-root") break ;;
        *) echo "Неверный выбор";;
    esac
done

# Выбор загрузчика
if [ "$INIT" = "systemd" ]; then
    BOOTLOADER="systemd-boot"
else
    PS3="Выберите загрузчик (для OpenRC): "
    select BOOTLOADER in "efistub"; do
        case $BOOTLOADER in
            efistub) break ;;
            *) echo "Только EFISTUB поддерживается для OpenRC в этом скрипте";;
        esac
    done
fi

log "Выбрано: init=$INIT, fs=$FS, bootloader=$BOOTLOADER"

# === 1. Разметка диска ===
log "Разметка диска $DISK..."

# Очистка диска
sgdisk --zap-all "$DISK" || true
sleep 2

if [ "$FS" = "zfs-root" ]; then
    # ZFS требует особой разметки
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:0       -t 2:bf00 -c 2:"ZFS" "$DISK"
else
    # Btrfs: EFI + swap + root
    sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2:0:+$SWAP_SIZE -t 2:8200 -c 2:"swap" "$DISK"
    sgdisk -n 3:0:0        -t 3:8300 -c 3:"root" "$DISK"
fi

partprobe "$DISK"
sleep 3

# === 2. Форматирование и монтирование ===
EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"
ZFS_PART="${DISK}2"  # при ZFS

if [ "$FS" = "zfs-root" ]; then
    log "Установка ZFS..."

    # Добавление репозитория ZFS (если нужно)
    modprobe zfs
    zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -O normalization=formD \
        -O mountpoint=none rpool "$ZFS_PART"

    zfs create -o mountpoint=legacy rpool/ROOT
    zfs create -o mountpoint=none rpool/DATA
    zfs create -o mountpoint=legacy rpool/DATA/home

    # Монтируем корень
    mkdir -p /mnt/gentoo
    mount -t zfs rpool/ROOT /mnt/gentoo

    # Создаём подкаталоги
    mkdir -p /mnt/gentoo/{boot,home}
    mount -t zfs rpool/DATA/home /mnt/gentoo/home

else
    # Btrfs с подтомами
    mkfs.vfat -F32 "$EFI_PART"
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"

    mkfs.btrfs -f "$ROOT_PART"
    mount "$ROOT_PART" /mnt/btrfs-tmp

    # Создание подтомов
    btrfs subvolume create /mnt/btrfs-tmp/@
    btrfs subvolume create /mnt/btrfs-tmp/@home
    btrfs subvolume create /mnt/btrfs-tmp/@snapshots

    umount /mnt/btrfs-tmp
    mkdir -p /mnt/gentoo
    mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo
    mkdir -p /mnt/gentoo/{home,.snapshots}
    mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo/home
    mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo/.snapshots
fi

# Монтируем EFI
mkdir -p /mnt/gentoo/boot/efi
mount "$EFI_PART" /mnt/gentoo/boot/efi

# === 3. Загрузка stage3 ===
log "Загрузка stage3..."

cd /mnt/gentoo

# Определяем профиль
if [ "$INIT" = "systemd" ]; then
    PROFILE="systemd"
else
    PROFILE="default"
fi

# Получаем URL последнего stage3 (amd64)
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-$PROFILE.txt | grep -v "^#" | cut -f1 -d' ')
wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3_URL" -O stage3.tar.xz

# Распаковка
tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
rm stage3.tar.xz

# === 4. Настройка chroot-окружения ===
log "Настройка chroot..."

# Зеркала
mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf
echo 'MAKEOPTS="-j$(nproc)"' >> /mnt/gentoo/etc/portage/make.conf

# fstab
cat > /mnt/gentoo/etc/fstab <<EOF
# <fs>                  <mountpoint>    <type>  <opts>      <dump/pass>
EOF

if [ "$FS" = "zfs-root" ]; then
    echo "rpool/ROOT          /               zfs     defaults    0 0" >> /mnt/gentoo/etc/fstab
    echo "rpool/DATA/home     /home           zfs     defaults    0 0" >> /mnt/gentoo/etc/fstab
else
    UUID_ROOT=$(blkid -s UUID -o value "$ROOT_PART")
    echo "UUID=$UUID_ROOT     /               btrfs   subvol=@,compress=zstd,noatime  0 0" >> /mnt/gentoo/etc/fstab
    echo "UUID=$UUID_ROOT     /home           btrfs   subvol=@home,compress=zstd,noatime 0 0" >> /mnt/gentoo/etc/fstab
    echo "UUID=$UUID_ROOT     /.snapshots     btrfs   subvol=@snapshots,compress=zstd,noatime 0 0" >> /mnt/gentoo/etc/fstab
fi

UUID_EFI=$(blkid -s UUID -o value "$EFI_PART")
echo "UUID=$UUID_EFI      /boot/efi       vfat    defaults    0 2" >> /mnt/gentoo/etc/fstab

if [ "$FS" != "zfs-root" ]; then
    UUID_SWAP=$(blkid -s UUID -o value "$SWAP_PART")
    echo "UUID=$UUID_SWAP     none            swap    sw          0 0" >> /mnt/gentoo/etc/fstab
fi

# Сетевые настройки
echo "hostname=\"gentoo\"" > /mnt/gentoo/etc/conf.d/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/gentoo/etc/localtime
echo "sys-apps/systemd" >> /mnt/gentoo/etc/portage/package.use/systemd 2>/dev/null || true

# === 5. Chroot и завершение установки ===
log "Переход в chroot..."

# Копируем DNS
cp -L /etc/resolv.conf /mnt/gentoo/etc/

# Монтируем псевдо-ФС
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Chroot-скрипт
cat > /mnt/gentoo/root/install-chroot.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Обновление Portage
emerge --sync --quiet

# Установка ядра
emerge sys-kernel/gentoo-sources sys-apps/pciutils

# Конфигурация ядра (упрощённо — используем defconfig + модули)
cd /usr/src/linux
make defconfig
echo 'CONFIG_MODULES=y' >> .config
scripts/config --enable CONFIG_BINFMT_SCRIPT
scripts/config --enable CONFIG_EFI
scripts/config --enable CONFIG_EFI_STUB
if [ "$FS" = "zfs-root" ]; then
    scripts/config --module CONFIG_ZFS
    # ZFS требует дополнительной настройки (в реальности — через ebuild)
    emerge sys-fs/zfs
elif [ "$FS" = "btrfs-subvol" ]; then
    scripts/config --enable CONFIG_BTRFS_FS
fi
make -j$(nproc) modules_prepare
make -j$(nproc) modules
make modules_install

# Установка ядра
make install

# Обновление мира
emerge --update --deep --newuse @world

# Установка загрузчика
if [ "$BOOTLOADER" = "systemd-boot" ]; then
    bootctl install
    cat > /boot/loader/entries/gentoo.conf <<INNEREOF
title Gentoo Linux
linux /vmlinuz-$(uname -r)
initrd /initramfs-$(uname -r).img
options root=UUID=$(blkid -s UUID -o value /dev/sda3) rootflags=subvol=@ rw
INNEREOF
    cat > /boot/loader/loader.conf <<INNEREOF
default gentoo
timeout 4
INNEREOF
elif [ "$BOOTLOADER" = "efistub" ]; then
    # EFISTUB: создаём запись через efibootmgr
    KERNEL_VERSION=$(uname -r)
    UUID_ROOT=$(blkid -s UUID -o value /dev/sda3)
    efibootmgr --create --disk /dev/sda --part 1 \
        --loader "/vmlinuz-${KERNEL_VERSION}" \
        --label "Gentoo" \
        --unicode "root=UUID=${UUID_ROOT} rootflags=subvol=@ rw initrd=\\initramfs-${KERNEL_VERSION}.img"
fi

# Установка пароля root
echo "root:password" | chpasswd

# Завершение
log "Установка завершена! Перезагрузитесь."
EOF

chmod +x /mnt/gentoo/root/install-chroot.sh

# Передаём переменные в chroot
chroot /mnt/gentoo /bin/bash -c "
export INIT='$INIT'
export FS='$FS'
export BOOTLOADER='$BOOTLOADER'
/root/install-chroot.sh
"

log "Установка завершена. Выполните 'reboot' и удалите установочный носитель."
