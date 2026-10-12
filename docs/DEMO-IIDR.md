# Guía de demostración — `iidr_customers_menu_informix.sh`

**Autor:** Julio César García Hernández — [LinkedIn](https://www.linkedin.com/in/jcgarciahdz/)

## 1. Propósito

Menú interactivo que genera operaciones DML (`INSERT` y `DELETE`) sobre la tabla `customers` de Informix para demostrar la captura y replicación de cambios con IIDR (por ejemplo, hacia MongoDB).

## 2. Ejecución

Debe correr **en el servidor de Informix**, como `root` o como el usuario `informix`:

```bash
sudo ./scripts/iidr_customers_menu_informix.sh
```

Con sobreescrituras opcionales:

```bash
sudo DB_NAME=informix IFX_USER=informix TABLE=customers RESET_SERIAL=no \
  ./scripts/iidr_customers_menu_informix.sh
```

## 3. Variables

| Variable | Defecto | Descripción |
|----------|---------|-------------|
| `IFX_USER` | `informix` | Usuario propietario de la instancia |
| `DB_NAME` | `informix` | Base de datos |
| `TABLE` | `customers` | Tabla de trabajo |
| `RESET_SERIAL` | `no` | `yes` reinicia `customer_id` a 1 al limpiar (usa `ALTER TABLE`, DDL) |

> **Importante:** con `RESET_SERIAL=yes` se ejecuta DDL sobre una tabla posiblemente suscrita en IIDR, lo que puede afectar la replicación. Por eso el valor por defecto es `no`.

## 4. Esquema de la tabla

```sql
CREATE TABLE IF NOT EXISTS customers (
  customer_id SERIAL       NOT NULL,
  full_name   VARCHAR(100) NOT NULL,
  email       VARCHAR(150),
  city        VARCHAR(60),
  PRIMARY KEY (customer_id)
) LOCK MODE ROW;
```

Se crea automáticamente al iniciar si no existe (también mediante la opción 8).

## 5. Opciones del menú

| Opción | Descripción | Evento en IIDR |
|--------|-------------|----------------|
| 1 | Limpia la tabla con `DELETE` (pide confirmación `SI`) | Borrados |
| 2 | Limpia y carga exactamente 1000 registros | Borrados + inserciones |
| 3 | Agrega 10 registros | Inserciones |
| 4 | Agrega 100 registros | Inserciones |
| 5 | Agrega 1000 registros | Inserciones |
| 6 | Muestra servidor, base, tabla, conteo y `RESET_SERIAL` | — |
| 7 | Muestra los últimos 10 registros | — |
| 8 | Crea la tabla si no existe | — |
| 0 | Salir | — |

## 6. Detalles de implementación

- Se usa `DELETE` (no `TRUNCATE`) para que existan eventos de borrado capturables por IIDR.
- Informix no dispone de `generate_series`, `md5` ni arreglos: los `INSERT` se generan con `awk` y se ejecutan en **una sola transacción** (`BEGIN WORK` / `COMMIT WORK`).
- Datos sintéticos: `Cliente Demo <timestamp>-<n>`, correo `cliente.<hash>@iidr-demo.local` y ciudades de México rotativas.
- Las consultas se ejecutan con `dbaccess` bajo el entorno de login del usuario `informix`; cualquier `Error in line` o `ISAM error` se reporta y no interrumpe el menú.
- Validación de entorno al arranque: usuario, `dbaccess`, motor On-Line (`onstat -` ⇒ código 5) y acceso a la base.

## 7. Flujo de demostración sugerido

1. Instalar Informix con el script de instalación.
2. Configurar el origen y la suscripción de `customers` en IIDR (destino p. ej. MongoDB).
3. Opción **2**: carga base de 1000 registros → verificar la replicación inicial.
4. Opciones **3/4/5**: cargas incrementales → verificar latencia y conteos.
5. Opción **1**: borrado → verificar que el destino refleja los `DELETE`.
