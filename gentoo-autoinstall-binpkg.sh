#!/bin/bash
# ======================================================================
# AUTOINSTALL GENTOO WITH CHOICES: systemd/openrc, btrfs/subvol, zfs-root, systemd-boot + efistub
# + AUTOMATIC MIRROR SELECTION + BINARY PACKAGE INSTALLATION (BINPKG)
# Run from Gentoo LiveCD with internet access and partitioned disk (e.g. /dev/nvme0n1)
# ======================================================================

set -e

# --- CONFIGURATION ---
DISK="/dev/nvme0n1"           # CHANGE THIS TO YOUR DISK!
BOOT_SIZE="512M"
SWAP_SIZE="4G"
ROOT_SIZE="rest"

EFI_PARTITION="${DISK}p1"
SWAP_PARTITION="${DISK}p2"
ROOT_PARTITION="${DISK}p3"

# BINPKG CONFIG (use official Gentoo binary repository)
BINPKG_HOST="https://binpkg.gentoo.org"
BINPKG_ARCH="amd64"
BINPKG_USE="hardened"  # or "default"

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- FUNCTIONS ---
log() { echo -e "${BLUE}>> $1${NC}"; }
warn() { echo -e "${YELLOW}!! $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; exit 1; }
success() { echo -e "${GREEN}✓ $1${NC}"; }

# --- CHECKS ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root!"
    fi
}

check_disk() {
    if [ ! -b "$DISK" ]; then
        error "Disk $DISK not found!"
    fi
    warn "This will ERASE ALL DATA on $DISK!"
    read -p "Continue? (y/N): " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted."
}

# --- PARTITIONING ---
partition_disk() {
    log "Partitioning $DISK..."

    dd if=/dev/zero of="$DISK" bs=512 count=2048 conv=notrunc 2>/dev/null

    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart swap linux-swap "$BOOT_SIZE" "$(( $(blockdev --getsize64 "$DISK") - 1024*1024*1024 ))"
    parted -s "$DISK" mkpart primary ext4 "$(( $(blockdev --getsize64 "$DISK") - 1024*1024*1024 ))" 100%

    mkfs.fat -F32 "$EFI_PARTITION"
    mkswap "$SWAP_PARTITION"
    swapon "$SWAP_PARTITION"

    success "Partitions created and formatted."
}

# --- FILESYSTEM SETUP ---
setup_btrfs() {
    log "Setting up BTRFS with subvolumes..."
    mkfs.btrfs -f "$ROOT_PARTITION"

    mount "$ROOT_PARTITION" /mnt/gentoo

    btrfs subvolume create /mnt/gentoo/@
    btrfs subvolume create /mnt/gentoo/@home
    btrfs subvolume create /mnt/gentoo/@var
    btrfs subvolume create /mnt/gentoo/@tmp
    btrfs subvolume create /mnt/gentoo/@snapshots

    umount /mnt/gentoo
    mount -o subvol=@ "$ROOT_PARTITION" /mnt/gentoo
    mkdir -p /mnt/gentoo/{home,var,tmp,.snapshots}
    mount -o subvol=@home "$ROOT_PARTITION" /mnt/gentoo/home
    mount -o subvol=@var "$ROOT_PARTITION" /mnt/gentoo/var
    mount -o subvol=@tmp "$ROOT_PARTITION" /mnt/gentoo/tmp
    mount -o subvol=@snapshots "$ROOT_PARTITION" /mnt/gentoo/.snapshots

    mkdir -p /mnt/gentoo/boot
    mount "$EFI_PARTITION" /mnt/gentoo/boot

    success "BTRFS subvolumes mounted."
}

setup_zfs() {
    log "Setting up ZFS root..."

    emerge --sync
    emerge -q sys-fs/zfs
    modprobe zfs

    zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -O mountpoint=none rpool "$ROOT_PARTITION"

    zfs create -o mountpoint=none rpool/root
    zfs create -o mountpoint=/ rpool/root/gentoo
    zfs create -o mountpoint=/home rpool/root/home
    zfs create -o mountpoint=/var rpool/root/var
    zfs create -o mountpoint=/tmp rpool/root/tmp

    zfs mount rpool/root/gentoo
    mkdir -p /mnt/gentoo/{home,var,tmp}
    zfs mount rpool/root/home /mnt/gentoo/home
    zfs mount rpool/root/var /mnt/gentoo/var
    zfs mount rpool/root/tmp /mnt/gentoo/tmp

    mkdir -p /mnt/gentoo/boot
    mount "$EFI_PARTITION" /mnt/gentoo/boot

    success "ZFS pool and datasets mounted."
}

# --- AUTO SELECT FASTEST MIRROR ---
select_fastest_mirror() {
    log "Detecting fastest Portage mirror..."
    emerge -q app-portage/mirrorselect
    mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf 2>/dev/null || {
        warn "mirrorselect failed, using default mirror"
        echo "GENTOO_MIRRORS=\"https://distfiles.gentoo.org/\"" >> /mnt/gentoo/etc/portage/make.conf
    }
    success "Fastest mirror selected."
}

# --- STAGE3 & BINPKG SETUP ---
install_stage3_binpkg() {
    log "Downloading and extracting Stage3 with binary package support..."

    cd /mnt/gentoo
    local stage3_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-hardened.tar.xz"
    wget -q "$stage3_url" -O stage3.tar.xz
    tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
    rm stage3.tar.xz

    # Copy resolv.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    # Mount filesystems
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev

    # Configure binpkg
    mkdir -p /mnt/gentoo/etc/portage/binpkg
    cat > /mnt/gentoo/etc/portage/make.conf << 'EOF'
CFLAGS="-O2 -pipe -march=native"
CXXFLAGS="${CFLAGS}"
MAKEOPTS="-j$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc) --load-average=$(nproc) --with-bdeps=y"
ACCEPT_LICENSE="* -@EULA"
GENTOO_MIRRORS="https://distfiles.gentoo.org/"
PORTAGE_BINHOST="${BINPKG_HOST}/${BINPKG_ARCH}/${BINPKG_USE}"
PORTAGE_BINHOST_FORCE="yes"
FEATURES="getbinpkg binpkg-docompress binpkg-dostrip binpkg-logs"
EOF

    success "Stage3 installed with binary package configuration."
}

configure_chroot() {
    log "Entering chroot and configuring system..."

    chroot /mnt/gentoo /bin/bash << 'EOF'
    # Sync portage and install essentials
    emerge --sync
    emerge -q sys-apps/portage

    # Install kernel and firmware
    emerge -q sys-kernel/gentoo-sources sys-kernel/linux-firmware

    # Install bootloader tools
    emerge -q sys-boot/systemd-boot sys-apps/dracut sys-apps/efibootmgr

    # Install base utilities
    emerge -q sys-apps/util-linux sys-apps/smartmontools sys-apps/pciutils
    emerge -q net-misc/dhcpcd

    # Install sudo and basic tools
    emerge -q sys-apps/sudo

    # Install systemd or openrc (later)
EOF

    success "Base system installed via binpkg (where available)."
}

install_bootloader() {
    log "Installing systemd-boot with efistub..."

    chroot /mnt/gentoo /bin/bash << 'EOF'
    # Build kernel
    cd /usr/src/linux
    make defconfig
    make -j$(nproc)
    make modules_install
    cp arch/x86_64/boot/bzImage /boot/vmlinuz-gentoo
    cp .config /boot/config-gentoo

    # Generate initramfs (with ZFS/BTRFS support)
    emerge -q sys-apps/dracut
    dracut --force --add-drivers "efi_runtime" --no-hostonly /boot/initramfs-gentoo.img

    # Install systemd-boot
    bootctl install

    # Create boot entry
    cat > /boot/loader/entries/gentoo.conf << 'EOL'
title   Gentoo Linux
linux   /vmlinuz-gentoo
initrd  /initramfs-gentoo.img
options root=ZFS=rpool/root/gentoo rw rootflags=subvol=@ rootfstype=zfs
EOL
EOF

    # Inject correct root line based on FS type
    if [ "$FS_TYPE" = "btrfs" ]; then
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
        sed -i "s|root=ZFS=.*|root=UUID=$ROOT_UUID rw rootflags=subvol=@ rootfstype=btrfs|" /mnt/gentoo/boot/loader/entries/gentoo.conf
    elif [ "$FS_TYPE" = "zfs" ]; then
        sed -i "s|root=ZFS=.*|root=ZFS=rpool/root/gentoo rw|" /mnt/gentoo/boot/loader/entries/gentoo.conf
    fi

    success "systemd-boot installed with efistub."
}

configure_init_system() {
    log "Configuring init system: $INIT_SYSTEM..."

    chroot /mnt/gentoo /bin/bash << EOF
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        emerge -q sys-apps/systemd
        rc-update del default openrc
        rc-update add default systemd
        ln -sf /lib/systemd/systemd /sbin/init
    else
        emerge -q sys-apps/openrc
        rc-update add default openrc
    fi
EOF

    success "Init system configured: $INIT_SYSTEM"
}

configure_network() {
    log "Configuring network..."

    chroot /mnt/gentoo /bin/bash << 'EOF'
    rc-update add dhcpcd default
    echo 'hostname="gentoo"' > /etc/conf.d/hostname
EOF

    success "Network configured."
}

finalize() {
    log "Setting root password..."
    chroot /mnt/gentoo /bin/bash -c "passwd"

    log "Creating user..."
    chroot /mnt/gentoo /bin/bash -c "useradd -m -G wheel,audio,video -s /bin/bash gentoo"
    chroot /mnt/gentoo /bin/bash -c "passwd gentoo"

    log "Enabling sudo for wheel group..."
    chroot /mnt/gentoo /bin/bash -c "echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers"

    log "Unmounting filesystems..."
    umount -R /mnt/gentoo
    swapoff "$SWAP_PARTITION"

    success "Installation complete! Reboot and remove LiveCD."
}

# --- MAIN MENU ---
main_menu() {
    echo
    echo -e "${YELLOW}=== GENTOO AUTOINSTALL WITH BINPKG ===${NC}"
    echo "Choose your configuration:"
    echo
    echo "1. Init System:"
    echo "   1.1) systemd"
    echo "   1.2) openrc"
    echo
    echo "2. Root Filesystem:"
    echo "   2.1) BTRFS with subvolumes (@, @home, @var, @tmp)"
    echo "   2.2) ZFS root (rpool/root/gentoo)"
    echo
    read -p "Enter your choice (e.g., '1.1 2.1'): " CHOICE

    case $CHOICE in
        *"1.1"*)
            INIT_SYSTEM="systemd"
            ;;
        *"1.2"*)
            INIT_SYSTEM="openrc"
            ;;
        *)
            error "Invalid init system choice."
            ;;
    esac

    case $CHOICE in
        *"2.1"*)
            FS_TYPE="btrfs"
            ;;
        *"2.2"*)
            FS_TYPE="zfs"
            ;;
        *)
            error "Invalid filesystem choice."
            ;;
    esac

    log "Selected: Init=$INIT_SYSTEM, FS=$FS_TYPE"
    log "Using binary packages from: $BINPKG_HOST"
}

# --- MAIN ---
main() {
    check_root
    check_disk

    main_menu

    partition_disk

    if [ "$FS_TYPE" = "btrfs" ]; then
        setup_btrfs
    elif [ "$FS_TYPE" = "zfs" ]; then
        setup_zfs
    fi

    install_stage3_binpkg

    select_fastest_mirror

    configure_chroot

    install_bootloader

    configure_init_system

    configure_network

    finalize
}

main