#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# IIDR Informix -> MongoDB demo data generator
# Tabla: customers (base de datos "informix", owner informix)
#
# Autor : Julio César García Hernández - https://www.linkedin.com/in/jcgarciahdz/
# Licencia: MIT
#
# Ejecutar EN EL SERVIDOR de Informix, como root o como el usuario informix.
# Si la tabla no existe, se crea automaticamente (tambien esta en el menu).
#
# Overrides opcionales:
#   DB_NAME=informix IFX_USER=informix TABLE=customers RESET_SERIAL=no \
#   ./iidr_customers_menu_informix.sh
#
# RESET_SERIAL=yes reinicia customer_id a 1 al limpiar la tabla. Usa un
# ALTER TABLE (DDL); sobre una tabla ya suscrita en IIDR puede afectar la
# replicacion, por eso el valor por defecto es "no".
# ================================================================

IFX_USER="${IFX_USER:-informix}"
DB_NAME="${DB_NAME:-informix}"
TABLE="${TABLE:-customers}"
RESET_SERIAL="${RESET_SERIAL:-no}"

TABLE_L="${TABLE,,}"   # Informix guarda los nombres en minusculas en systables

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "%b[INFO]%b %s\n" "$CYAN" "$NC" "$*"; }
ok()    { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$*"; }
warn()  { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*" >&2; }

pause() {
  printf "\n"
  read -r -p "Presiona Enter para volver al menu..." _
}

require_user() {
  if [[ "${EUID}" -ne 0 && "$(id -un)" != "$IFX_USER" ]]; then
    error "Ejecuta este script como root o como el usuario '$IFX_USER'."
    exit 1
  fi
}

# Ejecuta un comando con el entorno de Informix (login shell del usuario informix).
# stdin se conserva, asi se le puede pasar SQL por pipe o here-string.
ifx() {
  if [[ "$(id -un)" == "$IFX_USER" ]]; then
    bash -lc "$1"
  else
    su - "$IFX_USER" -c "$1"
  fi
}

# Lee SQL por stdin y lo ejecuta con dbaccess. Imprime la salida; falla si hay error.
run_sql() {
  local out rc=0
  out="$(ifx "dbaccess '$DB_NAME' -" 2>&1)" || rc=$?
  if (( rc != 0 )) || grep -qE 'Error in line|ISAM error' <<<"$out"; then
    error "dbaccess devolvio un error:"
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

sql() { run_sql <<<"$1"; }

# Extrae el primer numero solo en una linea de la salida de dbaccess (resultado de COUNT).
first_number() {
  awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { gsub(/[[:space:]]/, ""); print; exit }' <<<"$1"
}

check_environment() {
  id "$IFX_USER" >/dev/null 2>&1 || {
    error "No existe el usuario '$IFX_USER'. Este script debe correr en el servidor de Informix."
    exit 1
  }

  ifx 'command -v dbaccess >/dev/null 2>&1' || {
    error "No se encontro 'dbaccess' en el entorno de '$IFX_USER'."
    exit 1
  }

  local mode
  mode="$(ifx 'onstat - >/dev/null 2>&1; echo $?' 2>/dev/null | tail -n 1 || true)"
  if [[ "$mode" != "5" ]]; then
    error "El motor Informix no esta On-Line (onstat devolvio '$mode')."
    exit 1
  fi

  sql "SELECT COUNT(*) AS n FROM systables WHERE tabid = 1;" >/dev/null || {
    error "No se pudo abrir la base '$DB_NAME'."
    exit 1
  }

  ensure_table
}

table_exists() {
  local out
  out="$(sql "SELECT COUNT(*) AS n FROM systables WHERE tabname = '${TABLE_L}' AND tabtype = 'T';")" || return 2
  [[ "$(first_number "$out")" == "1" ]]
}

create_table() {
  sql "CREATE TABLE IF NOT EXISTS ${TABLE} (
  customer_id SERIAL       NOT NULL,
  full_name   VARCHAR(100) NOT NULL,
  email       VARCHAR(150),
  city        VARCHAR(60),
  PRIMARY KEY (customer_id)
) LOCK MODE ROW;" >/dev/null
}

ensure_table() {
  local rc=0
  table_exists || rc=$?
  if (( rc == 0 )); then
    return 0
  elif (( rc == 2 )); then
    error "No se pudo consultar el catalogo de la base '$DB_NAME'."
    exit 1
  fi
  info "La tabla ${TABLE} no existe en '$DB_NAME'. Creandola..."
  create_table || { error "No se pudo crear la tabla ${TABLE}."; exit 1; }
  ok "Tabla ${TABLE} creada (customer_id SERIAL PK, full_name, email, city)."
}

create_table_menu() {
  local rc=0
  table_exists || rc=$?
  if (( rc == 0 )); then
    ok "La tabla ${TABLE} ya existe."
  else
    create_table || return 1
    ok "Tabla ${TABLE} creada."
  fi
}

current_count() {
  local out n
  out="$(sql "SELECT COUNT(*) AS total FROM ${TABLE};")" || return 1
  n="$(first_number "$out")"
  [[ -n "$n" ]] || { error "No se pudo leer el conteo de ${TABLE}."; return 1; }
  printf '%s' "$n"
}

show_status() {
  local count server
  count="$(current_count)" || return 1
  server="$(ifx 'printf %s "${INFORMIXSERVER:-?}"' 2>/dev/null | tail -n 1 || true)"
  printf "\n"
  info "Servidor   : ${server:-?}"
  info "Base       : $DB_NAME"
  info "Tabla      : $TABLE"
  info "Registros  : $count"
  info "Reset de customer_id al limpiar: $RESET_SERIAL"
}

reset_serial() {
  if [[ "$RESET_SERIAL" == "yes" ]]; then
    sql "ALTER TABLE ${TABLE} MODIFY (customer_id SERIAL(1));" >/dev/null || return 1
    info "customer_id reiniciado a 1."
  else
    info "customer_id NO se reinicia (RESET_SERIAL=no, evita DDL sobre una tabla replicada)."
  fi
}

clean_table() {
  local before after answer
  before="$(current_count)" || return 1

  warn "Se eliminaran $before registros de ${TABLE}."
  read -r -p "Escribe SI para continuar: " answer
  if [[ "$answer" != "SI" ]]; then
    warn "Operacion cancelada."
    return 0
  fi

  info "Ejecutando DELETE para producir eventos de borrado capturables por IIDR..."
  sql "DELETE FROM ${TABLE};" >/dev/null || return 1
  reset_serial || return 1

  after="$(current_count)" || return 1
  ok "Tabla limpiada. Antes: $before | Ahora: $after"
}

insert_rows() {
  local amount="$1"
  local before after inserted ts
  before="$(current_count)" || return 1

  info "Insertando $amount registros dummy en ${TABLE}..."
  ts="$(date +%Y%m%d%H%M%S%3N)"

  # Informix no tiene generate_series/md5/arrays: se generan los INSERT con awk
  # y se ejecutan en UNA sola transaccion (BEGIN/COMMIT WORK).
  {
    echo "BEGIN WORK;"
    awk -v n="$amount" -v ts="$ts" -v tbl="$TABLE" -v seed="$(date +%s%N)" '
      BEGIN {
        srand(seed)
        nc = split("Ciudad de Mexico,Guadalajara,Monterrey,Puebla,Queretaro,Merida,Tijuana,Leon,Toluca,Aguascalientes", c, ",")
        for (g = 1; g <= n; g++) {
          h = ""
          for (k = 0; k < 20; k++) h = h sprintf("%x", int(rand() * 16))
          printf "INSERT INTO %s (full_name, email, city) VALUES (\047Cliente Demo %s-%d\047, \047cliente.%s@iidr-demo.local\047, \047%s\047);\n", \
                 tbl, ts, g, h, c[(g - 1) % nc + 1]
        }
      }'
    echo "COMMIT WORK;"
  } | run_sql >/dev/null || return 1

  after="$(current_count)" || return 1
  inserted=$((after - before))
  ok "Carga terminada. Antes: $before | Insertados: $inserted | Total: $after"
}

reset_and_load_1000() {
  local before after answer
  before="$(current_count)" || return 1

  warn "Esta opcion eliminara los $before registros actuales y cargara exactamente 1000 nuevos."
  read -r -p "Escribe SI para continuar: " answer
  if [[ "$answer" != "SI" ]]; then
    warn "Operacion cancelada."
    return 0
  fi

  info "Eliminando los registros actuales..."
  sql "DELETE FROM ${TABLE};" >/dev/null || return 1
  reset_serial || return 1

  insert_rows 1000 || return 1
  after="$(current_count)" || return 1
  ok "Carga base completada. Total actual: $after"
}

show_sample() {
  local out
  printf "\n"
  out="$(sql "SELECT FIRST 10 customer_id, full_name, email, city FROM ${TABLE} ORDER BY customer_id DESC;")" || return 1
  sed '/^[[:space:]]*$/d' <<<"$out"
}

show_menu() {
  local count
  count="$(current_count 2>/dev/null || echo '?')"
  clear || true
  printf "%b" "$CYAN"
  cat <<'BANNER'
============================================================
     IIDR Demo - Informix CUSTOMERS -> MongoDB
============================================================
BANNER
  printf "%b" "$NC"
  printf "Usuario: %s | Base: %s | Tabla: %s\n" "$IFX_USER" "$DB_NAME" "$TABLE"
  printf "Registros actuales: %s\n\n" "$count"
  cat <<'MENU'
1) Limpiar la tabla CUSTOMERS
2) Limpiar y cargar exactamente 1000 registros dummy
3) Agregar 10 registros
4) Agregar 100 registros
5) Agregar 1000 registros
6) Mostrar conteo y configuracion
7) Mostrar los ultimos 10 registros
8) Crear la tabla CUSTOMERS (si no existe)
0) Salir
MENU
  printf "\n"
}

# Las acciones del menu devuelven error sin tumbar el script; se informa y se vuelve al menu.
run_action() {
  "$@" || warn "La operacion no se completo (ver detalle arriba)."
}

main() {
  require_user
  check_environment

  while true; do
    show_menu
    read -r -p "Selecciona una opcion: " option
    printf "\n"

    case "$option" in
      1) run_action clean_table; pause ;;
      2) run_action reset_and_load_1000; pause ;;
      3) run_action insert_rows 10; pause ;;
      4) run_action insert_rows 100; pause ;;
      5) run_action insert_rows 1000; pause ;;
      6) run_action show_status; pause ;;
      7) run_action show_sample; pause ;;
      8) run_action create_table_menu; pause ;;
      0) ok "Fin de la prueba."; exit 0 ;;
      *) error "Opcion invalida: $option"; pause ;;
    esac
  done
}

main "$@"
