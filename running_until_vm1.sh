#!/usr/bin/env bash
set -euo pipefail

scripts=(
  "./scripts/01-setup-network.sh"
  "./scripts/02-build-huronos-boot.sh"
  "./scripts/03-start-master.sh"
  "./scripts/04-start-slave1.sh"
)

for script in "${scripts[@]}"; do
  echo "Ejecutando: $script"
  bash "$script"
  echo "Terminado: $script"
done

echo "Todos los scripts finalizaron correctamente."
