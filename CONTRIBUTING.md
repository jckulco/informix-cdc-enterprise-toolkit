# Guía de contribución

Gracias por tu interés en mejorar este proyecto, creado y mantenido por [Julio César García Hernández](https://www.linkedin.com/in/jcgarciahdz/).

## Cómo contribuir

1. Abre un *issue* describiendo el problema o la mejora.
2. Haz *fork* y crea una rama: `git checkout -b feature/descripcion-corta`.
3. Realiza tus cambios siguiendo las convenciones de abajo.
4. Envía un *pull request* explicando el cambio y cómo lo probaste.

## Convenciones

- Bash con `set -Eeuo pipefail`; validar sintaxis con `bash -n` y, si es posible, `shellcheck`.
- Scripts idempotentes siempre que sea viable.
- Variables configurables por entorno con valor por defecto.
- Mensajes y documentación en español.
- Commits claros, en imperativo (por ejemplo: `Agrega validación de espacio en disco`).
- No incluir credenciales, instaladores de IBM ni datos reales.
