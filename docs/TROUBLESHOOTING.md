# Solución de problemas

**Autor:** Julio César García Hernández — [LinkedIn](https://www.linkedin.com/in/jcgarciahdz/)

Registros útiles: `/var/log/install_informix_cdc.log` y `$INFORMIXDIR/tmp/online.log`.

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| `Ejecuta como root.` | Script lanzado sin privilegios | Usar `sudo` |
| `No existe <IDS_ZIP>` | Instalador no está en `SRC_DIR` | Copiar el `.zip` o definir `SRC_DIR` / `IDS_ZIP` |
| `No hay Java en el PATH` | No se pudo instalar OpenJDK | `dnf install java-11-openjdk-headless` y reejecutar |
| `No se encontró 'ids_install'` | Estructura de `.zip` distinta | `find /opt/stage_informix/ids -maxdepth 4` |
| `SECURITY PROBLEM ... path is not trusted` | `INFORMIXDIR` o `etc` modificable por el grupo | El script aplica `chmod 755` y `g-w,o-w`; reejecutar |
| `online.log`: permisos 660 en chunks | `oninit` setuid exige 660 | Mantener `CHUNK_MODE=660` |
| `ontape`: `Bad READ/WRITE permissions` | Directorio de archive con 770 | Mantener `BACKUP_DIR_MODE=700` |
| `errno 13` en `/data/...` | Ruta no atravesable por `informix` | El script aplica `o+x` a los directorios padre |
| Informix rechaza `onconfig` ("too secure") | Modo 600 | El script fija 660 |
| DBeaver: `is not known on the database server` | `oninit` sin setuid root (Private Server) | El script aplica `chown root:informix` + `chmod 6755`; no ejecutar `chown -R` posterior sobre `bin/` |
| Motor no llega a On-Line | Restos de memoria compartida | `su - informix -c 'onclean -ky'` y reejecutar |
| Túnel SSH falla | `AllowTcpForwarding no` | Cambiar a `yes` en `sshd_config` y `systemctl reload sshd` |
| Sin conexión remota | `LISTEN_ADDR=127.0.0.1` | Usar túnel SSH o `LISTEN_ADDR=0.0.0.0` (abre el puerto en firewalld) |
| Conflictos con SELinux | Modo *Enforcing* | `ausearch -m avc -ts recent` |
| Menú: `El motor Informix no esta On-Line` | Instancia detenida | `systemctl start informix.service` |
| Menú: `No se pudo abrir la base` | `DB_NAME` incorrecta | Revisar con `DB_NAME=<base>` |
| Replicación afectada tras limpiar | `RESET_SERIAL=yes` ejecutó DDL | Mantener `RESET_SERIAL=no` en tablas suscritas |

## Diagnóstico rápido

```bash
su - informix -c 'onstat -'
su - informix -c 'onstat -d'
su - informix -c 'onstat -m'
ss -ltn | grep 9088
```
