#!/bin/bash

set -e

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от root"
    exit 1
fi

# Установка переменных
DISK="/dev/sda"
BOOT_SIZE="+512M"
MOUNT_POINT="/mnt/gentoo"

# Функция выбора init системы
choose_init() {
    echo "Выберите init систему:"
    echo "1) OpenRC"
    echo "2) systemd"
    read -p "Введите 1 или 2: " init_choice
    case $init_choice in
        1) INIT="openrc" ;;
        2) INIT="systemd" ;;
        *) echo "Неверный выбор"; exit 1 ;;
    esac
}

# Функция выбора ФС
choose_fs() {
    echo "Выберите файловую систему:"
    echo "1) btrfs (с подтомами)"
    echo "2) ZFS root"
    read -p "Введите 1 или 2: " fs_choice
    case $fs_choice in
        1) FS="btrfs" ;;
        2) FS="zfs" ;;
        *) echo "Неверный выбор"; exit 1 ;;
    esac
}

# Функция выбора загрузчика
choose_bootloader() {
    echo "Выберите загрузчик:"
    echo "1) systemd-boot"
    echo "2) EFISTUB"
    read -p "Введите 1 или 2: " boot_choice
    case $boot_choice in
        1) BOOTLOADER="systemd-boot" ;;
        2) BOOTLOADER="efistub" ;;
        *) echo "Неверный выбор"; exit 1 ;;
    esac
}

# Подтверждение
echo "ВНИМАНИЕ: Это полностью очистит $DISK!"
read -p "Продолжить? (y/N): " confirm
if [[ $confirm != [yY] ]]; then
    exit 0
fi

# Вызов функций выбора
choose_init
choose_fs
choose_bootloader

# Подготовка диска
echo "Разметка диска..."
sgdisk --zap-all $DISK
sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI System" $DISK
if [[ "$FS" == "zfs" ]]; then
    sgdisk -n2:0:0 -t2:bf01 -c2:"ZFS" $DISK
else
    sgdisk -n2:0:0 -t2:8300 -c2:"Root" $DISK
fi

partprobe $DISK

EFI_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"

# Форматирование
mkfs.fat -F32 $EFI_PARTITION

if [[ "$FS" == "btrfs" ]]; then
    mkfs.btrfs $ROOT_PARTITION
    mount $ROOT_PARTITION $MOUNT_POINT
    btrfs subvolume create $MOUNT_POINT/root
    btrfs subvolume create $MOUNT_POINT/home
    umount $MOUNT_POINT
    mount -o subvol=root $ROOT_PARTITION $MOUNT_POINT
    mkdir -p $MOUNT_POINT/{boot,home}
    mount $EFI_PARTITION $MOUNT_POINT/boot
    mount -o subvol=home $ROOT_PARTITION $MOUNT_POINT/home
elif [[ "$FS" == "zfs" ]]; then
    zpool create -f -o ashift=12 -O compression=lz4 -O xattr=sa -O acl=posix rootpool $ROOT_PARTITION
    zfs create -o mountpoint=legacy rootpool/ROOT
    zfs create -o mountpoint=legacy rootpool/home
    mount -t zfs rootpool/ROOT $MOUNT_POINT
    mkdir -p $MOUNT_POINT/{boot,home}
    mount $EFI_PARTITION $MOUNT_POINT/boot
    mount -t zfs rootpool/home $MOUNT_POINT/home
fi

# Скачивание stage3 и установка
echo "Выбор архива stage3..."
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64.txt | grep -v "^#" | head -n1 | awk '{print $1}')
wget -O stage3.tar.xz "https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3_URL"

# Распаковка
tar xpvf stage3.tar.xz -C $MOUNT_POINT --xattrs-include='*.*' --numeric-owner

# Копирование DNS
cp /etc/resolv.conf $MOUNT_POINT/etc/

# Монтирование системных директорий
mount --types proc /proc $MOUNT_POINT/proc
mount --rbind /sys $MOUNT_POINT/sys
mount --make-rslave $MOUNT_POINT/sys
mount --rbind /dev $MOUNT_POINT/dev
mount --make-rslave $MOUNT_POINT/dev

# Копирование скрипта для chroot
cat > $MOUNT_POINT/root/setup-chroot.sh <<EOF
#!/bin/bash
export PS1="(chroot) $PS1"

# Выбор профиля
eselect profile set default/linux/amd64/17.1

# Обновление портежа
emerge --sync
emerge --verbose --update --deep --newuse @world

# Установка системных пакетов
emerge sys-kernel/linux-firmware
emerge sys-kernel/genkernel

# Настройка fstab
genfstab -U $MOUNT_POINT >> /etc/fstab

# Установка ядра
if [[ "$FS" == "zfs" ]]; then
    echo 'zfs' >> /etc/portage/make.conf
    emerge sys-fs/zfs
    genkernel --kernel-config=/etc/kernels/kernel-config-$(uname -r) all
else
    genkernel all
fi

# Настройка часового пояса
echo "Europe/Moscow" > /etc/timezone
emerge --config sys-libs/timezone-data

# Настройка локали
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set ru_RU.UTF-8

env-update && source /etc/profile

# Установка init системы
if [[ "$INIT" == "openrc" ]]; then
    emerge sys-apps/openrc
    eselect rc update
    rc-update add sshd default
    rc-update add dhcpcd default
    echo 'rc_controller_cgroups="YES"' >> /etc/rc.conf
else
    echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
    emerge sys-boot/systemd
fi

# Установка загрузчика
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    if [[ "$INIT" == "systemd" ]]; then
        bootctl install
        cat > /boot/loader/entries/gentoo.conf <<BOOTCONF
title    Gentoo Linux
linux    /vmlinuz-linux
initrd   /initramfs-linux.img
options  root=PARTUUID=\$(blkid -s PARTUUID -o value $ROOT_PARTITION) rootfstype=\$([[ "$FS" == "zfs" ]] && echo zfs || echo btrfs) \$([[ "$FS" == "btrfs" ]] && echo "subvol=root")
BOOTCONF
    fi
elif [[ "$BOOTLOADER" == "efistub" ]]; then
    # EFISTUB использует efibootmgr
    echo "Настройка EFISTUB..."
    # Вручную или через efibootmgr
    # Это требует дополнительных действий в live-среде
    # Пока что просто добавим в fstab
    echo "Для EFISTUB настройте efibootmgr вручную."
fi

# Установка пароля root
passwd

EOF

chmod +x $MOUNT_POINT/root/setup-chroot.sh

# Вход в chroot и выполнение скрипта
chroot $MOUNT_POINT /root/setup-chroot.sh

# Удаление скрипта
rm $MOUNT_POINT/root/setup-chroot.sh

echo "Установка завершена! Выгрузите файловые системы и перезагрузитесь."
