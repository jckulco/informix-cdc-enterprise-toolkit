# Política de seguridad

## Reporte de vulnerabilidades

No publiques vulnerabilidades en *issues* públicos. Contacta al autor de forma privada a través de [LinkedIn](https://www.linkedin.com/in/jcgarciahdz/) o mediante un *security advisory* privado del repositorio.

## Consideraciones conocidas

- La contraseña por defecto `IFX_PASS=informix` es solo para laboratorio; defínela por entorno.
- El resumen del instalador y `/var/log/install_informix_cdc.log` muestran credenciales: protege o elimina el archivo (`chmod 600`).
- `oninit` se configura `setuid root` (6755) por requerimiento de Informix para autenticar clientes remotos.
- Se recomienda mantener `LISTEN_ADDR=127.0.0.1` y acceder por túnel SSH.
- No uses estos scripts en producción sin revisión de seguridad.
