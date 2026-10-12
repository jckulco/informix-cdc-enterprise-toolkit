#!/usr/bin/env bash
#==============================================================================
# install_informix_cdc_source.sh
# Instala Informix 14.10.FC11 y lo deja listo como SOURCE de
# IBM InfoSphere Data Replication (CDC) 11.4.
#
# Autor : Julio César García Hernández - https://www.linkedin.com/in/jcgarciahdz/
# Licencia: MIT
#
# Uso:   chmod +x install_informix_cdc_source.sh && ./install_informix_cdc_source.sh
# Todas las variables se pueden sobreescribir por entorno, ej.:
#   DB_NAME=ventas PORT=9089 ./install_informix_cdc_source.sh
#
# Es idempotente en lo posible: puedes re-ejecutarlo y saltará los pasos ya hechos.
#==============================================================================
set -Eeuo pipefail

#------------------------------ VARIABLES -------------------------------------
SRC_DIR="${SRC_DIR:-/opt}"
IDS_ZIP="${IDS_ZIP:-$SRC_DIR/INFM_DEV_V14.10.FC11_LNX_X86_64.zip}"
LIC_ZIP="${LIC_ZIP:-$SRC_DIR/INFM_ADV_ENTER_LIC_INS_V14.11.FC1.zip}"
APPLY_LICENSE="${APPLY_LICENSE:-yes}"

STAGE_DIR="${STAGE_DIR:-/opt/stage_informix}"        # descompresión temporal
INFORMIXDIR="${INFORMIXDIR:-/opt/informix}"          # destino de instalación
IFX_USER="${IFX_USER:-informix}"
IFX_GROUP="${IFX_GROUP:-informix}"
IFX_HOME="${IFX_HOME:-/home/$IFX_USER}"
IFX_PASS="${IFX_PASS:-informix}"                     # password del usuario OS (y de login remoto por DBeaver)

DATA_DIR="${DATA_DIR:-/data/informix}"               # chunks, backups
BACKUP_DIR_MODE="${BACKUP_DIR_MODE:-700}"              # ontape -s rechaza 770 en el directorio de archive ("Bad READ/WRITE permissions"); 700 funciona
CHUNK_MODE="${CHUNK_MODE:-660}"                    # con oninit setuid root el motor exige 660 en los chunks (online.log: "must have READ/WRITE permissions for owner and group (660)")
SERVERNAME="${SERVERNAME:-ifxsrc}"
SERVERNUM="${SERVERNUM:-1}"
PORT="${PORT:-9088}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1}"              # 127.0.0.1 = solo local (acceso vía túnel SSH). Usa 0.0.0.0 o una IP para exponerlo
ONCONFIG_FILE="onconfig.${SERVERNAME}"

# Tamaños en KB
ROOT_SIZE="${ROOT_SIZE:-1000000}"
DATA_SIZE="${DATA_SIZE:-1000000}"
SBSPACE_SIZE="${SBSPACE_SIZE:-1000000}"
TEMP_SIZE="${TEMP_SIZE:-500000}"

DB_NAME="${DB_NAME:-informix}"
DB_DBSPACE="datadbs1"
CDC_USER="${CDC_USER:-informix}"    # usuario OS con el que se conectará IIDR

LOG="/var/log/install_informix_cdc.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

#------------------------------ HELPERS ---------------------------------------
info() { echo -e "\n[$(date +%H:%M:%S)] ==> $*"; }
warn() { echo -e "[$(date +%H:%M:%S)] [WARN] $*"; }
die()  { echo -e "[$(date +%H:%M:%S)] [ERROR] $*" >&2; exit 1; }
trap 'die "Falló en la línea $LINENO (comando: $BASH_COMMAND). Revisa $LOG"' ERR

as_ifx() { su - "$IFX_USER" -c "$1"; }

set_onconfig() {  # set_onconfig PARAM VALOR  (reemplaza la línea existente, incluso si viene sin valor)
  local f="$INFORMIXDIR/etc/$ONCONFIG_FILE"
  if grep -qE "^$1([[:space:]]|\$)" "$f"; then
    sed -i -E "s|^$1([[:space:]].*)?\$|$1 $2|" "$f"
  else
    echo "$1 $2" >> "$f"
  fi
}

# Estado del motor: onstat - devuelve exit code 5 cuando está On-Line (se captura la salida primero, sin pipes con grep -q,
# para que 'set -o pipefail' no genere falsos negativos por SIGPIPE)
is_online() {
  local out
  out="$(as_ifx 'onstat - 2>&1; echo "RC=$?"' 2>/dev/null || true)"
  [[ "$out" == *"RC=5"* ]] || [[ "$out" == *"On-Line"* ]]
}

wait_online() {
  local i
  for i in $(seq 1 90); do
    if is_online; then return 0; fi
    sleep 2
  done
  return 1
}

# Descomprime todos los .tar/.tgz de un directorio, incluso anidados (el zip trae un tar que contiene otro tar)
unpack_nested() {  # unpack_nested DIR
  local dir="$1" round t found
  for round in 1 2 3 4; do
    found=0
    while IFS= read -r t; do
      [[ -e "$t.done" ]] && continue
      case "$t" in
        *.zip) mkdir -p "${t%.zip}_x"; unzip -oq "$t" -d "${t%.zip}_x" ;;
        *)     mkdir -p "${t%.tar*}_x"; tar -xf "$t" -C "${t%.tar*}_x" ;;
      esac
      touch "$t.done"; found=1
    done < <(find "$dir" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' \))
    [[ $found -eq 1 ]] || break
  done
}

[[ $EUID -eq 0 ]] || die "Ejecuta como root."
[[ -f "$IDS_ZIP" ]] || die "No existe $IDS_ZIP"

#------------------------------ 1. PAQUETES -----------------------------------
info "1/11 Instalando paquetes requeridos"
if command -v dnf >/dev/null 2>&1; then PM="dnf -y install"
elif command -v yum >/dev/null 2>&1; then PM="yum -y install"
elif command -v apt-get >/dev/null 2>&1; then PM="apt-get -y install"; apt-get update -y || true
else die "Gestor de paquetes no soportado"; fi

if command -v apt-get >/dev/null 2>&1; then
  PKGS="unzip tar libaio1 libncurses5 libpam0g libstdc++6 bc ksh net-tools"
else
  PKGS="unzip tar libaio ncurses ncurses-compat-libs pam libgcc libstdc++ libnsl libxcrypt-compat bc ksh net-tools procps-ng"
fi
for p in $PKGS; do $PM "$p" >/dev/null 2>&1 || warn "No se pudo instalar '$p' (puede no existir en esta distro; se continúa)"; done

# Java: ids_install (InstallAnywhere) necesita una JVM en el PATH
if ! command -v java >/dev/null 2>&1; then
  info "Instalando Java (requerido por el instalador de Informix)"
  if command -v apt-get >/dev/null 2>&1; then JAVA_PKGS="openjdk-8-jre-headless openjdk-11-jre-headless openjdk-17-jre-headless"
  else JAVA_PKGS="java-1.8.0-openjdk-headless java-11-openjdk-headless java-17-openjdk-headless"; fi
  for j in $JAVA_PKGS; do
    if $PM "$j" >/dev/null 2>&1; then echo "Java instalado: $j"; break; else warn "No se pudo instalar $j"; fi
  done
fi
command -v java >/dev/null 2>&1 || die "No hay Java en el PATH. Instala uno manualmente (ej. dnf install java-11-openjdk-headless) y vuelve a ejecutar."
echo "Java en uso: $(java -version 2>&1 | head -1)"

#------------------------------ 2. USUARIO ------------------------------------
info "2/11 Creando grupo/usuario $IFX_USER"
getent group "$IFX_GROUP" >/dev/null || groupadd "$IFX_GROUP"
if ! id "$IFX_USER" >/dev/null 2>&1; then
  useradd -m -d "$IFX_HOME" -g "$IFX_GROUP" -s /bin/bash "$IFX_USER"
fi
# Password fija (se reaplica en cada ejecución). Informix autentica conexiones remotas contra el usuario OS.
echo "$IFX_USER:$IFX_PASS" | chpasswd
info "Password del usuario OS $IFX_USER establecida"

# Si IIDR usará otro usuario OS distinto a informix, se crea y se agrega al grupo
if [[ "$CDC_USER" != "$IFX_USER" ]] && ! id "$CDC_USER" >/dev/null 2>&1; then
  useradd -m -g "$IFX_GROUP" -s /bin/bash "$CDC_USER"
  echo "$CDC_USER:$IFX_PASS" | chpasswd
  info "Usuario $CDC_USER creado con la misma password"
fi

#------------------------------ 3. INSTALACIÓN --------------------------------
info "3/11 Instalando Informix en $INFORMIXDIR"
if [[ -x "$INFORMIXDIR/bin/oninit" ]]; then
  info "Informix ya instalado, se omite."
else
  rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR/ids"
  unzip -oq "$IDS_ZIP" -d "$STAGE_DIR/ids"
  unpack_nested "$STAGE_DIR/ids"
  INST="$(find "$STAGE_DIR/ids" -name ids_install -type f | head -1 || true)"
  [[ -n "$INST" ]] || die "No se encontró 'ids_install' dentro de $IDS_ZIP. Revisa: find $STAGE_DIR/ids -maxdepth 4"
  chmod -R a+rX "$STAGE_DIR"; chmod +x "$INST"
  mkdir -p "$INFORMIXDIR"
  ( cd "$(dirname "$INST")" && ./ids_install -i silent \
      -DUSER_INSTALL_DIR="$INFORMIXDIR" \
      -DLICENSE_ACCEPTED=TRUE )
  [[ -x "$INFORMIXDIR/bin/oninit" ]] || die "La instalación no dejó $INFORMIXDIR/bin/oninit"
fi
chown -R "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR"

#------------------------------ 4. LICENCIA -----------------------------------
info "4/11 Aplicando licencia (Advanced Enterprise Edition)"
LIC_MARK="$INFORMIXDIR/etc/.edition_license_applied"
if [[ "$APPLY_LICENSE" != "yes" ]]; then
  warn "Licencia omitida (APPLY_LICENSE=$APPLY_LICENSE)."
elif [[ -f "$LIC_MARK" ]]; then
  info "La licencia ya fue aplicada anteriormente, se omite."
elif [[ ! -f "$LIC_ZIP" ]]; then
  warn "No existe $LIC_ZIP; se continúa con la edición Developer."
else
  rm -rf "$STAGE_DIR/lic"; mkdir -p "$STAGE_DIR/lic"
  unzip -oq "$LIC_ZIP" -d "$STAGE_DIR/lic"
  unpack_nested "$STAGE_DIR/lic"
  chmod a+rx "$STAGE_DIR"; chmod -R a+rX "$STAGE_DIR/lic"
  EDJAR="$(find "$STAGE_DIR/lic" -name 'aee_edition.jar' -type f | head -1 || true)"
  [[ -n "$EDJAR" ]] || EDJAR="$(find "$STAGE_DIR/lic" -name '*_edition.jar' -type f | head -1 || true)"
  if [[ -z "$EDJAR" ]]; then
    find "$STAGE_DIR/lic" ! -name '*.done' | sed 's/^/   /'
    die "No se encontró el .jar del edition installer dentro de $LIC_ZIP"
  fi
  JBIN="$INFORMIXDIR/jvm/jre/bin/java"; [[ -x "$JBIN" ]] || JBIN="$(command -v java)"
  echo "Edition installer: $EDJAR  (JVM: $JBIN)"
  # El README indica ejecutarlo como el usuario informix (dueño de la instalación)
  chown -R "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR"
  as_ifx "cd '$(dirname "$EDJAR")' && '$JBIN' -jar '$(basename "$EDJAR")' -DUSER_INSTALL_DIR='$INFORMIXDIR' -DLICENSE_ACCEPTED=TRUE -i silent" \
    || die "El edition installer falló. Revisa la salida anterior."
  touch "$LIC_MARK"
  chown -R "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR"
  info "Licencia aplicada"
fi

# Informix valida que $INFORMIXDIR no sea modificable por el grupo (si no: "SECURITY PROBLEM ... path is not trusted")
chown "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR"
chmod 755 "$INFORMIXDIR"
chmod g-w,o-w "$INFORMIXDIR/etc" 2>/dev/null || true

#------------------------------ 5. ENTORNO ------------------------------------
info "5/11 Configurando entorno, sqlhosts y servicios"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; HOST_IP="${HOST_IP:-127.0.0.1}"

cat > "$IFX_HOME/.informix_env" <<EOF
export INFORMIXDIR=$INFORMIXDIR
export INFORMIXSERVER=$SERVERNAME
export ONCONFIG=$ONCONFIG_FILE
export INFORMIXSQLHOSTS=\$INFORMIXDIR/etc/sqlhosts
export DB_LOCALE=en_US.utf8
export CLIENT_LOCALE=en_US.utf8
export PATH=\$INFORMIXDIR/bin:\$PATH
export LD_LIBRARY_PATH=\$INFORMIXDIR/lib:\$INFORMIXDIR/lib/esql:\${LD_LIBRARY_PATH:-}
EOF
grep -q '.informix_env' "$IFX_HOME/.bash_profile" 2>/dev/null || \
  echo '[ -f ~/.informix_env ] && . ~/.informix_env' >> "$IFX_HOME/.bash_profile"
chown "$IFX_USER:$IFX_GROUP" "$IFX_HOME/.informix_env" "$IFX_HOME/.bash_profile"

echo "$SERVERNAME onsoctcp $LISTEN_ADDR $PORT" > "$INFORMIXDIR/etc/sqlhosts"
chown "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR/etc/sqlhosts"; chmod 644 "$INFORMIXDIR/etc/sqlhosts"

# Para que IIDR (u otro usuario) vea el entorno
cat > /etc/profile.d/informix.sh <<EOF
export INFORMIXDIR=$INFORMIXDIR
export INFORMIXSERVER=$SERVERNAME
export ONCONFIG=$ONCONFIG_FILE
export INFORMIXSQLHOSTS=\$INFORMIXDIR/etc/sqlhosts
export PATH=\$INFORMIXDIR/bin:\$PATH
EOF

#------------------------------ 6. CHUNKS Y ONCONFIG --------------------------
info "6/11 Creando chunks y archivo onconfig"
mkdir -p "$DATA_DIR/backup" "$DATA_DIR/logbackup"
# El usuario informix debe poder atravesar toda la ruta (con umask 077 /data queda 700 root y da errno 13)
_d="$(dirname "$DATA_DIR")"
while [[ "$_d" != "/" && "$_d" != "." ]]; do chmod o+x "$_d" 2>/dev/null || true; _d="$(dirname "$_d")"; done
for f in rootdbs.000 datadbs1.000 sbspace1.000 tempdbs1.000; do
  [[ -f "$DATA_DIR/$f" ]] || touch "$DATA_DIR/$f"
done
chown -R "$IFX_USER:$IFX_GROUP" "$DATA_DIR"
chmod "$CHUNK_MODE" "$DATA_DIR"/*.000; chmod 770 "$DATA_DIR" "$DATA_DIR/logbackup"; chmod "$BACKUP_DIR_MODE" "$DATA_DIR/backup"

if ! is_online; then
  # Motor apagado: se regenera el onconfig desde la plantilla para evitar restos de intentos previos
  cp -f "$INFORMIXDIR/etc/onconfig.std" "$INFORMIXDIR/etc/$ONCONFIG_FILE"
fi
set_onconfig ROOTNAME        rootdbs
set_onconfig ROOTPATH        "$DATA_DIR/rootdbs.000"
set_onconfig ROOTOFFSET      0
set_onconfig ROOTSIZE        "$ROOT_SIZE"
set_onconfig SERVERNUM       "$SERVERNUM"
set_onconfig DBSERVERNAME    "$SERVERNAME"
set_onconfig MSGPATH         "$INFORMIXDIR/tmp/online.log"
set_onconfig TAPEDEV         "$DATA_DIR/backup"
set_onconfig TAPESIZE        0
set_onconfig LTAPEDEV        "$DATA_DIR/logbackup"
set_onconfig LTAPESIZE       0
set_onconfig LOGFILES        10
set_onconfig LOGSIZE         20000
set_onconfig PHYSFILE        100000
# Backup automático de logical logs (evita que el motor se bloquee con logs llenos)
sed -i -E 's/^BACKUPLOGS=.*/BACKUPLOGS=Y/' "$INFORMIXDIR/etc/alarmprogram.sh" || true
chown -R "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR/etc"
chmod 660 "$INFORMIXDIR/etc/$ONCONFIG_FILE"   # Informix rechaza modo 600 ("too secure")
# oninit debe ser setuid root (root:informix, 6755). Sin esto el motor corre como "Private Server"
# y no puede validar usuario/password de clientes remotos (DBeaver: "is not known on the database server").
# El chown -R de arriba quita el setuid, por eso se reaplica aquí, después de todos los chown.
chown root:"$IFX_GROUP" "$INFORMIXDIR/bin/oninit"
chmod 6755 "$INFORMIXDIR/bin/oninit"
mkdir -p "$INFORMIXDIR/tmp"; chown "$IFX_USER:$IFX_GROUP" "$INFORMIXDIR/tmp"

#------------------------------ 7. INICIALIZACIÓN -----------------------------
info "7/11 Inicializando el motor (oninit -ivy)"
if is_online; then
  info "El motor ya está On-Line, se omite oninit."
else
  as_ifx "onclean -ky" >/dev/null 2>&1 || true     # limpia memoria compartida de intentos fallidos previos
  if ! as_ifx "oninit -ivy"; then
    echo "------ últimas líneas de $INFORMIXDIR/tmp/online.log ------"
    tail -n 60 "$INFORMIXDIR/tmp/online.log" 2>/dev/null || true
    echo "-----------------------------------------------------------"
    die "oninit falló. Revisa el online.log mostrado arriba."
  fi
  if ! wait_online; then
    tail -n 60 "$INFORMIXDIR/tmp/online.log" 2>/dev/null || true
    die "El motor no llegó a On-Line. Revisa $INFORMIXDIR/tmp/online.log"
  fi
fi

#------------------------------ 8. DBSPACES, SBSPACE, ARCHIVE -----------------
info "8/11 Creando dbspaces / sbspace / temp y parámetros para CDC"
db_exists() { local o; o="$(as_ifx "echo \"select name from sysmaster:sysdatabases where name='$1'\" | dbaccess sysmaster -" 2>/dev/null || true)"; grep -qw "$1" <<<"$o"; }
has_space() { local o; o="$(as_ifx "onstat -d" 2>/dev/null || true)"; grep -qw "$1" <<<"$o"; }

has_space "$DB_DBSPACE" || as_ifx "onspaces -c -d $DB_DBSPACE  -p $DATA_DIR/datadbs1.000  -o 0 -s $DATA_SIZE"
has_space "sbspace1"    || as_ifx "onspaces -c -S sbspace1     -p $DATA_DIR/sbspace1.000  -o 0 -s $SBSPACE_SIZE"
has_space "tempdbs1"    || as_ifx "onspaces -c -d tempdbs1 -t  -p $DATA_DIR/tempdbs1.000  -o 0 -s $TEMP_SIZE"

# CDC requiere un sbspace definido en SBSPACENAME
as_ifx "onmode -wf SBSPACENAME=sbspace1"
as_ifx "onmode -wf SBSPACETEMP=tempdbs1" || true
as_ifx "onmode -wf DBSPACETEMP=tempdbs1" || warn "No se pudo fijar DBSPACETEMP en caliente; agrégalo al onconfig y reinicia."

# Archive nivel 0 (requerido tras crear dbspaces/sbspaces)
if compgen -G "$DATA_DIR/backup/*_L0" >/dev/null; then
  info "Ya existe un archive nivel 0 en $DATA_DIR/backup, se omite."
else
  as_ifx "ontape -s -L 0 -d" </dev/null || warn "ontape nivel 0 falló; ejecútalo manualmente: su - $IFX_USER -c 'ontape -s -L 0 -d'"
fi

#------------------------------ 9. BASE DE DATOS ------------------------------
info "9/11 Creando base de datos $DB_NAME con logging"
if db_exists "$DB_NAME"; then
  info "La BD $DB_NAME ya existe."
else
  as_ifx "dbaccess - - <<'SQL'
CREATE DATABASE $DB_NAME IN $DB_DBSPACE WITH LOG;   -- logging UNBUFFERED (requerido por CDC)
SQL"
  as_ifx "dbaccess $DB_NAME - <<'SQL'
-- Tablas de ejemplo para el laboratorio (con PRIMARY KEY: recomendado para replicación)
CREATE TABLE clientes (
  id_cliente  SERIAL PRIMARY KEY,
  nombre      VARCHAR(80)  NOT NULL,
  email       VARCHAR(120),
  creado      DATETIME YEAR TO SECOND DEFAULT CURRENT YEAR TO SECOND
);
CREATE TABLE pedidos (
  id_pedido   SERIAL PRIMARY KEY,
  id_cliente  INTEGER NOT NULL,
  monto       DECIMAL(12,2),
  fecha       DATE DEFAULT TODAY
);
INSERT INTO clientes(nombre,email) VALUES ('Cliente Uno','uno@demo.com');
INSERT INTO clientes(nombre,email) VALUES ('Cliente Dos','dos@demo.com');
INSERT INTO pedidos(id_cliente,monto) VALUES (1,100.50);
SQL"
fi

# Permisos del usuario que usará IIDR
if [[ "$CDC_USER" != "$IFX_USER" ]]; then
  as_ifx "dbaccess $DB_NAME - <<SQL
GRANT DBA TO $CDC_USER;
SQL"
fi

#------------------------------ 10. syscdcv1 ----------------------------------
info "10/11 Creando base syscdcv1 (Change Data Capture API)"
if db_exists syscdcv1; then
  info "syscdcv1 ya existe."
else
  as_ifx "dbaccess - \$INFORMIXDIR/etc/syscdcv1.sql"
fi

#------------------------------ 11. SERVICIO + FIREWALL -----------------------
info "11/11 Servicio systemd y firewall"
cat > /etc/systemd/system/informix.service <<EOF
[Unit]
Description=IBM Informix $SERVERNAME
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$IFX_USER
Environment=INFORMIXDIR=$INFORMIXDIR INFORMIXSERVER=$SERVERNAME ONCONFIG=$ONCONFIG_FILE INFORMIXSQLHOSTS=$INFORMIXDIR/etc/sqlhosts
ExecStart=$INFORMIXDIR/bin/oninit -vy
ExecStop=$INFORMIXDIR/bin/onmode -ky
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable informix.service >/dev/null 2>&1 || true

# Acceso externo: el diseño es por TÚNEL SSH (solo el 22 expuesto); Informix escucha en $LISTEN_ADDR:$PORT
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ "$LISTEN_ADDR" != "127.0.0.1" ]]; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" && firewall-cmd --reload
    info "Puerto ${PORT}/tcp abierto en firewalld"
  else
    info "firewalld activo y Informix solo escucha en loopback: no se abre el puerto $PORT (se accede por túnel SSH)"
  fi
else
  info "firewalld inactivo (modo demo)."
fi
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  warn "SELinux está en Enforcing. Si algo no conecta, revisa: ausearch -m avc -ts recent"
fi

# El túnel SSH requiere AllowTcpForwarding habilitado en sshd
if command -v sshd >/dev/null 2>&1; then
  FWD="$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding/ {print $2}')"
  if [[ "$FWD" == "no" || "$FWD" == "remote" ]]; then
    warn "sshd tiene AllowTcpForwarding=$FWD; el túnel de DBeaver fallará. Cámbialo a 'yes' en /etc/ssh/sshd_config y ejecuta: systemctl reload sshd"
  else
    echo "OK: sshd permite port forwarding (AllowTcpForwarding=${FWD:-yes})"
  fi
fi

CHECK_IP="$LISTEN_ADDR"; [[ "$CHECK_IP" == "0.0.0.0" ]] && CHECK_IP="127.0.0.1"
info "Verificando que el listener de Informix responda en $CHECK_IP:$PORT"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  echo "OK: puerto $PORT en escucha:"; ss -ltn | grep -E "[:.]${PORT}[[:space:]]" || true
else
  warn "No se ve el puerto $PORT en escucha. Revisa $INFORMIXDIR/tmp/online.log y $INFORMIXDIR/etc/sqlhosts"
fi
if (exec 3<>/dev/tcp/"$CHECK_IP"/"$PORT") 2>/dev/null; then
  echo "OK: conexión TCP a $CHECK_IP:$PORT exitosa"
else
  warn "No se pudo abrir conexión TCP a $CHECK_IP:$PORT"
fi

#------------------------------ RESUMEN ---------------------------------------
echo
echo "=============================== RESUMEN ================================="
as_ifx "onstat -V" | head -3 || true
as_ifx "onstat -" | head -2 || true
echo "Servidor      : $SERVERNAME  (escucha en $LISTEN_ADDR:$PORT, onsoctcp; host $HOST_IP)"
echo "INFORMIXDIR   : $INFORMIXDIR"
echo "Base fuente   : $DB_NAME (logging unbuffered) + syscdcv1"
echo "SBSPACENAME   : sbspace1"
echo "Usuario IIDR  : $CDC_USER"
echo "Log instalador: $LOG"
echo "Login OS/BD   : $IFX_USER / $IFX_PASS"
echo
echo "---- Conexión desde tu máquina local (túnel SSH) ----"
echo "Opción A (terminal):  ssh -N -L ${PORT}:127.0.0.1:${PORT} <usuario_ssh>@$HOST_IP"
echo "Opción B (DBeaver) :  pestaña SSH -> Host $HOST_IP, puerto 22, tu usuario/llave SSH"
echo "DBeaver (pestaña Main, driver IBM Informix):"
echo "   Host: localhost   Puerto: $PORT   Base de datos: $DB_NAME   Server: $SERVERNAME"
echo "   Usuario/Pass: $IFX_USER / $IFX_PASS"
echo "URL JDBC: jdbc:informix-sqli://localhost:$PORT/$DB_NAME:INFORMIXSERVER=$SERVERNAME;DELIMIDENT=Y"
echo "========================================================================="
