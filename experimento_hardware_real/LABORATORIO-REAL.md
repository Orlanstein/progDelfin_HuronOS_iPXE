# Laboratorio real: RPi + MikroTik hEX lite + PCs físicas

Primer piloto en hardware real del proyecto (hasta ahora todo se probó en simulación 100% local con QEMU — ver `README.md`/`PROGRESO.md` en la raíz). Master en una Raspberry Pi, primera PC cliente la laptop del usuario, escalable a más PCs después.

## 1. Objetivo

Recrear, con hardware real, exactamente lo que ya funciona en la simulación (arranque 100% por red, directivas, persistencia `event`/`contest`), pero:

- El master corre en una Raspberry Pi en vez de en el mismo host que las VMs.
- Las PCs cliente son máquinas físicas (empezando por una laptop) en vez de VMs QEMU.
- Un MikroTik hEX lite hace de router/switch dedicado del segmento de examen, aislado del resto de la red (modem/ISP) — así el `dnsmasq` de la RPi sigue siendo el único servidor DHCP del segmento, igual que en la simulación con `br-ipxe` aislado.

**Por qué no conectar todo al modem directamente:** el modem casi seguro trae su propio DHCP corriendo en el mismo segmento — eso compite con el `dnsmasq` de la RPi, con resultados impredecibles para el PXE boot (opciones 66/67 mezcladas, IPs de origen equivocado). El MikroTik aísla el segmento de examen exactamente como lo hacía el bridge virtual `br-ipxe` en la simulación.

## 2. Topología

```
Internet
   │
 MODEM (ISP)
   │
   │ ether1 (DHCP client) — ya configurado, 192.168.1.11/24
┌──┴──────────────────────────────┐
│         MikroTik hEX lite        │
│  bridge-lan (ether2,3,4,5)       │
│  IP: 192.168.2.1/24              │
│  NAT masquerade ether1 → internet│  (ya configurado)
│  DHCP server propio: DESHABILITAR│  (dhcp-lan, ver sección 3)
└──┬──────┬──────┬──────┬──────────┘
   │      │      │      │
 ether2  ether3 ether4 ether5
   │      │      │      │
   RPi   Laptop  PC2    PC3 (futuras)
 (master) (cliente PXE) ...
  .2.2     DHCP        DHCP
```

> Nota: este MikroTik ya llegó preconfigurado (bridge-lan con ether2-5, IP `192.168.2.1/24`,
> NAT masquerade hacia `ether1`, cliente DHCP en `ether1`, puertos ya etiquetados como
> "RPi PXE server"/"Laptop gamer") — de una prueba anterior. Reusamos esa configuración tal
> cual en vez de rehacerla desde cero; lo único pendiente es apagar su `dhcp-server` propio
> (sección 3), que compite con el `dnsmasq` de la RPi.

### Direccionamiento

| Dispositivo | IP | Rol |
|---|---|---|
| MikroTik (bridge-lan) | `192.168.2.1/24` | Gateway del segmento + NAT hacia el modem |
| Raspberry Pi (master) | `192.168.2.2/24` (estática) | dnsmasq (DHCP+PXE) + nginx (HTTP) + sync-server (persistencia) |
| Laptop / PCs cliente | DHCP, rango `192.168.2.100`-`192.168.2.200` | Arrancan HuronOS por red |

El gateway es `192.168.2.1` (ya existente en el MikroTik) — solo hace falta poner la IP estática de la RPi (`192.168.2.2`) y confirmar la interfaz (`eth0`, ya confirmado con `ip addr`).

## 3. Configuración del MikroTik (RouterOS)

Este hEX lite ya llegó configurado (de una prueba anterior) con exactamente lo que necesitábamos armar: bridge `bridge-lan` con `ether2` (RPi) y `ether3` (laptop), IP `192.168.2.1/24`, `ether1` como cliente DHCP hacia el modem (`192.168.1.11/24`), y NAT masquerade `bridge-lan → ether1`. Confirmado con:

```
/interface bridge print          # bridge-lan, con ether2 "RPi PXE server", ether3 "Laptop gamer"
/ip address print                # 192.168.2.1/24 en bridge-lan
/ip dhcp-client print             # bound, 192.168.1.11/24 en ether1
/ip firewall nat print            # chain=srcnat action=masquerade out-interface=ether1
```

Lo único que falta es apagar el **DHCP server propio** del MikroTik en `bridge-lan` (`dhcp-lan`) — si sigue activo, compite con el `dnsmasq` de la RPi por las mismas IPs/PXE:

```
/ip dhcp-server print
# debe verse: 0  dhcp-lan  bridge-lan  pool-lan  12h
/ip dhcp-server disable dhcp-lan
```

Verifica:

```
/ip dhcp-server print       # dhcp-lan debe quedar "disabled=yes" (o listado con flag X)
```

> Si en tu MikroTik el bridge/NAT/WAN client NO existieran todavía (equipo nuevo de fábrica),
> arma primero el bridge y el NAT:
> ```
> /interface bridge add name=bridge-lan
> /interface bridge port add bridge=bridge-lan interface=ether2
> /interface bridge port add bridge=bridge-lan interface=ether3
> /interface bridge port add bridge=bridge-lan interface=ether4
> /interface bridge port add bridge=bridge-lan interface=ether5
> /ip address add address=192.168.2.1/24 interface=bridge-lan
> /ip dhcp-client add interface=ether1 disabled=no
> /ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
> ```

## 4. Configuración de red de la Raspberry Pi

IP estática `192.168.2.2/24`, gateway `192.168.2.1`, DNS `8.8.8.8` (o el que prefieras). Esta RPi corre Ubuntu (`VERSION_CODENAME=questing`) con NetworkManager activo — confirmado con `systemctl status NetworkManager`.

Importante: la conexión SSH que usas para administrar la RPi va por `wlan0` (`192.168.1.13`, WiFi de casa), y este cambio es solo sobre `eth0` (el segmento aislado del MikroTik) — no vas a perder la sesión al aplicarlo.

```bash
nmcli connection show                       # identifica el nombre de la conexión sobre eth0 (ej. "Wired connection 1")
nmcli connection modify "Wired connection 1" \
    ipv4.method manual \
    ipv4.addresses 192.168.2.2/24 \
    ipv4.gateway 192.168.2.1 \
    ipv4.dns 8.8.8.8
nmcli connection up "Wired connection 1"
```

Confirma con `ip addr show eth0` que quedó en `192.168.2.2/24` antes de seguir.

## 5. Detectar el nombre real de la interfaz

Ya confirmado con `ip addr`: la interfaz Ethernet de esta RPi se llama `eth0` (coincide con el placeholder de `experimento_hardware_real/master/dnsmasq.conf`, no hace falta editarlo).

## 6. Levantar el master

`experimento_hardware_real/setup-master.sh` automatiza todo este paso (y la
sección 4, si se lo pides con `--configure-network`): verifica herramientas,
genera `boot/` desde la ISO, regenera las capas `hmm`/`hnetsync`, descarga
`snponly.efi` si falta, copia el `boot.ipxe` de hardware real, y levanta el
contenedor. Sirve tanto para el setup inicial de una máquina nueva como para
un simple reinicio (con `--skip-boot-build`, no vuelve a montar la ISO de 5GB
ni a bajar todo el catálogo de software).

```bash
cd experimento_hardware_real

# Primera vez en una máquina nueva (asumiendo kernel-cache/ ya compilado,
# ver scripts/00-build-kernel.sh, o agrega --build-kernel para compilarlo):
./setup-master.sh --configure-network --iface eth0

# Reinicios posteriores (ya generado boot/, red ya configurada):
./setup-master.sh --skip-boot-build
```

`--iface` es la única variable real entre máquinas — confírmala con `ip addr`
antes de correr `--configure-network` (ver sección 5). La IP del master
(`192.168.2.2/24`) y el gateway (`192.168.2.1`, el MikroTik) quedan fijos,
sin importar qué máquina haga de master. Corre `./setup-master.sh --help`
para ver todas las flags.

### Dashboard (`master-tui.sh`)

Para el día a día (revisar estado, ver logs, cambiar de directivas, alternar
Event/Contest, reiniciar el contenedor) sin tener que recordar comandos
sueltos, `experimento_hardware_real/master-tui.sh` pone un menú (whiptail)
encima de `setup-master.sh` y de `scripts/02b-setup-directives.sh`:

```bash
cd experimento_hardware_real
./master-tui.sh
```

Incluye también un panel de enlaces de referencia (docs de HuronOS, repo
oficial de build, ejemplos de `directives.hdf`). No reemplaza a
`setup-master.sh` ni a los pasos manuales — solo los envuelve.

Si prefieres los pasos manuales (o quieres entender qué hace el script por
debajo):

```bash
# Desde la raíz del repo (no solo esta carpeta — el boot/ generado se comparte)
sudo ./scripts/02-build-huronos-boot.sh
./scripts/02c-build-hmm-layer.sh          # si no se hizo antes
./scripts/02e-build-hnetsync-layer.sh     # si no se hizo antes
sudo ./scripts/02b-setup-directives.sh

# Usar el boot.ipxe adaptado a hardware real (server=192.168.2.2)
cp experimento_hardware_real/boot.ipxe boot/boot.ipxe

# Levantar el contenedor con la config de esta carpeta
cd experimento_hardware_real
docker compose build
docker compose up -d
```

Nota: `boot/boot.ipxe` normalmente está versionado con `set server 192.168.100.1` (valor de la simulación QEMU). Copiar el de esta carpeta lo sobreescribe para hardware real — si vuelves a correr la simulación QEMU después, recuerda restaurarlo con `git checkout boot/boot.ipxe`.

### 6.1 Chainload TFTP para firmware PXE no-iPXE (necesario en hardware real)

A diferencia de la simulación QEMU (cuya ROM de red ya es un binario iPXE desde el
primer DHCP request), el firmware UEFI de fábrica de una PC física **no es iPXE**
todavía en su primer request, así que no puede consumir directamente el script HTTP
`boot.ipxe`. `dnsmasq.conf` (de esta carpeta) ya está configurado para encadenar esto
en dos pasos vía TFTP:

1. El firmware UEFI (detectado por DHCP option 60 = `PXEClient:Arch:00007`, EFI x86-64)
   pide por TFTP `snponly.efi` — un binario iPXE real, compilado con el driver SNP del
   propio firmware UEFI (máxima compatibilidad con NICs que no conocemos de antemano).
2. Al arrancar, `snponly.efi` repite el DHCP request pero ya como iPXE (con la opción
   175), y ahí `dnsmasq` lo redirige al `boot.ipxe` real por HTTP.

Esto ya viene resuelto en el repo: solo hace falta que `experimento_hardware_real/tftpboot/snponly.efi`
exista (descargado de `http://boot.ipxe.org/x86_64-efi/snponly.efi`) y que el
`docker-compose.yml` de esta carpeta monte `./tftpboot:/var/ftpd:ro` (ya está en el
archivo versionado). Si se agrega una PC con arquitectura distinta (BIOS legacy en vez
de UEFI, o UEFI de 32 bits), hay que agregar el binario `.efi`/`.kpxe` correspondiente
a `tftpboot/` y su propio `dhcp-match`/`dhcp-boot` en `dnsmasq.conf`.

## 7. Qué NO se usa aquí

| Script (raíz del repo) | Por qué no aplica | Qué lo reemplaza |
|---|---|---|
| `scripts/01-setup-network.sh` | Crea el bridge virtual `br-ipxe` + TAPs + NAT — son constructos de QEMU/Linux bridge en el host de simulación | Configuración del MikroTik (sección 3) + IP estática de la RPi (sección 4) |
| `scripts/99-teardown.sh` | Limpia el bridge/TAPs de la simulación | `docker compose down` en esta carpeta; nada que limpiar del lado de red (es hardware real) |
| `scripts/00b-rebuild-initrd.sh` | Sin cambios — sigue usándose igual si se modifica `huronos-patch/livekitlib`, desde la raíz del repo |
| `scripts/04-start-slave1.sh` / `04-start-slave2.sh` | Arrancan VMs QEMU — no aplica a PCs físicas | Habilitar PXE boot en el firmware (BIOS/UEFI) de cada PC física (sección 8) |

## 8. Arrancar la laptop/PCs por PXE

1. Conecta la PC al MikroTik **por cable** a uno de los puertos `ether2-5` (WiFi no soporta PXE boot).
2. Entra al BIOS/UEFI de la PC (tecla F2/F10/F12/Del según el fabricante).
3. Habilita "Network Boot" / "PXE Boot" / "LAN Boot" (el nombre exacto varía).
4. Pon el arranque por red primero en el orden de arranque (boot order), o usa el menú de arranque rápido (F12 en muchos fabricantes) para elegir "Network Boot" una sola vez sin cambiar el orden permanente.
5. Guarda y reinicia.

## 9. Checklist de verificación

1. **DHCP**: la laptop debe recibir una IP en `192.168.2.100-200` con gateway `192.168.2.1`. Revisa `docker logs -f ipxe-master` en la RPi (verás el `log-dhcp` de `dnsmasq`) mientras arranca la laptop.
2. **HTTP**: desde la RPi y desde cualquier otra PC del segmento:
   ```bash
   curl http://192.168.2.2/boot.ipxe
   curl -I http://192.168.2.2/huronos-system.sfs
   ```
3. **Arranque completo**: la laptop debe llegar al escritorio Budgie de HuronOS (mismo flujo que las VMs — ver `README.md` de la raíz, "Cadena de arranque completa").
4. **Directivas**: dentro de la laptop ya arrancada,
   ```bash
   cat /var/log/hsync.log | tail -50
   iptables -L INPUT -n
   ```
   debe reflejar el modo activo (`always`/`event`/`contest`) según `directives/directives.hdf`.
5. **`hnetsync`** (persistencia event/contest): usa la MAC **real** de la laptop (no hay que fijar nada a mano, a diferencia de las VMs QEMU que compartían MAC por defecto):
   ```bash
   ip addr show <interfaz> | grep link/ether     # MAC real de la laptop
   ```
   En la RPi, confirma que aparece `sync-data/<mac-sin-dos-puntos>/` con `event.tar.gz`/`contest.tar.gz` tras el primer ciclo de `hsync` (~60s después del login).

## 10. Diferencias clave vs. la simulación QEMU

| | Simulación (QEMU) | Hardware real |
|---|---|---|
| Master corre en | El mismo host Linux que las VMs, dentro de Docker con `network_mode: host` sobre `br-ipxe` (bridge virtual) | Raspberry Pi dedicada, Docker con `network_mode: host` sobre su interfaz física |
| Aislamiento de red | Bridge Linux `br-ipxe` + TAPs, creados por `01-setup-network.sh` | MikroTik hEX lite (bridge + DHCP único + NAT) |
| NAT a internet | `iptables MASQUERADE` en el host (`01-setup-network.sh`) | NAT en el MikroTik (`ether1` → internet) |
| PCs cliente | VMs QEMU (`04-start-slaveN.sh`), ROM iPXE emulada | PCs físicas, firmware PXE nativo |
| Identidad de máquina (`hnetsync`) | MAC fija asignada a mano en cada script (`52:54:00:12:34:0N`) para evitar colisiones de QEMU | MAC real de la NIC de cada PC — ya es única, no requiere configuración |
| `boot/boot.ipxe` | `set server 192.168.100.1` (el propio host) | `set server 192.168.2.2` (la RPi) — ver `experimento_hardware_real/boot.ipxe` |
