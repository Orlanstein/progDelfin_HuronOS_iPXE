# Simulación iPXE con QEMU — Proyecto Delfín

Entorno de simulación de red iPXE con una PC master (servidor) y dos PCs esclavas que arrancan por red. Diseñado para probar ISOs de arranque en red antes de desplegarlas en hardware real.

## Arquitectura

```
HOST LINUX (192.168.100.1 en br-ipxe)
│
├── Docker "ipxe-master"  (--network=host)
│   ├── dnsmasq  ─── DHCP  → asigna IPs al rango .100-.200
│   │               ─── iPXE → entrega URL del script de arranque
│   └── nginx    ─── HTTP :80
│                     /boot.ipxe   ← script iPXE
│                     /vmlinuz     ← kernel Linux
│                     /initrd      ← initrd del live
│
├── NFS server (host)
│   └── /mnt/ubuntu-iso  ─── exportado como read-only a 192.168.100.0/24
│                              (ISO de Ubuntu montada como loop device)
│
├── tap0 ──► QEMU slave1  (KVM, 4 GB RAM, SDL)
└── tap1 ──► QEMU slave2  (KVM, 4 GB RAM, SDL)
```

### Cadena de arranque completa

```
1. QEMU arranca  →  ROM iPXE (pxe-e1000.rom)
2. iPXE          →  DHCP a 192.168.100.1
3. dnsmasq       →  responde: IP + filename=http://192.168.100.1/boot.ipxe
4. iPXE          →  descarga boot.ipxe por HTTP
5. boot.ipxe     →  descarga vmlinuz + initrd por HTTP
6. kernel        →  arranca con boot=casper netboot=nfs
7. casper        →  monta NFS 192.168.100.1:/mnt/ubuntu-iso en /cdrom
8. casper        →  apila capas squashfs del ISO via overlayfs
9. Sistema       →  Ubuntu 24.04 Live listo
```

---

## Requisitos

| Herramienta | Versión mínima | Notas |
|---|---|---|
| QEMU | 8.x | `qemu-system-x86_64` |
| Docker + Compose | 29.x | Para el contenedor master |
| `ipxe-qemu` | cualquiera | ROM `/usr/lib/ipxe/qemu/pxe-e1000.rom` |
| `nfs-kernel-server` | cualquiera | Se instala con `02-extract-iso.sh` |
| KVM | — | `/dev/kvm` debe existir (`lsmod | grep kvm`) |
| RAM host | 10 GB+ | 4 GB por slave + SO host + Docker |

---

## Estructura del proyecto

```
progDelfin_iPXE/
├── ubuntu-24.04.1-desktop-amd64.iso   ← ISO fuente (no en git)
├── boot/                               ← archivos servidos por nginx
│   ├── boot.ipxe                      ← script de arranque iPXE
│   ├── vmlinuz                        ← kernel (extraído del ISO)
│   └── initrd                         ← initrd (extraído del ISO)
├── master/
│   ├── Dockerfile                     ← imagen Docker del master
│   ├── dnsmasq.conf                   ← DHCP + detección iPXE
│   ├── nginx.conf                     ← servidor HTTP de archivos de boot
│   └── entrypoint.sh                  ← arranca nginx + dnsmasq
├── docker-compose.yml
└── scripts/
    ├── 01-setup-network.sh            ← crea br-ipxe, tap0, tap1
    ├── 02-extract-iso.sh              ← extrae kernel/initrd, monta NFS
    ├── 03-start-master.sh             ← docker compose up
    ├── 04-start-slave1.sh             ← QEMU slave 1 (tap0)
    ├── 04-start-slave2.sh             ← QEMU slave 2 (tap1)
    └── 99-teardown.sh                 ← limpieza total
```

---

## Puesta en marcha

Ejecutar **en este orden** desde el directorio raíz del proyecto:

### 1. Red virtual

```bash
sudo ./scripts/01-setup-network.sh
```

Crea el bridge `br-ipxe` (192.168.100.1/24) y las interfaces TAP `tap0` y `tap1`. Requiere sudo. Idempotente — no falla si ya existen.

### 2. ISO y NFS

```bash
sudo ./scripts/02-extract-iso.sh
```

- Extrae `vmlinuz` e `initrd` del ISO a `boot/`
- Monta el ISO en `/mnt/ubuntu-iso` (loop device, read-only)
- Instala `nfs-kernel-server` si no está presente
- Exporta `/mnt/ubuntu-iso` por NFS a la subred `192.168.100.0/24`

Este paso **persiste entre reinicios** siempre que el montaje y NFS sigan activos. Si el host se reinicia, repetir este paso.

### 3. Master (DHCP + HTTP)

```bash
./scripts/03-start-master.sh
```

Construye y lanza el contenedor Docker `ipxe-master` con `dnsmasq` y `nginx`. Usa `network_mode: host` para escuchar directamente en `br-ipxe`.

Verificar que funciona:

```bash
curl http://192.168.100.1/boot.ipxe
docker logs -f ipxe-master
```

### 4. VMs esclavas

En terminales separadas:

```bash
# Terminal 1
sudo ./scripts/04-start-slave1.sh

# Terminal 2
sudo ./scripts/04-start-slave2.sh
```

Cada slave abre una ventana SDL. El log de arranque aparece en la terminal donde se lanzó el script (via `-serial stdio`).

---

## Parámetros de arranque (boot.ipxe)

```
boot=casper          → activa el modo live de Ubuntu
netboot=nfs          → indica que el root filesystem viene por NFS
nfsroot=<ip>:/path   → dónde montar el root
ip=dhcp              → configura red via DHCP en el guest
nomodeset            → desactiva KMS; fuerza X11 con renderizado software
                       (necesario para que GDM3/GNOME funcione en QEMU std VGA)
console=ttyS0,115200 → kernel logs al puerto serial → visible en la terminal host
console=tty1         → consola principal en la pantalla SDL
```

---

## Opciones de QEMU (slaves)

| Opción | Valor | Motivo |
|---|---|---|
| `-enable-kvm -cpu host` | — | Aceleración hardware; sin esto GNOME no arranca (timeout) |
| `-m 4096` | 4 GB | Ubuntu 24.04 Desktop Live requiere ≥ 3 GB para funcionar fluidamente |
| `-smp 2` | 2 vCPUs | Mínimo para el renderizado software de GNOME |
| `-device e1000` | e1000 | NIC con ROM iPXE compatible (`pxe-e1000.rom`) |
| `-boot order=n` | red primero | Fuerza boot por red; sin esto intenta disco primero |
| `-vga std` | VGA estándar | Compatible con `nomodeset`; `virtio-gpu` requiere GL |
| `-serial stdio` | — | Redirige consola serial a la terminal del host para diagnóstico |

---

## Teardown

Para limpiar todo el entorno:

```bash
sudo ./scripts/99-teardown.sh
```

Detiene el contenedor Docker, elimina la exportación NFS, desmonta el ISO, y elimina `tap0`, `tap1` y `br-ipxe`.

---

## Cambiar la ISO

El sistema está diseñado para sustituir Ubuntu por cualquier ISO live basada en casper (ej. HuronOS):

1. Copiar la nueva ISO al directorio del proyecto
2. Editar `scripts/02-extract-iso.sh`: cambiar la variable `ISO` al nuevo nombre de archivo
3. Editar `boot/boot.ipxe`: ajustar parámetros de kernel si la ISO los requiere distintos
4. Volver a ejecutar `sudo ./scripts/02-extract-iso.sh`

Si la ISO usa `filesystem.squashfs` en lugar del esquema de capas de Ubuntu 24.04, eliminar `nomodeset` de `boot.ipxe` podría mejorar el rendimiento gráfico.

---

## Diagnóstico y solución de problemas

### Ver logs del master en tiempo real

```bash
docker logs -f ipxe-master
```

### Verificar NFS desde el host

```bash
showmount -e localhost
# Debe mostrar: /mnt/ubuntu-iso 192.168.100.0/24
```

### Verificar que nginx sirve los archivos

```bash
curl http://192.168.100.1/boot.ipxe
curl -I http://192.168.100.1/vmlinuz
```

### Acceder a la consola del guest sin ventana SDL

La terminal donde se lanzó el slave actúa como consola serial. Presionar **Enter** para obtener un prompt de login (`ubuntu`, sin contraseña).

```bash
# Una vez dentro del guest:
journalctl -b -p err --no-pager | tail -50
systemctl status gdm3
```

### Ctrl+Alt+F2 no funciona en SDL

QEMU SDL intercepta `Ctrl+Alt` para liberar el mouse. Para cambiar de TTY en el guest usar la consola serial (terminal del host) o agregar `-monitor stdio` para acceder al monitor QEMU.

### Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| iPXE no recibe DHCP | Master no iniciado o bridge mal configurado | Verificar `docker logs ipxe-master` y `ip addr show br-ipxe` |
| `nfsmount: can't parse IP` | Parámetro `nfsroot` con URL HTTP en lugar de IP | Asegurar que `boot.ipxe` usa `netboot=nfs nfsroot=IP:/path` |
| Cursor X en pantalla gris | GNOME no arranca por falta de KVM o GPU incompatible | Verificar `-enable-kvm` y `nomodeset` en los parámetros |
| `exportfs: command not found` | PATH sin `/usr/sbin` al correr sudo | El script usa `/usr/sbin/exportfs` explícitamente |
| ISO no se monta al reiniciar | El montaje loop no persiste entre reinicios | Repetir `sudo ./scripts/02-extract-iso.sh` |
