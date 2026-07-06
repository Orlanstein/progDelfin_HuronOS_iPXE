# Bitácora de avances — Migración a HuronOS 100% netboot

Registro cronológico del trabajo de reemplazar Ubuntu/casper por HuronOS arrancando enteramente vía iPXE (sin USB física), para uso eventual en el laboratorio real de exámenes de la ICMP/OMI.

## Objetivo

Que las PCs del laboratorio arranquen HuronOS completo (incluyendo el escritorio Budgie) directamente por red, sin instalar una memoria USB por equipo, usando la infraestructura iPXE ya existente en este proyecto (dnsmasq + nginx + QEMU).

## Estado actual (2026-07-06)

**Logrado:** arranque de HuronOS 100% por red hasta el escritorio gráfico completo, en la VM esclava simulada con QEMU, con red funcionando automáticamente dentro del escritorio (DHCP vía `connman`, salida a internet real vía NAT en el host), **y con `directives.hdf` detectándose y aplicándose automáticamente** — allowlist de sitios (firewall), USB, wallpaper, horarios Event/Contest, y software (IDEs/compiladores) descargado bajo demanda. Ver intentos 9-11.

**Pendiente:** implementar el sync de `event`/`contest` (hoy en RAM) contra el master, para persistencia entre sesiones de examen (Fase 3). Ver "Próximos pasos".

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

**Pendiente detectado en ese momento:** dentro del escritorio, la red no parecía configurarse como en un arranque real desde USB. Sospecha inicial: `connman` no levantaba la interfaz `e1000` automáticamente, o el sistema completo (capas `huronOS/base/*.hsl`) no incluía `e1000.ko` en su propio árbol de módulos (independiente del que se armó a mano para el `initrd`). Ver intento 9 — esta sospecha resultó incorrecta.

### 9. Diagnóstico de red post-boot: no era un bug (2026-07-06)

Investigación estática de `huronOS/base/01-core.hsl` (la capa del sistema completo, no el initrd): `e1000.ko`/`e1000e.ko` **sí** están presentes en `/usr/lib/modules/6.0.15-huronos+/kernel/drivers/net/ethernet/intel/`, con sus alias PCI correctos en `modules.alias`, y `connman.service` está habilitado (systemd + sysvinit). También se confirmó, leyendo `change_root()` en `lib/livekitlib` del initrd, que `pivot_root`/`chroot` no matan el `udhcpc` que el propio `init` lanza para descargar `huronos-system.sfs` — hipótesis: ese proceso residual podía interferir con `connman` al arrancar el sistema completo.

Se arrancó con `debug` agregado a `huronos.flags` para diagnosticar en vivo. En el escritorio ya cargado (usuario `contestant`):

- `ip addr show`: `eth0` con IP DHCP real (`192.168.100.157/24`), ruta default correcta.
- `ps aux | grep udhcp`: **ningún proceso vivo** — la hipótesis del `udhcpc` colgado era incorrecta.
- `systemctl status connman`: `active (running)`.
- `connmanctl technologies`: `Wired`, `Powered=True`, `Connected=True`.
- `connmanctl services`: `*AR Wired` (Ready, no Online — esperado, ya que este laboratorio no tiene salida a internet real desde el master, así que el chequeo `EnableOnlineCheck` de `connman` nunca puede completarse).
- `ping -c 3 192.168.100.1`: 0% de pérdida, ~0.2-0.8ms.
- `curl -I http://192.168.100.1/boot.ipxe`: `200 OK`.

**Conclusión:** la red dentro del escritorio ya funciona automáticamente de punta a punta. El problema reportado anteriormente ya no está presente — probablemente se observó en un boot anterior al fix de RAM-copy (intento 7), o antes de que el arranque terminara de asentarse (~2:30 min). No se aplicó ningún cambio de código; no hacía falta.

### 10. Salida a internet real desde las VMs

`br-ipxe` era una red completamente aislada (dnsmasq + nginx, sin NAT), así que aunque la conectividad al master funcionaba, no había salida a internet real (`ping 8.8.8.8`/`curl wikipedia.com` se quedaban colgados). Corrección en `scripts/01-setup-network.sh`: detecta automáticamente la interfaz con ruta default del host y agrega `iptables` `MASQUERADE` + `FORWARD` (idempotente, con limpieza correspondiente en `scripts/99-teardown.sh`).

### 11. `directives.hdf`: detección, allowlist, USB, horarios y software (2026-07-06)

Se descubrió que HuronOS **ya trae, dentro de `huronOS/base/01-core.hsl`, el mecanismo completo de directivas** — nunca antes visto porque vive fuera de `install.sh`/`init`:

- `hsync.timer` (habilitado, cada 60s) dispara `hsync.service` → `/usr/lib/hsync/hsync.sh --routine-sync`, que lee `huronOS/data/configs/sync-server.conf` (mismo formato que genera `install.sh`), descarga `directives.hdf` por `wget`, y si cambió, aplica timezone, teclado, wallpaper, bookmarks, y decide el modo activo (`always`/`event`/`contest`) según `[Event-Times]`/`[Contest-Times]`.
- El firewall/allowlist (`libhfirewall.so`) resuelve por DNS cada dominio de `AllowedWebsites` y arma reglas `iptables` (DROP de entrada + allowlist de esas IPs en los puertos 80/443/8080).
- El software (`AvailableSoftware`) se activa vía `/usr/sbin/hmm` ("huronOS Module Manager"): monta cada `.hsm` de `huronOS/software/<categoría>/<nombre>.hsm` por loop + lo agrega a la unión AUFS.
- Sin `sync-server.conf` (nuestro caso hasta ahora), `hsync.sh` caía a `/etc/hsync/default` (`AllowedWebsites=all`) — por eso ya había internet libre antes de este cambio.

Implementación (sin tocar ningún archivo original de HuronOS más de lo estrictamente necesario):

- `directives/directives.hdf`: el ejemplo del usuario, versionado en git (a diferencia de `boot/`).
- `boot/boot.ipxe`: nuevos flags `directives.url`, `directives.server`, `software.url`.
- `huronos-patch/livekitlib` (`find_data_netboot()`): sintetiza `sync-server.conf` a partir de esos flags, ya que el netboot nunca corre `install.sh`.
- `huronos-patch/hmm`: copia parchada de `/usr/sbin/hmm` — si `netboot=true` y el `.hsm` pedido no existe localmente, lo descarga del master antes de montarlo. Empaquetada como capa aditiva `06-netboot-hmm.hsl` (via `scripts/02c-build-hmm-layer.sh`), que se apila por encima de `01-core.hsl` en la unión AUFS gracias a que `union_append_modules()` ya recorre `huronOS/base/*.hsl` en orden alfabético — cero cambios a HuronOS, cero riesgo de reintroducir el bug de los 4 GiB (cada `.hsm` se sirve suelto desde `boot/software/`, nunca en un bundle único).
- `scripts/02b-setup-directives.sh`: publica `directives.hdf` y extrae el catálogo `.hsm` completo de la ISO a `boot/software/`.

**Dos bugs encontrados y corregidos durante la verificación:**
- `readlink -f` exige que todos los directorios padre de la ruta ya existan; como `huronOS/software/<categoría>/` no existe hasta que se descarga algo ahí, `MODULE_PATH` se resolvía a `""` antes de que el parche pudiera actuar. Corrección: crear el directorio padre y descargar contra la ruta cruda (`$1`) antes de llamar a `readlink -f`.
- `cp -a` desde la ISO preservaba permisos root-only, y `nginx` corre como `www-data` dentro del contenedor → 404 al pedir un `.hsm`. Corrección: `chmod -R a+rX` sobre `boot/software/` en `02b-setup-directives.sh`.

Verificado en VM: `directives.hdf` real descargado (no el default), `iptables -L INPUT` con el allowlist resuelto, `hmm --list-modules` mostrando los 10 módulos de `[Always]` montados, y `which gcc chromium` resolviendo binarios reales — sin haber descargado nunca los módulos pesados no solicitados (rider, clion, etc.).

## Próximos pasos

1. Implementar el servicio de sync de `event`/`contest` (hoy en RAM) hacia el master, para persistencia real entre sesiones de examen (Fase 3).
2. Evaluar y optimizar el tiempo de arranque (~2:30 min hoy).
3. Probar el modo `event`/`contest` con horarios vigentes (el `directives.hdf` de ejemplo trae fechas de junio 2026, ya pasadas) para verificar el cambio de modo y el bloqueo de USB en `Contest`.

## Referencias

- Repo oficial de build de HuronOS: https://github.com/equetzal/huronOS-build-tools
- Directivas de ejemplo: https://raw.githubusercontent.com/Orlanstein/huronos_directives/refs/heads/main/directives.hdf
- Ver `README.md` de este proyecto para la arquitectura final y cómo levantar el entorno.
