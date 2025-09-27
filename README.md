✅ ФУНКЦИИ:
Автоматический выбор зеркала (mirrorselect) — выбирает лучшее зеркало по скорости.
Установка из бинарных пакетов (binpkg) — использует binpkg с PORTAGE_BINHOST для максимальной скорости установки (идеально для медленных соединений или быстрой развёртывания).

🛠️ Требования

1. **LiveCD Gentoo** (желательно `hardened` или `stage3` с `systemd`/`openrc`)
2. **Интернет** — нужен для скачивания stage3 и бинарников
3. **UEFI** — обязательно для `systemd-boot`
4. **ZFS** — если выбираете ZFS, убедитесь, что `sys-fs/zfs` доступен в chroot (если LiveCD без ZFS — установите его вручную до запуска скрипта):

```bash
emerge -q sys-fs/zfs
modprobe zfs

✅ Как использовать

```bash
wget https://example.com/gentoo-autoinstall-binpkg.sh
chmod +x gentoo-autoinstall-binpkg.sh
./gentoo-autoinstall-binpkg.sh
```

> 🔗 **Ссылка на бинарники**: https://binpkg.gentoo.org — официальный репозиторий Gentoo, обновляется ежедневно.

---

### 📌 Дополнительно: как проверить, что бинарники используются?

Внутри chroot:

```bash
emerge --pretend sys-apps/sudo
```

Если видите:
```
[binary   R ] sys-apps/sudo-1.9.13_p1
```
→ **Успешно!** Пакет скачивается как бинарник.
