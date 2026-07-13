# Bitácora de avances — Migración a HuronOS 100% netboot

Registro cronológico del trabajo de reemplazar Ubuntu/casper por HuronOS arrancando enteramente vía iPXE (sin USB física), para uso eventual en el laboratorio real de exámenes de la ICMP/OMI.

## Objetivo

Que las PCs del laboratorio arranquen HuronOS completo (incluyendo el escritorio Budgie) directamente por red, sin instalar una memoria USB por equipo, usando la infraestructura iPXE ya existente en este proyecto (dnsmasq + nginx + QEMU).

## Estado actual (2026-07-13)

**Logrado:** arranque de HuronOS 100% por red hasta el escritorio gráfico completo, en la VM esclava simulada con QEMU, con red funcionando automáticamente dentro del escritorio (DHCP vía `connman`, salida a internet real vía NAT en el host), **`directives.hdf` detectándose y aplicándose automáticamente** (allowlist de sitios, USB, wallpaper, horarios Event/Contest, software bajo demanda), **y también el trabajo de `event`/`contest` persistiendo entre sesiones vía sync con el master** (`hnetsync`). Ver intentos 9-12. Probado con un horario de `Contest` real (no fechas de ejemplo ya pasadas): cambio de modo, bloqueo de USB, allowlist estricto, y sobrevivencia de archivos del usuario tras apagar/prender la VM, todo verificado en vivo.

**Y ahora, además: primer piloto en hardware real** (Raspberry Pi + MikroTik hEX lite + laptop física) arrancando por PXE de punta a punta, con `directives.hdf` en modo `Event` aplicándose y el software (`vscode`/`pycharm`/`chromium`, etc.) cargando correctamente. Ver intento 13.

**Pendiente:** optimizar el tiempo de arranque (~2:30 min hoy), probar `Event` con horario vigente en la simulación QEMU (ya validado en hardware real), y verificar `hnetsync` (persistencia) en la laptop física. Ver "Próximos pasos".

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

### 12. `hnetsync`: sync de `event`/`contest` con el master (2026-07-11/12)

`libhpersistence.so` (HuronOS original, sin modificar) espera particiones físicas `event`/`contest` para persistir el trabajo del contestant entre encendidos. En netboot, `huronos-patch/livekitlib` las monta como `tmpfs` (RAM), así que todo se perdía al apagar la VM. Se implementó un mecanismo de sync con el master:

- **Master**: `master/sync-server.py` (stdlib puro, `127.0.0.1:8081`) — `PUT`/`GET /sync/<machine-id>/<disk>.tar.gz`, con `machine-id`/`disk` validados por regex. Expuesto en el puerto 80 vía `location /sync/` en `nginx.conf` (proxy a loopback) para quedar dentro del allowlist de firewall que aplican las directivas (`libhfirewall.so` solo permite `INPUT` de vuelta en sport 80/443/8080). Persistencia real en `sync-data/` (volumen Docker).
- **Guardar (push)**: `huronos-patch/hnetsync/usr/local/sbin/hnetsync-push`, enganchado vía *drop-ins* systemd (`hsync.service.d/`, `happly.service.d/`, más un `hnetsync-push-shutdown.service` para el apagado) — cero ediciones a archivos originales de HuronOS.
- **Restaurar (pull)**: vive en el **initrd**, dentro de `persistent_changes()` (`huronos-patch/livekitlib`), justo después de montar los `tmpfs` de `event`/`contest`.
- **Identidad de máquina**: MAC de la interfaz de red (se detectó que `04-start-slave1.sh`/`04-start-slave2.sh` no fijaban `mac=`, así que QEMU les daba la misma por defecto — corregido con `52:54:00:12:34:01`/`:02`).

**Tres bugs reales encontrados en la verificación en vivo (ninguno se ve con solo leer el código):**

1. **La ventana de 60s de `system_has_just_booted()`** (`libhsystem.so`, sin modificar): decide "¿acabo de arrancar?" mirando `/proc/uptime < 60s`. El primer diseño ponía el `pull` en un `.service` systemd que esperaba a `network-online.target` antes de que `hsync.service` corriera — eso empujaba la primera ejecución de `hsync.service` más allá de los 60s, HuronOS lo trataba como arranque rutinario (no el primero), se saltaba `restore_state_from_disk()`/`start_persistence()` por completo, encontraba `STATE_MODE=none`, y por seguridad reconstruía todo desde cero en modo `always` — **borrando en cascada, vía `start_always_mode()`/`always_to_contest()`, lo que se acababa de restaurar.** Mover el `pull` al initrd (antes de que systemd empiece a contar) evita competir por esa ventana.
2. **La ventana de 60s en sí es poco realista en este netboot**: el arranque completo (kernel + initrd + descarga HTTP + descompresión del squashfs) ya tarda bastante más de 60s por sí solo, con o sin el pull. Corrección: capa aditiva `07-hnetsync.hsl` con una copia parchada de `/usr/lib/hsync/libhsystem.so` (mismo patrón que `huronos-patch/hmm`) — `system_has_just_booted()` usa un marcador de una sola vez por arranque (`/run/hsync/netboot-first-run-done`) en vez de `/proc/uptime`, **solo si `netboot=true`**; el camino físico (USB) queda byte-idéntico al original.
3. **`tar -z` no soportado por el busybox de este initrd** (v1.26.2): aunque `gzip`/`gunzip`/`tar` existen como applets separados, la combinación `tar xzf` fallaba con `tar: invalid option -- z` (silenciosamente, el script no revisaba el código de salida). Corrección: `gzip -dc archivo.tar.gz | tar x -C DIR -f -`.

Se agregó además un log propio (`/var/log/hnetsync-initrd.log`, escrito directamente en `$SYSCHANGES` para sobrevivir al `pivot_root`) — fue indispensable para diagnosticar el bug #3, ya que `journalctl`/`dmesg` no capturan la salida de consola del initrd.

**Verificado en vivo, extremo a extremo:** con `directives.hdf` apuntando a una ventana de `Contest` real (no fechas de ejemplo ya pasadas), la VM cambió correctamente a modo `contest` (allowlist estricto, USB bloqueado, software de la lista de Contest activado), un archivo creado por el usuario sobrevivió un apagado+encendido completo de la VM, y `restore_state_from_disk` reportó "preserving changes" (sin transición destructiva) en el segundo arranque.

### 13. Piloto en hardware real: Raspberry Pi + MikroTik hEX lite + laptop física (2026-07-13)

Primer despliegue fuera de la simulación QEMU: RPi como master (dnsmasq+nginx+sync-server, igual que en `master/`), un MikroTik hEX lite como router/switch dedicado del segmento de examen (aislado del modem/ISP, igual rol que cumplía `br-ipxe` en la simulación), y la laptop del usuario como primera PC cliente física. Todo lo específico de hardware real vive en `experimento_hardware_real/` (ver `LABORATORIO-REAL.md`), sin tocar `master/`, `docker-compose.yml` ni `boot/boot.ipxe` de la raíz.

**Red de la RPi (Ubuntu, NetworkManager+netplan+cloud-init):**
- La RPi administra dos interfaces: `wlan0` (WiFi de casa, para SSH/administración) y `eth0` (segmento aislado del MikroTik, IP estática `192.168.2.2/24`). El `nmcli connection modify`/`up` sobre `eth0` no pisó la sesión SSH por `wlan0`.
- Bug encontrado: `/etc/netplan/50-cloud-init.yaml` (generado por cloud-init en cada boot) competía con el perfil de NetworkManager, dejando una IP secundaria fantasma (`192.168.2.10`) además de la correcta. Corrección: `network: {config: disabled}` en `/etc/cloud/cloud.cfg.d/`, para que cloud-init deje de regenerar netplan.
- Bug encontrado: el archivo netplan generado por NetworkManager (`90-NM-*.yaml`) terminó con `gateway4:` (sintaxis vieja) **y** `routes:` (sintaxis nueva) para la misma interfaz al mismo tiempo — `netplan apply` colgado con "Conflicting default route declarations". Corrección: eliminar la línea `gateway4:` a mano, dejando solo `routes:`.

**MikroTik:** llegó preconfigurado de una prueba anterior (bridge `bridge-lan` en `ether2-5`, IP `192.168.2.1/24`, NAT masquerade `ether1`→internet, DHCP client en `ether1`) — se reusó tal cual, solo hacía falta confirmar que su DHCP server propio (`dhcp-lan`) estuviera apagado para no competir con el `dnsmasq` de la RPi (ya lo estaba).

**Bug encontrado — `ufw` bloqueando DHCP/HTTP silenciosamente:** la RPi traía `ufw` activo (`deny` por defecto) de una configuración anterior, con reglas para SSH/NBD/NFS pero **sin** `67/udp` (DHCP) ni `80/tcp` (HTTP). `tcpdump` mostraba los paquetes DHCP de la laptop llegando bien a `eth0`, pero `dnsmasq` nunca los veía en su propio log — la firma clásica de un firewall descartando tráfico por debajo de la capa de aplicación. Corrección: `ufw allow in on eth0 to any port 67 proto udp` + `... port 80 proto tcp`, **acotado a `eth0`** (no expuesto en `wlan0`, la red de casa).

**Bug encontrado — firmware PXE de fábrica no es iPXE (a diferencia de QEMU):** con el firewall corregido, el DHCP normal del sistema operativo de la laptop funcionaba, pero el PXE de la laptop (`PXEClient:Arch:00007:UNDI:003016`, UEFI x86-64 real) se quedaba en "Start PXE over IPv4" sin avanzar. Causa: a diferencia de la ROM `pxe-e1000.rom` de QEMU (que ya es un binario iPXE desde el primer DHCP request), el firmware UEFI de fábrica de una PC física no es iPXE en su primer request, así que no puede consumir directamente el script HTTP `boot.ipxe` — dnsmasq solo tenía configurada la regla `dhcp-boot` para clientes que ya mandan la opción 175 (exclusiva de iPXE).

Corrección: chainload en dos pasos vía TFTP. Se descargó `snponly.efi` (binario iPXE oficial, `http://boot.ipxe.org/x86_64-efi/snponly.efi`, usa el driver SNP del propio firmware UEFI para máxima compatibilidad con NICs desconocidas) a `experimento_hardware_real/tftpboot/`, se habilitó `enable-tftp`/`tftp-root=/var/ftpd` en `dnsmasq.conf`, y se agregó una regla `dhcp-match=set:efi64,60,PXEClient:Arch:00007` + `dhcp-boot=tag:efi64,tag:!ipxe,snponly.efi` — así el firmware de fábrica primero recibe `snponly.efi` por TFTP, ese binario repite el DHCP request ya como iPXE (con la opción 175), y ahí sí cae en la regla existente hacia `boot.ipxe` por HTTP. Documentado en `LABORATORIO-REAL.md` §6.1.

**Resultado:** arranque PXE completo de la laptop hasta el escritorio Budgie, `directives.hdf` (`[Event]`, ventana 2026-07-13T10:00 a 2026-07-16T23:59:59) aplicándose y el software de la directiva activa (`vscode`, `pycharm`, `chromium`, etc.) abriendo correctamente — confirmado en vivo por el usuario. Sin poder verificar todavía el allowlist de sitios (el lab de prueba no tenía salida a internet en ese momento) ni `hnetsync` (persistencia) con la MAC real de la laptop — ver "Próximos pasos".

## Próximos pasos

1. Evaluar y optimizar el tiempo de arranque (~2:30 min hoy).
2. Repetir la prueba de horario vigente en modo `Event` **en la simulación QEMU** (ya se probó a fondo `Contest` en QEMU, ver intento 12; `Event` ya se validó en hardware real, ver intento 13).
3. Fijar MACs distintas para más de 2 VMs si se agregan más `slaveN` al laboratorio simulado (hoy solo `slave1`/`slave2` tienen `mac=` fija).
4. Verificar `hnetsync` (persistencia `event`/`contest`) en la laptop física del piloto de hardware real — confirmar que `sync-data/<mac-de-la-laptop>/event.tar.gz` aparece en la RPi tras un ciclo de `hsync`.
5. Verificar el allowlist de sitios (`AllowedWebsites`) del piloto de hardware real en un lab con salida a internet.
6. Escalar el piloto de hardware real a más PCs físicas (`ether3`/`ether4`/`ether5` del MikroTik).

## Referencias

- Repo oficial de build de HuronOS: https://github.com/equetzal/huronOS-build-tools
- Directivas de ejemplo: https://raw.githubusercontent.com/Orlanstein/huronos_directives/refs/heads/main/directives.hdf
- Ver `README.md` de este proyecto para la arquitectura final y cómo levantar el entorno.
