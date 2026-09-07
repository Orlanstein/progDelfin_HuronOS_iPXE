#!/bin/bash
# Dashboard en terminal (whiptail) para preparar y administrar el master de
# hardware real, sin tener que recordar comandos sueltos de docker/sudo/scp.
# Envuelve exactamente lo que ya documenta LABORATORIO-REAL.md y automatiza
# setup-master.sh -- no reemplaza ninguno de los dos, solo les pone un menú
# encima.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MASTER_IP="192.168.2.2"
DIRECTIVES_DIR="$PROJECT_DIR/directives"
ACTIVE_DIRECTIVES="$DIRECTIVES_DIR/directives.hdf"
COMPOSE_DIR="$SCRIPT_DIR"

BACKTITLE="HuronOS -- Master de hardware real (${MASTER_IP})"

if ! command -v whiptail &>/dev/null; then
    echo "[ERROR] Falta 'whiptail' (en Raspberry Pi OS/Debian: sudo apt install whiptail)"
    exit 1
fi

pause() {
    echo ""
    read -rp "Presiona Enter para volver al menú..." _
}

# Ejecuta un comando fuera de whiptail (para salida en vivo: logs, sudo, docker)
run_live() {
    clear
    echo "\$ $*"
    echo "--------------------------------------------------------------------"
    "$@"
    pause
}

show_status() {
    local tmp
    tmp="$(mktemp)"
    {
        echo "Contenedor:"
        docker ps --filter name=ipxe-master --format '  {{.Names}}: {{.Status}}' 2>/dev/null
        echo ""
        echo -n "HTTP boot.ipxe (http://${MASTER_IP}/boot.ipxe): "
        if curl -sf -o /dev/null "http://${MASTER_IP}/boot.ipxe"; then
            echo "OK"
        else
            echo "FALLÓ"
        fi
        echo ""
        echo "Directivas activas: ${ACTIVE_DIRECTIVES}"
        if [ -f "$ACTIVE_DIRECTIVES" ]; then
            grep -E '^(EventConfig|ContestConfig)=' "$ACTIVE_DIRECTIVES" | sed 's/^/  /'
        fi
    } >"$tmp" 2>&1
    whiptail --backtitle "$BACKTITLE" --title "Estado" --textbox "$tmp" 20 78
    rm -f "$tmp"
}

pick_directives() {
    local options=() f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [ "$f" = "$ACTIVE_DIRECTIVES" ]; then
            options+=("$base" "(activo actualmente)")
        else
            options+=("$base" "en ${DIRECTIVES_DIR}/")
        fi
    done < <(find "$DIRECTIVES_DIR" -maxdepth 1 -name '*.hdf' 2>/dev/null | sort)
    options+=("__manual__" "Escribir otra ruta a mano (p.ej. descargado de huronos_directives)")

    local choice
    choice=$(whiptail --backtitle "$BACKTITLE" --title "Elegir directives.hdf" \
        --menu "Archivo a activar como directives/directives.hdf:" 20 78 10 \
        "${options[@]}" 3>&1 1>&2 2>&3) || return

    local src
    if [ "$choice" = "__manual__" ]; then
        src=$(whiptail --backtitle "$BACKTITLE" --title "Ruta manual" \
            --inputbox "Ruta completa al .hdf a activar:" 10 70 "" 3>&1 1>&2 2>&3) || return
    else
        src="$DIRECTIVES_DIR/$choice"
    fi

    if [ ! -f "$src" ]; then
        whiptail --backtitle "$BACKTITLE" --msgbox "No existe: $src" 8 70
        return
    fi
    if [ "$src" = "$ACTIVE_DIRECTIVES" ]; then
        whiptail --backtitle "$BACKTITLE" --msgbox "Ese archivo ya es el activo." 8 60
        return
    fi

    if whiptail --backtitle "$BACKTITLE" --yesno "Copiar:\n  $src\nsobre:\n  $ACTIVE_DIRECTIVES\n\n¿Continuar?" 12 78; then
        cp "$src" "$ACTIVE_DIRECTIVES"
        whiptail --backtitle "$BACKTITLE" --msgbox "Listo. Recuerda 'Publicar directivas + software' (opción del menú) para que el master las sirva." 9 78
    fi
}

edit_directives() {
    if [ ! -f "$ACTIVE_DIRECTIVES" ]; then
        whiptail --backtitle "$BACKTITLE" --msgbox "No existe $ACTIVE_DIRECTIVES todavía." 8 70
        return
    fi
    clear
    "${EDITOR:-nano}" "$ACTIVE_DIRECTIVES"
}

publish_directives() {
    if ! whiptail --backtitle "$BACKTITLE" --yesno "Esto monta la ISO de HuronOS (~5GB) y copia directives.hdf + el catálogo de software a boot/. Requiere sudo y puede tardar. ¿Continuar?" 11 78; then
        return
    fi
    run_live sudo "$PROJECT_DIR/scripts/02b-setup-directives.sh"
}

toggle_modes() {
    if [ ! -f "$ACTIVE_DIRECTIVES" ]; then
        whiptail --backtitle "$BACKTITLE" --msgbox "No existe $ACTIVE_DIRECTIVES todavía." 8 70
        return
    fi
    local event_cur contest_cur event_state contest_state selection
    event_cur="$(grep -oP '^EventConfig=\K.*' "$ACTIVE_DIRECTIVES" || echo false)"
    contest_cur="$(grep -oP '^ContestConfig=\K.*' "$ACTIVE_DIRECTIVES" || echo false)"
    [ "$event_cur" = "true" ] && event_state=ON || event_state=OFF
    [ "$contest_cur" = "true" ] && contest_state=ON || contest_state=OFF

    selection=$(whiptail --backtitle "$BACKTITLE" --title "Modo Event / Contest" \
        --checklist "Marca los modos que deben quedar habilitados en [Global] (Contest tiene prioridad sobre Event si se solapan las fechas -- ver directives.hdf):" 14 78 2 \
        "EventConfig" "Modo clase/práctica libre" "$event_state" \
        "ContestConfig" "Modo examen (bloqueo estricto)" "$contest_state" \
        3>&1 1>&2 2>&3) || return

    if echo "$selection" | grep -q "EventConfig"; then
        sed -i 's/^EventConfig=.*/EventConfig=true/' "$ACTIVE_DIRECTIVES"
    else
        sed -i 's/^EventConfig=.*/EventConfig=false/' "$ACTIVE_DIRECTIVES"
    fi
    if echo "$selection" | grep -q "ContestConfig"; then
        sed -i 's/^ContestConfig=.*/ContestConfig=true/' "$ACTIVE_DIRECTIVES"
    else
        sed -i 's/^ContestConfig=.*/ContestConfig=false/' "$ACTIVE_DIRECTIVES"
    fi
    whiptail --backtitle "$BACKTITLE" --msgbox "Actualizado. Recuerda 'Publicar directivas + software' para aplicarlo." 8 70
}

docker_action() {
    case "$1" in
        up) run_live bash -c "cd '$COMPOSE_DIR' && docker compose up -d" ;;
        down) run_live bash -c "cd '$COMPOSE_DIR' && docker compose down" ;;
        restart) run_live bash -c "cd '$COMPOSE_DIR' && docker compose restart" ;;
        logs) run_live bash -c "cd '$COMPOSE_DIR' && docker compose logs -f --tail=200" ;;
    esac
}

configure_network() {
    local iface
    iface=$(whiptail --backtitle "$BACKTITLE" --title "Configurar red" \
        --inputbox "Interfaz Ethernet hacia el MikroTik:" 10 70 "eth0" 3>&1 1>&2 2>&3) || return
    if ! whiptail --backtitle "$BACKTITLE" --yesno "Esto aplica IP estática ${MASTER_IP}/24 sobre '${iface}' vía nmcli. Si la interfaz es la equivocada puede cortar tu sesión SSH. ¿Continuar?" 11 78; then
        return
    fi
    run_live "$SCRIPT_DIR/setup-master.sh" --skip-boot-build --skip-docker --configure-network --iface "$iface"
}

full_setup() {
    local flags selection iface
    selection=$(whiptail --backtitle "$BACKTITLE" --title "Setup completo" \
        --checklist "Flags para setup-master.sh:" 15 78 4 \
        "--configure-network" "Aplicar IP estática (riesgo de cortar SSH)" OFF \
        "--build-kernel" "Compilar kernel-cache si falta (horas)" OFF \
        "--skip-boot-build" "No remontar la ISO ni regenerar boot/ (reinicio rápido)" ON \
        "--skip-docker" "No tocar el contenedor" OFF \
        3>&1 1>&2 2>&3) || return
    iface=$(whiptail --backtitle "$BACKTITLE" --inputbox "Interfaz Ethernet:" 10 70 "eth0" 3>&1 1>&2 2>&3) || return

    flags=()
    for opt in $selection; do
        flags+=("$(echo "$opt" | tr -d '"')")
    done
    run_live "$SCRIPT_DIR/setup-master.sh" --iface "$iface" "${flags[@]}"
}

show_links() {
    whiptail --backtitle "$BACKTITLE" --title "Enlaces de referencia" --msgbox "\
Documentación oficial de HuronOS:
  https://huronos.org/docs/introduction

Repo oficial de build de HuronOS (kernel, huronos.config, initramfs):
  https://github.com/equetzal/huronOS-build-tools

Ejemplos de directives.hdf:
  https://github.com/Orlanstein/huronos_directives

Guía de este laboratorio (pasos manuales completos):
  ${SCRIPT_DIR}/LABORATORIO-REAL.md" 18 78
}

while true; do
    CHOICE=$(whiptail --backtitle "$BACKTITLE" --title "Master de hardware real" \
        --menu "Elige una acción:" 22 78 13 \
        "1" "Estado del master (contenedor + HTTP)" \
        "2" "Ver logs en vivo" \
        "3" "Elegir / cambiar directives.hdf" \
        "4" "Editar directives.hdf" \
        "5" "Publicar directivas + software (sudo, monta ISO)" \
        "6" "Alternar modo Event / Contest" \
        "7" "Iniciar contenedor" \
        "8" "Detener contenedor" \
        "9" "Reiniciar contenedor" \
        "10" "Configurar red (IP estática)" \
        "11" "Setup completo (setup-master.sh)" \
        "12" "Enlaces / Wiki" \
        "0" "Salir" \
        3>&1 1>&2 2>&3) || { clear; exit 0; }

    case "$CHOICE" in
        1) show_status ;;
        2) docker_action logs ;;
        3) pick_directives ;;
        4) edit_directives ;;
        5) publish_directives ;;
        6) toggle_modes ;;
        7) docker_action up ;;
        8) docker_action down ;;
        9) docker_action restart ;;
        10) configure_network ;;
        11) full_setup ;;
        12) show_links ;;
        0) clear; exit 0 ;;
    esac
done
