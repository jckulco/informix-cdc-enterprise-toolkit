# Guía de instalación — `install_informix_cdc_source.sh`

**Autor:** Julio César García Hernández — [LinkedIn](https://www.linkedin.com/in/jcgarciahdz/)

## 1. Propósito

Instala **IBM Informix 14.10.FC11** y lo deja configurado como origen de **IBM InfoSphere Data Replication (CDC) 11.4**: usuario del SO, instalación silenciosa, licencia opcional, chunks, `onconfig`, dbspaces, sbspace, base de datos con logging, base `syscdcv1`, servicio `systemd` y verificaciones de red.

## 2. Prerrequisitos

| Elemento | Detalle |
|----------|---------|
| Usuario de ejecución | `root` (el script aborta en caso contrario) |
| SO | Familia RHEL (`dnf`/`yum`) o Debian/Ubuntu (`apt-get`) |
| Instalador IDS | `$SRC_DIR/INFM_DEV_V14.10.FC11_LNX_X86_64.zip` (obligatorio) |
| Licencia | `$SRC_DIR/INFM_ADV_ENTER_LIC_INS_V14.11.FC1.zip` (opcional; si falta se continúa con edición Developer) |
| Java | Se instala automáticamente (OpenJDK 8/11/17) si no existe en el `PATH` |

## 3. Ejecución

```bash
chmod +x scripts/install_informix_cdc_source.sh
sudo IFX_PASS='<contraseña_segura>' ./scripts/install_informix_cdc_source.sh
```

Ejemplo con parámetros personalizados:

```bash
sudo DB_NAME=ventas PORT=9089 SERVERNAME=ifxventas ./scripts/install_informix_cdc_source.sh
```

## 4. Fases del instalador

| # | Fase | Qué hace |
|---|------|----------|
| 1 | Paquetes | Instala dependencias (`unzip`, `libaio`, `ncurses`, `ksh`, …) y Java |
| 2 | Usuario | Crea grupo/usuario `informix`, fija contraseña; crea `CDC_USER` si es distinto |
| 3 | Instalación | Descomprime (incluso `.tar` anidados) y ejecuta `ids_install -i silent` |
| 4 | Licencia | Aplica el *edition installer* de Advanced Enterprise Edition (marca `.edition_license_applied`) |
| 5 | Entorno | Genera `~/.informix_env`, `/etc/profile.d/informix.sh` y `sqlhosts` |
| 6 | Chunks y `onconfig` | Crea chunks, parametriza `onconfig.<SERVERNAME>`, ajusta permisos y `setuid` de `oninit` |
| 7 | Inicialización | `oninit -ivy` y espera hasta estado *On-Line* (máx. 180 s) |
| 8 | Espacios | Crea `datadbs1`, `sbspace1`, `tempdbs1`; fija `SBSPACENAME`; archive nivel 0 con `ontape` |
| 9 | Base de datos | Crea `DB_NAME` con logging y tablas de ejemplo `clientes` y `pedidos` |
| 10 | `syscdcv1` | Ejecuta `$INFORMIXDIR/etc/syscdcv1.sql` (API de Change Data Capture) |
| 11 | Servicio y red | Unit `informix.service`, firewalld, SELinux, `AllowTcpForwarding`, prueba TCP |

## 5. Variables de entorno

| Variable | Defecto | Descripción |
|----------|---------|-------------|
| `SRC_DIR` | `/opt` | Ubicación de los `.zip` |
| `IDS_ZIP` / `LIC_ZIP` | según `SRC_DIR` | Rutas completas de instalador y licencia |
| `APPLY_LICENSE` | `yes` | `no` omite la licencia |
| `STAGE_DIR` | `/opt/stage_informix` | Descompresión temporal |
| `INFORMIXDIR` | `/opt/informix` | Destino de instalación |
| `IFX_USER` / `IFX_GROUP` / `IFX_HOME` | `informix` / `informix` / `/home/informix` | Identidad del propietario |
| `IFX_PASS` | `informix` | Contraseña del usuario del SO (**cambiar**) |
| `DATA_DIR` | `/data/informix` | Chunks y directorios de backup |
| `BACKUP_DIR_MODE` | `700` | Permisos del directorio de archive (`ontape` rechaza 770) |
| `CHUNK_MODE` | `660` | Permisos de chunks (requeridos con `oninit` setuid) |
| `SERVERNAME` / `SERVERNUM` | `ifxsrc` / `1` | Nombre y número de servidor |
| `PORT` | `9088` | Puerto `onsoctcp` |
| `LISTEN_ADDR` | `127.0.0.1` | `0.0.0.0` o una IP para exponer el servicio |
| `ROOT_SIZE`, `DATA_SIZE`, `SBSPACE_SIZE`, `TEMP_SIZE` | 1000000 / 1000000 / 1000000 / 500000 | Tamaños de chunk en KB |
| `DB_NAME` | `informix` | Base fuente |
| `CDC_USER` | `informix` | Usuario que usará IIDR (recibe `GRANT DBA` si es distinto) |

## 6. Requisitos de CDC cubiertos

- Base de datos con **logging** (`WITH LOG`).
- **sbspace** definido en `SBSPACENAME`.
- Base `syscdcv1` creada.
- Tablas con `PRIMARY KEY` recomendadas para replicación.
- Backup automático de logical logs (`BACKUPLOGS=Y`) para evitar bloqueos por logs llenos.

## 7. Acceso desde la estación local

```bash
ssh -N -L 9088:127.0.0.1:9088 <usuario_ssh>@<IP_DEL_SERVIDOR>
```

Parámetros de DBeaver (driver IBM Informix): host `localhost`, puerto `9088`, base `informix`, servidor `ifxsrc`.
URL JDBC:

```
jdbc:informix-sqli://localhost:9088/informix:INFORMIXSERVER=ifxsrc;DELIMIDENT=Y
```

El `sshd` debe tener `AllowTcpForwarding yes` (el script lo verifica y advierte).

## 8. Verificación posterior

```bash
su - informix -c 'onstat -'          # debe indicar On-Line
su - informix -c 'onstat -d'         # dbspaces y sbspace
ss -ltn | grep 9088                  # listener activo
tail -n 50 /var/log/install_informix_cdc.log
```

## 9. Reinicio y servicio

```bash
systemctl status informix.service
systemctl restart informix.service
```

## 10. Seguridad operativa

El resumen final y la bitácora contienen las credenciales. Restringe el acceso a `/var/log/install_informix_cdc.log` (`chmod 600`) o elimínalo tras la instalación.
