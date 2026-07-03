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
│   └── nginx    ─── HTTP :80
│                     /boot.ipxe             ← script iPXE
│                     /vmlinuz-*-huronos+    ← kernel recompilado (con e1000/e1000e)
│                     /initrfs.img           ← initrd recompilado (NETWORK=true + parche netboot)
│                     /huronos-system.sfs    ← bundle del sistema completo (squashfs de la ISO)
│
├── tap0 ──► QEMU slave1  (KVM, 6 GB RAM, SDL)
└── tap1 ──► QEMU slave2  (KVM, 6 GB RAM, SDL)
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
10. init              →  event/contest montados como tmpfs (RAM)
11. Sistema           →  HuronOS listo, pivot_root + chroot a systemd
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
│   └── livekitlib                 ← único archivo modificado de HuronOS: agrega
│                                     find_data_netboot() y tmpfs para event/contest
├── kernel-cache/                  ← salida de 00-build-kernel.sh (no en git)
│   ├── vmlinuz-6.0.15-huronos+    ← kernel recompilado con NETWORK=true
│   └── initrfs.img                ← initrd recompilado con el parche aplicado
├── boot/                          ← archivos servidos por nginx (generados)
│   ├── boot.ipxe                  ← script de arranque iPXE
│   ├── vmlinuz-6.0.15-huronos+
│   ├── initrfs.img
│   └── huronos-system.sfs
├── master/
│   ├── Dockerfile                 ← imagen Docker del master
│   ├── dnsmasq.conf                ← DHCP + detección iPXE
│   ├── nginx.conf                  ← servidor HTTP de archivos de boot
│   └── entrypoint.sh               ← arranca nginx + dnsmasq
├── docker-compose.yml
└── scripts/
    ├── 00-build-kernel.sh           ← (una sola vez) recompila el kernel con NETWORK=true
    ├── 01-setup-network.sh          ← crea br-ipxe, tap0, tap1
    ├── 02-build-huronos-boot.sh     ← copia kernel-cache/ a boot/ y genera el .sfs
    ├── 03-start-master.sh           ← docker compose up
    ├── 04-start-slave1.sh           ← QEMU slave 1 (tap0)
    ├── 04-start-slave2.sh           ← QEMU slave 2 (tap1)
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

Copia `kernel-cache/` a `boot/` y genera `boot/huronos-system.sfs` (squashfs de toda la ISO, servido por HTTP y consumido via `httpfs2` dentro del initrd). Repetir si cambia la ISO.

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

## El parche `huronos-patch/livekitlib`

Es una extensión local sobre HuronOS estándar, no parte del upstream oficial. Modifica únicamente `lib/livekitlib` dentro del initrd:

- **`find_data()`**: si `huronos.flags` trae `netboot=true`, delega a `find_data_netboot()` en vez de buscar un dispositivo físico por UUID. Reutiliza `mount_data_http()` (ya existente en HuronOS, heredado de Slax, nunca usado) para descargar `huronos-system.sfs` vía FUSE/httpfs2 y montarlo por loop device.
- **`persistent_changes()`**: si `netboot=true`, monta `event`/`contest` como `tmpfs` en vez de buscar particiones físicas por UUID.

El camino original (USB física + `install.sh`) no se toca: ambas ramas conviven, seleccionadas por el flag `netboot`.

---

## Trabajo futuro (fuera de este proyecto por ahora)

- Sincronizar `event`/`contest` (hoy en RAM) hacia el servidor master mediante un servicio periódico (POST por HTTP), implementado en la capa `05-custom.hsl` una vez arrancado el sistema completo.
- Servir `directives.hdf` desde el master y automatizar el flujo `--directives-url`/`--directives-server-ip` de `install.sh` para la sincronización de configuración del examen.
- Los módulos de software (`huronOS/software/*.hsm`: IDEs, lenguajes, navegadores) no se incluyen hoy en `huronos-system.sfs` (ver "El bug de los 4 GiB" abajo). Para tenerlos disponibles en netboot hace falta un mecanismo de montaje bajo demanda (otro `.sfs` separado por debajo de 4 GiB cada uno, o un transporte distinto a `httpfs2`).

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
