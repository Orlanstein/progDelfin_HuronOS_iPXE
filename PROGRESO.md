# Bitácora de avances — Migración a HuronOS 100% netboot

Registro cronológico del trabajo de reemplazar Ubuntu/casper por HuronOS arrancando enteramente vía iPXE (sin USB física), para uso eventual en el laboratorio real de exámenes de la ICMP/OMI.

## Objetivo

Que las PCs del laboratorio arranquen HuronOS completo (incluyendo el escritorio Budgie) directamente por red, sin instalar una memoria USB por equipo, usando la infraestructura iPXE ya existente en este proyecto (dnsmasq + nginx + QEMU).

## Estado actual (2026-07-01)

**Logrado:** arranque de HuronOS 100% por red hasta el escritorio gráfico completo, en la VM esclava simulada con QEMU.

**Pendiente:** una vez dentro del escritorio, la red no queda configurada como en un arranque real desde USB (no hay conectividad, no se sincronizan `directives.hdf`). Ver "Próximos pasos".

## Bitácora de intentos

### 1. Parche de red en el `initrd` (descartado)

Primer intento: parchear `init`/`lib/livekitlib` del `initrfs.img` de la ISO tal cual venía, para que `find_data()` descargara los datos del sistema por HTTP (reutilizando `mount_data_http()`, código heredado de Slax que HuronOS nunca usaba). Se probó en QEMU real y **falló de forma irrecuperable**: el kernel `6.0.15-huronos+` que trae la ISO no tiene **ningún** driver de red compilado, ni built-in ni como módulo.

### 2. SAN boot — `sanboot http://` y `sanboot iscsi://` (descartado)

Se intentó rodear el problema de red haciendo que la "USB" fuera un disco de red (servido por HTTP, y luego por iSCSI vía `tgt`), de forma que el arranque BIOS/MBR/extlinux ocurriera igual que en una USB física sin depender de que el kernel de HuronOS tuviera red. Ambos fallaron por la misma razón de fondo: `sanboot` engancha llamadas BIOS INT13 solo hasta que el bootloader entrega el control al kernel; un SO moderno necesita su **propio** driver de red para sostener la sesión SAN después de eso. Sin driver de red, no hay forma de que la conexión sobreviva más allá del bootloader.

### 3. Hallazgo clave: `huronOS-build-tools` (github.com/equetzal/huronOS-build-tools)

Se revisó el repositorio oficial de build de HuronOS (compartido por el usuario) y se encontró la causa real:

- `builder-scripts/kernel/huronos.config` **sí** compila `CONFIG_E1000=m`, `CONFIG_E1000E=m`, `CONFIG_VIRTIO_NET=m` — el kernel sí soporta red.
- `base-system/initramfs/initramfs_create` solo copia esos drivers al initrd si `$NETWORK = "true"`.
- `base-system/config` trae `export NETWORK=false` por defecto — la ISO se genera para USB únicamente, sin red, adrede.

Es un interruptor de build, no una limitación del kernel.

### 4. Recompilación del kernel con `NETWORK=true` (funcionó)

Se recompiló el kernel de HuronOS (mismo `huronos.config`, mismos parches AUFS, mismo `build-kernel.sh` oficial) dentro de un contenedor `debian:bullseye`, y se reconstruyó el `initrd` con `NETWORK=true`, agregando el parche local `huronos-patch/livekitlib`:

- `find_data()`: si `huronos.flags` trae `netboot=true`, usa `find_data_netboot()` (descarga por HTTP) en vez de buscar UUID físico.
- `persistent_changes()`: si `netboot=true`, monta `event`/`contest` como `tmpfs` en vez de buscar particiones físicas.

Con esto, el arranque llegó por primera vez hasta el prompt de login (`huronOS login:`) — red, descarga del sistema y ensamblado del union AUFS funcionando.

Automatizado en `scripts/00-build-kernel.sh` (compila) + `scripts/02-build-huronos-boot.sh` (empaqueta).

### 5. Login exitoso, pero sin escritorio gráfico

Con `root`/`toor` se pudo iniciar sesión en consola. `lightdm.service` fallaba con `203/EXEC`. Se investigó si HuronOS depende de un `kexec` a un segundo kernel Debian (`5.10.0-23-amd64`, cuyos módulos aparecen en la capa `01-core.hsl`) para tener gráficos/red completos — se descartó: `systemd-kexec.service`/`kexec.target` están inactivos/disabled por defecto, es solo un mecanismo opcional de reboot rápido (`quick-reboot`), no algo que ocurra automáticamente.

### 6. El bug de los 4 GiB

`journalctl` mostraba `SQUASHFS error: Unable to read fragment/page` repetido, siempre en el mismo bloque. Causa encontrada: `huronos-system.sfs` pesaba **4.976 GiB** (justo arriba de la barrera de 4 GiB), y `mount.httpfs2` (el binario que HuronOS usa para montar el archivo remoto vía FUSE) es **ELF de 32 bits** — al leer cerca del final del archivo (donde squashfs guarda su tabla de fragmentos), el offset se truncaba.

Corrección: `02-build-huronos-boot.sh` ahora arma `huronos-system.sfs` solo con `huronOS/base` + `huronOS/data` + `boot` + `EFI` + `checksums` (sin `huronOS/software/`, el grueso del tamaño), dejando el bundle en ~1.1 GiB.

### 7. El bug del "loop sobre loop sobre FUSE"

El error de SQUASHFS **persistió** incluso con el bundle más chico (mismo bloque exacto). Se confirmó que el archivo `03-budgie.hsl` de la ISO original **no está corrupto** (se extrajo sin errores directamente en el host). La causa real: `huronos-system.sfs` se monta vía `loop` sobre un archivo expuesto por FUSE (`httpfs2`), y luego cada `.hsl` (`03-budgie.hsl`, etc.) se vuelve a montar por `loop` **encima de eso** — un apilamiento "loop sobre loop sobre FUSE" que el kernel maneja de forma poco confiable para las lecturas anidadas que hace `mount_modules()`.

Corrección (en `huronos-patch/livekitlib`, dentro de `find_data_netboot()`): apenas se confirma que los datos del sistema llegaron, se copian a una segunda tmpfs (`/memory/system-ramcopy`) y se desmonta la pila `loop+FUSE`, dejando `$SYSTEM_MNT` apuntando (via bind mount) a la copia en RAM. Todo lo que sigue (`mount_modules()`, etc.) opera sobre archivos normales en tmpfs, sin FUSE de por medio.

### 8. Arranque completo hasta el escritorio (2026-07-01)

Con el fix de RAM-copy aplicado, el arranque tardó ~2:30 min (copiar ~1.1 GiB a RAM vía `httpfs2` sin caché) pero **llegó al escritorio Budgie completo**, con autologin de `contestant` funcionando.

**Pendiente detectado:** dentro del escritorio, la red no se configura como en un arranque real desde USB — no hay conectividad, no se sincronizan directivas. Sospecha: `connman` (el gestor de red de HuronOS) no está levantando la interfaz `e1000` automáticamente en este entorno, o el sistema completo (capas `huronOS/base/*.hsl`) no incluye `e1000.ko` en su propio árbol de módulos (independiente del que se armó a mano para el `initrd`).

## Próximos pasos

1. Diagnosticar por qué `connman` no configura la red dentro del escritorio ya arrancado (¿falta `e1000.ko` en los módulos del sistema completo? ¿`connman` no tiene una regla para traer la interfaz automáticamente en este entorno virtual?).
2. Una vez con red en el escritorio: implementar el sync de `directives.hdf` contra el master (fuera de alcance hasta ahora).
3. Implementar el servicio de sync de `event`/`contest` (hoy en RAM) hacia el master, para persistencia real entre sesiones de examen.
4. Evaluar y optimizar el tiempo de arranque (~2:30 min hoy).

## Referencias

- Repo oficial de build de HuronOS: https://github.com/equetzal/huronOS-build-tools
- Directivas de ejemplo: https://raw.githubusercontent.com/Orlanstein/huronos_directives/refs/heads/main/directives.hdf
- Ver `README.md` de este proyecto para la arquitectura final y cómo levantar el entorno.
