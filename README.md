# Simulación iPXE con QEMU — Proyecto Delfín

Entorno de simulación de red iPXE con una PC master (servidor) y dos PCs esclavas que arrancan por red. Diseñado para probar el arranque 100% por red de **HuronOS** (la distro oficial de la ICMP México y la Olimpiada Mexicana de Informática) antes de desplegarlo en un laboratorio real, sin depender de una memoria USB por equipo.

## Por qué esto no es un simple cambio de ISO

HuronOS normalmente solo arranca desde una memoria USB instalada con `install.sh`: su `init` (heredado del proyecto Slax, con AUFS) busca los datos del sistema mediante `blkid`, exigiendo un **dispositivo de bloques físico** cuyo UUID coincida con `huronos.flags=(system.uuid=...;event.uuid=...;contest.uuid=...)`.

### Investigación: tres intentos hasta encontrar la causa real

1. **Parchear `init`/`lib/livekitlib` para descargar por HTTP** (`mount_data_http()`, código heredado de Slax, nunca usado por HuronOS). Falló en QEMU real: el kernel `6.0.15-huronos+` que trae la ISO **no tiene ningún driver de red compilado, ni built-in ni como módulo**.
2. **SAN boot** (`sanboot http://` y luego `sanboot iscsi://`, sirviendo un disco virtual con las 3 particiones reales). Ambos fallaron por la misma razón de fondo: `sanboot` funciona enganchando llamadas BIOS INT13 solo hasta que el bootloader entrega el control al kernel; a partir de ahí, un SO moderno necesita su **propio driver de red** para sostener la sesión de red (así es como Windows/Linux hacen boot real por iSCSI en producción). Sin driver de red en el kernel, no hay forma de que la conexión sobreviva.
3. **Revisar el repositorio oficial de build de HuronOS** (`huronOS-build-tools`, github.com/equetzal/huronOS-build-tools): ahí se encontró la causa real. `builder-scripts/kernel/huronos.config` **sí** compila `CONFIG_E1000=m`, `CONFIG_E1000E=m`, `CONFIG_VIRTIO_NET=m` — el kernel sí soporta red. Pero `base-system/initramfs/initramfs_create` solo copia esos drivers al initrd si `$NETWORK = "true"`, y `base-system/config` trae `export NETWORK=false` por defecto (la ISO se genera para USB, sin red, adrede). Es un interruptor de build, no una limitación del kernel.

### La solución final: recompilar el kernel con `NETWORK=true`

Este proyecto recompila el kernel de HuronOS (mismo `huronos.config`, mismos parches AUFS, mismo proceso reproducible `build-kernel.sh` del repo oficial) y reconstruye el initrd con `NETWORK=true`, agregando además un parche propio y mínimo a `lib/livekitlib` (`huronos-patch/livekitlib`) que conecta el código de descarga HTTP que HuronOS ya traía pero nunca usaba. El camino físico-USB original (`install.sh`, hardware real) **no se modifica en absoluto** — el parche solo actúa cuando el kernel recibe `huronos.flags=(netboot=true;...)`.

### El bug de los 4 GiB

Con la red ya funcionando, el arranque llegaba hasta el prompt de login pero `lightdm` fallaba con `203/EXEC` y el kernel reportaba `SQUASHFS error: Unable to read fragment/page` — siempre en el mismo bloque, en cada intento. Eso descarta una falla de red intermitente: es corrupción determinista. La causa: `huronos-system.sfs` pesaba **4.976 GiB** (justo arriba de la barrera de 4 GiB / 2^32 bytes), y `mount.httpfs2` — el binario que HuronOS usa para montar el archivo remoto via FUSE — es **ELF de 32 bits**. Al pedir rangos de bytes cerca del final del archivo (donde squashfs guarda su tabla de fragmentos), el offset se trunca/desborda y se lee el rango equivocado.

La corrección: `huronos-system.sfs` ya no empaqueta la ISO completa, solo `huronOS/base` + `huronOS/data` + `boot` + `EFI` + `checksums` — lo mínimo para que `find_data_netboot()` encuentre el sistema base y arranque. Eso deja el bundle en ~1.2 GiB, muy por debajo de la barrera de 4 GiB. Se excluye deliberadamente `huronOS/software/` (los módulos de IDEs/lenguajes/navegadores, el grueso del tamaño): no hacen falta para arrancar, y agregarlos de vuelta requeriría resolver primero el límite de 32 bits de `httpfs2` (ver "Trabajo futuro").

## Arquitectura

```
HOST LINUX (192.168.100.1 en br-ipxe)
│
├── Docker "ipxe-master"  (--network=host)
│   ├── dnsmasq  ─── DHCP  → asigna IPs al rango .100-.200
│   │               ─── iPXE → entrega URL del script de arranque
│   ├── nginx    ─── HTTP :80
│   │                 /boot.ipxe             ← script iPXE
│   │                 /vmlinuz-*-huronos+    ← kernel recompilado (con e1000/e1000e)
│   │                 /initrfs.img           ← initrd recompilado (NETWORK=true + parche netboot)
│   │                 /huronos-system.sfs    ← bundle del sistema completo (squashfs de la ISO)
│   │                 /directives.hdf        ← directivas del examen (allowlist, USB, software, horarios)
│   │                 /software/*.hsm        ← catálogo de IDEs/compiladores, servidos sueltos
│   │                 /sync/<mac>/*.tar.gz   ← proxy a sync-server.py (persistencia event/contest)
│   └── sync-server.py (127.0.0.1:8081) ─── PUT/GET del respaldo event/contest por MAC
│                     → sync-data/<mac>/{event,contest}.tar.gz (volumen persistente en el host)
│
├── NAT (iptables MASQUERADE br-ipxe → interfaz con internet del host)
│
├── tap0 ──► QEMU slave1  (KVM, 6 GB RAM, SDL, mac=52:54:00:12:34:01)
└── tap1 ──► QEMU slave2  (KVM, 6 GB RAM, SDL, mac=52:54:00:12:34:02)
```

### Cadena de arranque completa

```
1. QEMU arranca      →  ROM iPXE (pxe-e1000.rom)
2. iPXE              →  DHCP a 192.168.100.1
3. dnsmasq           →  responde: IP + filename=http://192.168.100.1/boot.ipxe
4. iPXE              →  descarga boot.ipxe por HTTP
5. boot.ipxe         →  descarga vmlinuz-*-huronos+ + initrfs.img (recompilados) por HTTP
6. kernel            →  arranca con huronos.flags=(netboot=true;system.url=...)
7. init (parcheado)  →  find_data() detecta netboot=true → find_data_netboot()
8. find_data_netboot →  modprobe e1000 (¡ahora sí existe!), DHCP, mount_data_http() monta
                        huronos-system.sfs via httpfs2 (FUSE) + loop
9. init              →  ensambla el union AUFS con las capas de huronOS/base/*.hsl
                        (incluye 06-netboot-hmm.hsl y 07-hnetsync.hsl, ver más abajo)
10. init              →  event/contest montados como tmpfs (RAM), luego persistent_changes()
                        restaura el último respaldo de esta MAC desde /sync/ en el master
                        (hnetsync-pull, corre aquí y no después vía systemd — ver PROGRESO.md,
                        intento 12, sobre la ventana de 60s de system_has_just_booted())
11. Sistema           →  HuronOS listo, pivot_root + chroot a systemd
12. systemd           →  hsync.timer (ya viene habilitado en HuronOS) descarga
                        directives.hdf del master y aplica allowlist/USB/software/horarios;
                        al terminar cada ciclo, hnetsync-push sube event/contest al master
                        (drop-in sobre hsync.service/happly.service, más un service al apagar)
```

---

## Requisitos

| Herramienta | Versión mínima | Notas |
|---|---|---|
| QEMU | 8.x | `qemu-system-x86_64` |
| Docker + Compose | 29.x | Para el contenedor master y para compilar el kernel |
| `ipxe-qemu` | cualquiera | ROM `/usr/lib/ipxe/qemu/pxe-e1000.rom` |
| `squashfs-tools` | cualquiera | Para generar `huronos-system.sfs` |
| `kmod` | cualquiera | Para `depmod` al empaquetar los módulos compilados |
| KVM | — | `/dev/kvm` debe existir (`lsmod | grep kvm`) |
| RAM host | 14 GB+ | 6 GB por slave (incluye caché de httpfs2) + SO host + Docker |
| Espacio en disco | ~10 GB temporales | Solo durante `00-build-kernel.sh` (fuentes del kernel); el resultado final pesa unos 15 MB |

---

## Estructura del proyecto

```
progDelfin_iPXE/
├── huronOS-alpha-0.4-amd64.iso   ← ISO fuente (no en git)
├── huronos-patch/
│   ├── livekitlib                 ← modifica lib/livekitlib del initrd: agrega
│   │                                 find_data_netboot(), tmpfs para event/contest,
│   │                                 la síntesis de sync-server.conf, y la restauración
│   │                                 (pull) del respaldo event/contest desde el master
│   ├── hmm                        ← copia parchada de /usr/sbin/hmm: descarga un
│   │                                 .hsm del master bajo demanda si no existe local
│   └── hnetsync/                  ← árbol para la capa 07-hnetsync.hsl:
│       ├── usr/local/sbin/hnetsync-push     ← sube event/contest al master
│       ├── usr/lib/hsync/libhsystem.so      ← copia parchada: system_has_just_booted()
│       │                                       usa un marcador de arranque en netboot
│       │                                       en vez de /proc/uptime (ver PROGRESO.md)
│       └── etc/systemd/system/    ← hnetsync-push-shutdown.service + drop-ins sobre
│                                     hsync.service/happly.service (ExecStopPost=)
├── directives/
│   └── directives.hdf             ← directivas del examen (editar aquí entre exámenes)
├── kernel-cache/                  ← salida de 00-build-kernel.sh / 02c / 02e (no en git)
│   ├── vmlinuz-6.0.15-huronos+    ← kernel recompilado con NETWORK=true
│   ├── initrfs.img                ← initrd recompilado con huronos-patch/livekitlib
│   ├── 06-netboot-hmm.hsl         ← capa aditiva con huronos-patch/hmm
│   └── 07-hnetsync.hsl            ← capa aditiva con huronos-patch/hnetsync
├── boot/                          ← archivos servidos por nginx (generados)
│   ├── boot.ipxe                  ← script de arranque iPXE
│   ├── vmlinuz-6.0.15-huronos+
│   ├── initrfs.img
│   ├── huronos-system.sfs
│   ├── directives.hdf             ← copia de directives/directives.hdf
│   └── software/<categoria>/*.hsm ← catálogo completo extraído de la ISO
├── sync-data/                     ← respaldos event/contest por MAC (no en git, generado)
│   └── <mac>/{event,contest}.tar.gz
├── master/
│   ├── Dockerfile                 ← imagen Docker del master
│   ├── dnsmasq.conf                ← DHCP + detección iPXE
│   ├── nginx.conf                  ← servidor HTTP de archivos de boot + proxy /sync/
│   ├── sync-server.py              ← recibe/sirve los respaldos event/contest (127.0.0.1:8081)
│   └── entrypoint.sh               ← arranca nginx + dnsmasq + sync-server.py
├── docker-compose.yml
└── scripts/
    ├── 00-build-kernel.sh           ← (una sola vez) recompila el kernel con NETWORK=true
    ├── 00b-rebuild-initrd.sh        ← reconstruye solo el initrd (sin recompilar el kernel)
    ├── 01-setup-network.sh          ← crea br-ipxe, tap0, tap1 + NAT a internet
    ├── 02-build-huronos-boot.sh     ← copia kernel-cache/ a boot/ y genera el .sfs
    ├── 02b-setup-directives.sh      ← publica directives.hdf y boot/software/*.hsm
    ├── 02c-build-hmm-layer.sh       ← empaqueta huronos-patch/hmm en 06-netboot-hmm.hsl
    ├── 02e-build-hnetsync-layer.sh  ← empaqueta huronos-patch/hnetsync en 07-hnetsync.hsl
    ├── 03-start-master.sh           ← docker compose up
    ├── 04-start-slave1.sh           ← QEMU slave 1 (tap0, mac=52:54:00:12:34:01)
    ├── 04-start-slave2.sh           ← QEMU slave 2 (tap1, mac=52:54:00:12:34:02)
    └── 99-teardown.sh               ← limpieza total
```

---

## Puesta en marcha

Ejecutar **en este orden** desde el directorio raíz del proyecto:

### 1. Compilar el kernel con soporte de red (una sola vez)

```bash
./scripts/00-build-kernel.sh
```

Clona `huronOS-build-tools`, aplica `huronos-patch/livekitlib`, y compila el kernel `6.0.15-huronos+` (mismo `.config` oficial) dentro de un contenedor `debian:bullseye`, con `NETWORK=true` para que el initrd incluya `e1000`/`e1000e`. Es una compilación de kernel real — puede tardar bastante (hasta un par de horas según CPU). Resultado en `kernel-cache/`. Solo hay que repetir este paso si cambia la versión de HuronOS o el parche.

### 2. Red virtual

```bash
sudo ./scripts/01-setup-network.sh
```

Crea el bridge `br-ipxe` (192.168.100.1/24) y las interfaces TAP `tap0` y `tap1`. Idempotente.

### 3. Construir los archivos de boot

```bash
sudo ./scripts/02-build-huronos-boot.sh
```

Copia `kernel-cache/` a `boot/` y genera `boot/huronos-system.sfs` (squashfs de toda la ISO, servido por HTTP y consumido via `httpfs2` dentro del initrd). Repetir si cambia la ISO. Si `kernel-cache/06-netboot-hmm.hsl` no existe, este paso avisa — correr antes `./scripts/02c-build-hmm-layer.sh`.

### 3b. Directivas del examen y catálogo de software

```bash
./scripts/02c-build-hmm-layer.sh      # una sola vez (o si cambia huronos-patch/hmm)
./scripts/02e-build-hnetsync-layer.sh # una sola vez (o si cambia huronos-patch/hnetsync)
sudo ./scripts/02b-setup-directives.sh
```

Publica `directives/directives.hdf` en `boot/directives.hdf`, y extrae todo `huronOS/software/*.hsm` de la ISO a `boot/software/` (archivos sueltos, servidos por nginx — el mecanismo nativo de HuronOS, `hmm`/`hsync`, descarga bajo demanda solo los que las directivas activas piden). Editar `directives/directives.hdf` y volver a correr `02b-setup-directives.sh` es suficiente para publicar cambios de directivas entre exámenes; no requiere reconstruir el kernel/initrd/sfs.

Nota sobre `02e-build-hnetsync-layer.sh`: si cambia `huronos-patch/livekitlib` (la parte de `hnetsync-pull`, que corre en el initrd), hace falta además `./scripts/00b-rebuild-initrd.sh` antes de `02-build-huronos-boot.sh`.

### 4. Master (DHCP + HTTP)

```bash
./scripts/03-start-master.sh
```

Verificar que funciona:

```bash
curl http://192.168.100.1/boot.ipxe
curl -I http://192.168.100.1/huronos-system.sfs
docker logs -f ipxe-master
```

### 5. VMs esclavas

```bash
# Terminal 1
sudo ./scripts/04-start-slave1.sh

# Terminal 2
sudo ./scripts/04-start-slave2.sh
```

El log de arranque aparece en la terminal donde se lanzó el script (`-serial stdio`). Debe mostrar `huronOS Init process`, `Fetching huronOS system data from ...`, y terminar en `huronOS ready!, starting contest enviroment`.

---

## Teardown

```bash
sudo ./scripts/99-teardown.sh
```

Detiene el contenedor Docker, desmonta la ISO si quedó montada, y elimina `tap0`, `tap1` y `br-ipxe`.

---

## Piloto en hardware real

Todo lo de arriba es la simulación 100% local (QEMU + bridge virtual `br-ipxe` en el mismo host que corre el master). Existe además un primer piloto en **hardware real** — Raspberry Pi como master, un MikroTik hEX lite como router/switch dedicado del segmento de examen, y PCs físicas (empezando por una laptop) como clientes PXE — auto-contenido en `experimento_hardware_real/` sin modificar nada de lo anterior (`master/`, `docker-compose.yml`, `boot/boot.ipxe` de la raíz siguen sirviendo igual para la simulación QEMU).

Ya validado de punta a punta: arranque PXE completo de una laptop física hasta el escritorio Budgie, `directives.hdf` aplicándose (allowlist, software bajo demanda — `vscode`/`pycharm`/`chromium`, etc. confirmados abriendo), sobre una red físicamente aislada por el MikroTik. Ver `experimento_hardware_real/LABORATORIO-REAL.md` para la topología, la configuración paso a paso del MikroTik/RPi, y el detalle del chainload TFTP (`snponly.efi`) que hace falta para firmware PXE de fábrica (no-iPXE) — algo que la simulación QEMU no necesita porque su ROM de red ya es iPXE desde el primer DHCP request. Ver también `PROGRESO.md` (intento 13) para la bitácora completa de bugs encontrados y corregidos armando esto.

## Los parches locales sobre HuronOS

Ambos son extensiones aditivas, no parte del upstream oficial, y el camino original (USB física + `install.sh`) no se toca en ninguno de los dos: cada rama nueva solo se activa cuando el kernel recibe `huronos.flags=(netboot=true;...)`.

### `huronos-patch/livekitlib` (modifica `lib/livekitlib` del initrd)

- **`find_data()`**: si `netboot=true`, delega a `find_data_netboot()` en vez de buscar un dispositivo físico por UUID. Reutiliza `mount_data_http()` (ya existente en HuronOS, heredado de Slax, nunca usado) para descargar `huronos-system.sfs` vía FUSE/httpfs2 + loop, y lo copia a una segunda `tmpfs` para evitar el bug de "loop sobre loop sobre FUSE" (ver `PROGRESO.md`, intento 7).
- **`persistent_changes()`**: si `netboot=true`, monta `event`/`contest` como `tmpfs` en vez de buscar particiones físicas por UUID.
- Sintetiza `huronOS/data/configs/sync-server.conf` (mismo formato que genera `install.sh`) a partir de los flags `directives.url`/`directives.server`, ya que el netboot nunca corre `install.sh`.

### `huronos-patch/hmm` (copia parchada de `/usr/sbin/hmm`, empaquetada como capa `06-netboot-hmm.hsl`)

HuronOS ya trae, dentro de `huronOS/base/01-core.hsl`, el mecanismo completo de directivas — `hsync.timer`/`hsync.service`/`happly.service` descargan `directives.hdf` cada 60s y aplican timezone, wallpaper, horarios `Event`/`Contest`, el firewall/allowlist (`AllowedWebsites`, vía `iptables`), USB (`AllowUsbStorage`), y software (`AvailableSoftware`, vía `hmm`). Nada de esto se tuvo que reconstruir.

Lo único que falta en netboot es que `huronOS/software/*.hsm` (los módulos de IDEs/compiladores que `hmm` monta) no viajan dentro de `huronos-system.sfs` — se excluyeron deliberadamente por el bug de los 4 GiB (ver abajo). `huronos-patch/hmm` agrega, dentro de `activate()`, un fetch bajo demanda: si `netboot=true` y el `.hsm` pedido no existe localmente, se descarga del master (`software.url`) antes de montarlo — solo los módulos que las directivas activas realmente piden, nunca el catálogo completo. Se apila como `huronOS/base/06-netboot-hmm.hsl`, por encima de `01-core.hsl` en la unión AUFS (gracias a que `union_append_modules()` ya recorre `huronOS/base/*.hsl` en orden alfabético), sin modificar ningún archivo original de HuronOS.

### `huronos-patch/hnetsync/` (capa `07-hnetsync.hsl`) + la parte de `pull` en `livekitlib`

`libhpersistence.so`/`libhrestore.so` (HuronOS original, sin modificar) ya saben restaurar/respaldar el trabajo del contestant entre encendidos — pero esperan una partición física `event`/`contest` en un USB. En netboot esas particiones son `tmpfs` (RAM), así que sin este parche todo se perdía al apagar la VM. La solución tiene tres piezas:

- **Restaurar (pull)**: agregado directamente en `persistent_changes()` de `huronos-patch/livekitlib`, justo después de montar los `tmpfs` de `event`/`contest` — **en el initrd, antes de `pivot_root`**, no en un servicio systemd posterior (ver más abajo por qué).
- **Guardar (push)**: `huronos-patch/hnetsync/usr/local/sbin/hnetsync-push`, enganchado con *drop-ins* systemd (`hsync.service.d/`, `happly.service.d/`, más un `hnetsync-push-shutdown.service` para el apagado) — nunca se edita `hsync.service`/`happly.service` en sí.
- **`usr/lib/hsync/libhsystem.so`** (copia parchada, mismo patrón que `huronos-patch/hmm`): `system_has_just_booted()` decide si es "el primer arranque" mirando `/proc/uptime < 60s` — poco confiable en este netboot, donde kernel+initrd+descarga+descompresión ya tardan más que eso por sí solos. La copia parchada usa un marcador de una sola vez por arranque **solo si `netboot=true`**; el camino físico (USB) queda intacto.

La identidad de cada máquina es la MAC de su interfaz de red — por eso `04-start-slave1.sh`/`04-start-slave2.sh` fijan `mac=` explícita (QEMU les daba la misma por defecto si no).

Ver `PROGRESO.md` (intento 12) para los tres bugs reales encontrados armando esto — ninguno se ve con solo leer el código, hicieron falta ciclos completos de arranque/apagado para descubrirlos.

---

## Trabajo futuro (fuera de este proyecto por ahora)

- Optimizar el tiempo de arranque (~2:30 min hoy, copiando `huronos-system.sfs` completo a RAM sin caché).
- Probar el modo `Event` con un horario vigente **en la simulación QEMU** (ya se probó a fondo `Contest` aquí, ver `PROGRESO.md`; `Event` ya se validó en el piloto de hardware real — ver arriba e intento 13 de `PROGRESO.md`).
- Verificar `hnetsync` (persistencia `event`/`contest`) en el piloto de hardware real con la MAC de una PC física — confirmado el mecanismo en QEMU (intento 12), pendiente el ciclo completo apagar/encender en la laptop.

---

## Diagnóstico y solución de problemas

### Ver logs del master en tiempo real

```bash
docker logs -f ipxe-master
```

### Verificar que nginx sirve los archivos

```bash
curl http://192.168.100.1/boot.ipxe
curl -I http://192.168.100.1/vmlinuz-6.0.15-huronos+
curl -I http://192.168.100.1/initrfs.img
curl -I http://192.168.100.1/huronos-system.sfs
```

### Depurar el arranque paso a paso

Agrega `debug` a `huronos.flags` (imita el label `debug` de `boot/huronos.cfg` del ISO original) para obtener shells interactivos entre cada paso del `init` (`debug_shell`), útiles para diagnosticar si la red no subió, si `httpfs2` no montó el `.sfs`, o si el squashfs no contiene `huronOS/base/*.hsl` en su raíz.

### Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| iPXE no recibe DHCP | Master no iniciado o bridge mal configurado | Verificar `docker logs ipxe-master` y `ip addr show br-ipxe` |
| `ifconfig: error fetching interface information` / `udhcpc: SIOCGIFINDEX` | El initrd usado no tiene `e1000.ko` (se usó el original de la ISO, no el de `kernel-cache/`) | Verificar que `boot/initrfs.img` viene de `02-build-huronos-boot.sh`, no de la ISO directamente |
| `fatal: No base system found via netboot URL ...` | `huronos-system.sfs` no responde, o no contiene `huronOS/base/*.hsl` en su raíz | `curl -I http://192.168.100.1/huronos-system.sfs` y regenerar con `02-build-huronos-boot.sh` |
| `00-build-kernel.sh` falla en la compilación | Revisar `build.log` dentro del contenedor (el script lo imprime en pantalla); suele ser falta de espacio en disco | Verificar espacio libre antes de lanzar el build |
| ISO no se monta al reiniciar el host | El montaje loop no persiste entre reinicios | Repetir `sudo ./scripts/02-build-huronos-boot.sh` |
| `lightdm.service` falla con `203/EXEC`, `journalctl` muestra `SQUASHFS error: Unable to read fragment/page` en el mismo bloque siempre | `huronos-system.sfs` pesaba > 4 GiB; `mount.httpfs2` (binario de 32 bits) trunca offsets cerca del final del archivo, corrompiendo la tabla de fragmentos de squashfs | Ya corregido: `02-build-huronos-boot.sh` solo empaqueta `huronOS/base`+`huronOS/data`+`boot`+`EFI`+`checksums` (sin `huronOS/software/`), quedando muy por debajo de 4 GiB. Si el `.sfs` vuelve a acercarse a 4 GiB, revisar qué se está incluyendo |
| No hay internet real dentro de la VM (solo conectividad al master) | Falta NAT del bridge `br-ipxe` hacia la interfaz con internet del host | `sudo ./scripts/01-setup-network.sh` (idempotente, agrega `MASQUERADE`+`FORWARD` automáticamente) |
| `hsync.log` muestra `!huronOS module not found: ` con la ruta **vacía** | `readlink -f` exige que los directorios padre ya existan; `huronOS/software/<categoria>/` no existe hasta que se descarga algo ahí | Ya corregido en `huronos-patch/hmm`: crea el directorio padre y descarga contra la ruta cruda antes de resolver con `readlink -f` |
| Un `.hsm` pedido en `AvailableSoftware` da `404` al descargarlo (`curl -I http://.../software/...` confirma) | `cp -a` desde la ISO preserva permisos root-only; `nginx` corre como `www-data` dentro del contenedor | Ya corregido en `02b-setup-directives.sh`: `chmod -R a+rX` sobre `boot/software/` tras copiar |
| Tras reiniciar la VM, el trabajo restaurado de `event`/`contest` desaparece a los pocos segundos (`hsync.log` muestra `Running mode is always, ...considered to be different`) | `system_has_just_booted()` (HuronOS original) decidió que este NO era el primer arranque (uptime > 60s), se saltó el restore, y por seguridad reconstruyó todo desde cero en modo `always` — borrando en cascada lo recién restaurado | Ya corregido: el `pull` corre en el initrd (antes de que systemd cuente uptime) y `libhsystem.so` usa un marcador de arranque en vez de `/proc/uptime` cuando `netboot=true` (capa `07-hnetsync.hsl`) |
| `hnetsync-pull` descarga el `.tar.gz` pero `/var/log/hnetsync-initrd.log` muestra `tar: invalid option -- z` | El `tar` de busybox de este initrd (v1.26.2) no soporta `-z` aunque `gzip`/`gunzip` existan como applets aparte | Ya corregido en `huronos-patch/livekitlib`: `gzip -dc archivo.tar.gz \| tar x -C DIR -f -` en vez de `tar xzf` |
| No se ve nada de `hnetsync-pull` en `journalctl -b 0`/`dmesg` | journald no captura la salida de consola del initrd (arranca después, ya en el sistema completo) | Revisar `/var/log/hnetsync-initrd.log` (escrito directo en `$SYSCHANGES`, sobrevive al `pivot_root`) |
