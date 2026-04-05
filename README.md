# AHME - Anime Helper for Mediafire Extractor

**AHME** es un script para terminal que permite descargar episodios de anime desde **jkanime.net** usando el servidor **Mediafire**. Incluye búsqueda interactiva, gestión de base de datos, reproducción de episodios descargados y un sistema de configuración para borrado automático.

## Características

-  **Búsqueda** de animes con selección interactiva (`fzf`).
-  **Descarga por rangos** (capítulo único o secuencial).
-  **Base de datos SQLite** para recordar el último capítulo descargado.
-  **Reproducción directa** de episodios descargados (con `mpv` o `vlc`).
-  **Menú de configuración**:
  - Borrado automático después de reproducir.
  - Limpieza programada por antigüedad (días).
-  **Robustez**:
  - Reintentos automáticos (3 intentos).
  - Validación de códigos HTTP.
  - Sanitización de nombres de archivo (`slug_001.mp4`).
  - Verificación de que el archivo descargado no sea HTML.
-  **Interfaz amigable** con `fzf` para selección y búsqueda.

##  Dependencias

- curl
- pup
- sqlite3
- fzf
- mpv
- file

## Uso
| Comando | Descripción |
|---------|-------------|
| `ahme -d` | Muestra la base de datos y permite seleccionar un anime para continuar descargando desde el último capítulo+1. |
| `ahme -p` | Lista los episodios descargados de un anime y los reproduce (con opción de borrado). |
| `ahme -c` | Abre el menú de configuración (borrado automático, retención). |
| `ahme -h` | Muestra la ayuda. |
| `ahme "dragon ball"` | Busca animes que coincidan con el término y permite seleccionar uno para descargar. |
| `ahme one-piece 10` | Descarga directamente el capítulo 10 de one-piece (si el slug es exacto). Si no existe, busca coincidencias. |

## Solución de problemas
Error: No se encontraron archivos de ...

    Asegúrate de que los episodios se descargaron con el script (usan el formato slug_XXX.mp4). Si tenías archivos antiguos, renómbralos manualmente.

    Verifica que el slug del anime coincida con el prefijo del archivo (sin espacios, todo minúsculas).

Error: El archivo descargado es HTML

    Mediafire puede cambiar sus enlaces. Actualiza los patrones de grep en la función obtener_url_mediafire_de_capitulo.

    Ejecuta el script con bash -x ahme.sh ... para depurar el enlace extraído.

El reproductor no se abre

    Instala mpv (sudo pacman -S mpv) o vlc. El script los detecta automáticamente.
    
