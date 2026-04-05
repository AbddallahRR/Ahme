#!/bin/bash
set -euo pipefail

# ╔══════════════════════════════════════════════════╗
# ║  Descargador de anime desde la terminal          ║
# ║  Sitio: jkanime.net  |  Servidor: Mediafire      ║
# ║  Dependencias: curl, pup, sqlite3, fzf, base64   ║
# ╚══════════════════════════════════════════════════╝

# ──────────────────────────────
# CONFIGURACIÓN
# ──────────────────────────────
BASE_URL="https://jkanime.net"
DOWNLOAD_DIR="$HOME/Ahme"
TMP_DIR="/tmp/ahme_$$"
UA="Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"
SQLITE_DB="$HOME/.config/Ahme/anime.db"
CONFIG_FILE="$HOME/.config/Ahme/config.txt"

# ──────────────────────────────
# CONFIGURACIÓN DE USUARIO
# ──────────────────────────────
AUTO_DELETE_AFTER_PLAY=0
RETAIN_DAYS=7

cargar_config() {
  [ -f "$CONFIG_FILE" ] || {
    echo "AUTO_DELETE_AFTER_PLAY=0" > "$CONFIG_FILE"
    echo "RETAIN_DAYS=7" >> "$CONFIG_FILE"
  }
  source "$CONFIG_FILE"
}

guardar_config() {
  cat > "$CONFIG_FILE" << EOF
AUTO_DELETE_AFTER_PLAY=$AUTO_DELETE_AFTER_PLAY
RETAIN_DAYS=$RETAIN_DAYS
EOF
}

# ──────────────────────────────
# UTILIDADES GENERALES
# ──────────────────────────────
limpiar_tmp() {
  rm -rf "$TMP_DIR"
}
trap limpiar_tmp EXIT INT TERM

asegurar_dirs() {
  mkdir -p "$HOME/.config/Ahme" "$DOWNLOAD_DIR" "$TMP_DIR"
  init_db
  cargar_config
}

# ──────────────────────────────
# BASE DE DATOS SQLITE
# ──────────────────────────────
init_db() {
  sqlite3 "$SQLITE_DB" "CREATE TABLE IF NOT EXISTS anime (name TEXT PRIMARY KEY, cap INTEGER);"
}

guardar_en_db() {
  local anime="$1"
  local capitulo="$2"
  sqlite3 "$SQLITE_DB" "INSERT OR REPLACE INTO anime (name, cap) VALUES ('$anime', $capitulo);"
  printf "  ok Guardado: %s en capitulo %s\n" "$anime" "$capitulo"
}

obtener_cap_db() {
  local anime="$1"
  local cap
  cap=$(sqlite3 "$SQLITE_DB" "SELECT cap FROM anime WHERE name='$anime';")
  echo "${cap:-0}"
}

listar_animes_db() {
  sqlite3 "$SQLITE_DB" "SELECT name || ' (capítulo ' || cap || ')' FROM anime ORDER BY name;"
}

# ──────────────────────────────
# VALIDACIONES Y ERRORES
# ──────────────────────────────
validar_slug() {
  local slug="$1"
  if [[ ! "$slug" =~ ^[a-z0-9-]+$ ]]; then
    echo "Slug inválido: $slug. Solo minúsculas, números y guiones." >&2
    return 1
  fi
  return 0
}

retry() {
  local n=0
  local max=3
  local delay=2
  while true; do
    "$@" && break || {
      n=$((n+1))
      if [ $n -ge $max ]; then
        echo "Falló tras $n intentos: $*" >&2
        return 1
      fi
      echo "Reintentando ($n/$max) en ${delay}s..." >&2
      sleep $delay
    }
  done
}

http_get() {
  local url="$1"
  local output="$2"
  local http_code
  http_code=$(curl -s -L -w "%{http_code}" -H "User-Agent: $UA" -o "$output" "$url")
  if [ "$http_code" -ne 200 ]; then
    echo "Error HTTP $http_code al obtener $url" >&2
    return 1
  fi
  return 0
}

# ──────────────────────────────
# EXTRACCIÓN DE URL DE MEDIAFIRE
# ──────────────────────────────
obtener_url_mediafire_de_capitulo() {
  local anime="$1"
  local capitulo="$2"
  local html_file="$TMP_DIR/${anime}_${capitulo}.html"
  local mf_page direct_url

  printf "  -> Obteniendo info del capitulo %s...\n" "$capitulo" >&2
  if ! http_get "$BASE_URL/$anime/$capitulo/" "$html_file"; then
    printf "  x No se pudo descargar la pagina del capitulo %s.\n" "$capitulo" >&2
    return 1
  fi

  mf_page=$(grep -oE '"remote":"[^"]+","slug":"[^"]+","server":"Mediafire"' "$html_file" \
            | grep -oE '"remote":"[^"]+"' \
            | cut -d'"' -f4 \
            | tr -- '-_' '+/' \
            | base64 -d 2>/dev/null)

  if [ -z "$mf_page" ]; then
    printf "  x No se encontro servidor Mediafire para el capitulo %s.\n" "$capitulo" >&2
    return 1
  fi

  printf "  -> Resolviendo enlace de Mediafire...\n" >&2
  # Primero intentamos con grep para encontrar enlace directo .mp4
  direct_url=$(curl -s -L -H "User-Agent: $UA" "$mf_page" | grep -oP 'https://download[^"\'' ]+\.mp4' | head -1)

  if [ -z "$direct_url" ]; then
    # Si no, probamos con pup
    direct_url=$(curl -s -L -H "User-Agent: $UA" "$mf_page" | pup 'a#downloadButton attr{href}' 2>/dev/null | head -1)
  fi

  if [ -z "$direct_url" ]; then
    printf "  x No se pudo extraer el enlace directo de Mediafire.\n"
    printf "    Pagina intentada: %s\n" "$mf_page"
    return 1
  fi

  echo "$direct_url"
}

# ──────────────────────────────
# DESCARGA
# ──────────────────────────────
obtener_total_capitulos() {
  local anime="$1"
  local html_anime="$TMP_DIR/${anime}_info.html"
  local total

  if ! http_get "$BASE_URL/$anime/" "$html_anime"; then
    echo "0"
    return
  fi

  total=$(grep -oE 'Episodios:</span> [0-9]+' "$html_anime" | grep -oE '[0-9]+' | head -1)
  echo "${total:-0}"
}

descargar_capitulo() {
  local anime="$1"
  local capitulo="$2"
  local capitulo_formateado=$(printf "%03d" "$capitulo")
  local filename="${anime}_${capitulo_formateado}.mp4"
  local salida="$DOWNLOAD_DIR/$filename"

  printf "\n[ AHME ] %s - Capitulo %s\n" "$anime" "$capitulo"
  printf "=====================================\n"

  if [ -f "$salida" ]; then
    printf "  -> El archivo %s ya existe. Saltando...\n" "$filename"
    return 0
  fi

  local direct_url
  direct_url=$(obtener_url_mediafire_de_capitulo "$anime" "$capitulo") || return 1

  printf "  -> Descargando: %s\n" "$filename"
  if retry curl -L -H "User-Agent: $UA" -H "Referer: https://www.mediafire.com/" --progress-bar -o "$salida" "$direct_url"; then
    printf "  ok Guardado en: %s\n" "$salida"
    return 0
  else
    printf "  x Error en la descarga del capitulo %s.\n" "$capitulo"
    rm -f "$salida"
    return 1
  fi
}

descargar_rango() {
  local anime="$1"
  local capitulo="$2"
  local respuesta="s"
  local total

  printf "  -> Obteniendo informacion de la serie...\n" >&2
  total=$(obtener_total_capitulos "$anime")
  if [ "$total" -gt 0 ]; then
    printf "  -> Total de capitulos disponibles: %s\n" "$total" >&2
  fi

  while [ "$respuesta" = "s" ]; do
    if [ "$total" -gt 0 ] && [ "$capitulo" -gt "$total" ]; then
      printf "\n  El capitulo %s no existe (maximo: %s).\n" "$capitulo" "$total"
      break
    fi

    descargar_capitulo "$anime" "$capitulo"
    capitulo=$((capitulo + 1))

    if [ "$total" -gt 0 ] && [ "$capitulo" -gt "$total" ]; then
      printf "\n  Se descargaron todos los capitulos disponibles.\n"
      break
    fi

    printf "\n¿Descargar el capitulo %s? [s/N]: " "$capitulo" >&2
    read -r respuesta < /dev/tty
  done

  printf "\n¿Guardar '%s' en la base de datos (ultimo cap: %s)? [g/N]: " "$anime" "$((capitulo - 1))" >&2
  read -r guardar < /dev/tty
  [ "$guardar" = "g" ] && guardar_en_db "$anime" "$((capitulo - 1))"
}

# ──────────────────────────────
# SELECCIÓN INTERACTIVA (fzf)
# ──────────────────────────────
seleccionar_de_db() {
  local opciones seleccion anime_sel cap_sel
  mapfile -t opciones < <(listar_animes_db)
  if [ ${#opciones[@]} -eq 0 ]; then
    echo "Base de datos vacía." >&2
    exit 1
  fi
  seleccion=$(printf '%s\n' "${opciones[@]}" | fzf --prompt="📺 Selecciona anime: " --height=10 --border --cycle)
  if [ -z "$seleccion" ]; then
    echo "Cancelado." >&2
    exit 1
  fi
  anime_sel=$(echo "$seleccion" | awk '{print $1}')
  cap_sel=$(obtener_cap_db "$anime_sel")
  echo "$anime_sel $cap_sel"
}

buscar_anime() {
  local termino="$1"
  local html_busqueda="$TMP_DIR/busqueda.html"
  local urls nombres seleccion anime_seleccionado

  if ! http_get "$BASE_URL/buscar/$termino" "$html_busqueda"; then
    echo "Error en la búsqueda." >&2
    return 1
  fi

  urls=$(grep -oE 'href="'"$BASE_URL"'/[a-z0-9][a-z0-9-]+/"' "$html_busqueda" \
         | grep -oE '/[a-z0-9][a-z0-9-]+/' \
         | sed 's|/||g' \
         | grep -vE '^(buscar|anime|ver|capitulo|tag|genero|categoria)$' \
         | awk '!seen[$0]++')

  if [ -z "$urls" ]; then
    echo "No se encontraron resultados." >&2
    return 1
  fi

  mapfile -t nombres < <(echo "$urls" | sed 's/-/ /g')
  seleccion=$(printf '%s\n' "${nombres[@]}" | fzf --prompt="🔍 Buscar \"$termino\": " --height=15 --border --cycle)
  if [ -z "$seleccion" ]; then
    return 1
  fi
  anime_seleccionado=$(echo "$seleccion" | sed 's/ /-/g')
  echo "$anime_seleccionado"
}

# ──────────────────────────────
# REPRODUCCIÓN Y LIMPIEZA
# ──────────────────────────────
reproducir_anime() {
  local resultado anime_sel ultimo_cap archivos opcion archivo_a_reproducir

  resultado=$(seleccionar_de_db) || exit 1
  anime_sel=$(echo "$resultado" | cut -d' ' -f1)
  ultimo_cap=$(echo "$resultado" | cut -d' ' -f2)

  # Buscar archivos con naming estricto
  mapfile -t archivos < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name "${anime_sel}_[0-9][0-9][0-9].mp4" | sort -V)

  if [ ${#archivos[@]} -eq 0 ]; then
    echo "No se encontraron archivos de $anime_sel en $DOWNLOAD_DIR" >&2
    echo "Formato esperado: ${anime_sel}_XXX.mp4" >&2
    exit 1
  fi

  echo "Episodios disponibles para $anime_sel:"
  for i in "${!archivos[@]}"; do
    nombre=$(basename "${archivos[$i]}")
    echo "  $((i+1)). $nombre"
  done
  echo -n "Selecciona número (o Enter para último capítulo $ultimo_cap): "
  read -r opcion < /dev/tty

  if [ -z "$opcion" ]; then
    # Último capítulo: buscar archivo que contenga el número con 3 dígitos
    local ultimo_cap_fmt=$(printf "%03d" "$ultimo_cap")
    archivo_a_reproducir=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name "${anime_sel}_${ultimo_cap_fmt}.mp4" | head -1)
    if [ -z "$archivo_a_reproducir" ]; then
      echo "No se encontró el capítulo $ultimo_cap. Se usará el primer archivo."
      archivo_a_reproducir="${archivos[0]}"
    fi
  else
    archivo_a_reproducir="${archivos[$((opcion-1))]}"
  fi

  if [ -z "$archivo_a_reproducir" ] || [ ! -f "$archivo_a_reproducir" ]; then
    echo "Archivo no válido." >&2
    exit 1
  fi

  echo "Reproduciendo: $(basename "$archivo_a_reproducir")"
  if command -v mpv >/dev/null; then
    mpv --quiet "$archivo_a_reproducir"
  elif command -v vlc >/dev/null; then
    vlc --play-and-exit "$archivo_a_reproducir"
  else
    echo "No se encontró un reproductor (mpv o vlc). Instala mpv." >&2
    exit 1
  fi

  # Borrado según configuración
  if [ $AUTO_DELETE_AFTER_PLAY -eq 1 ]; then
    echo "Borrando $archivo_a_reproducir (auto-delete activado)..."
    rm -f "$archivo_a_reproducir"
  else
    echo -n "¿Borrar este capítulo? [s/N]: "
    read -r resp < /dev/tty
    [ "$resp" = "s" ] && rm -f "$archivo_a_reproducir"
  fi
}

limpiar_antiguos() {
  if [ $AUTO_DELETE_AFTER_PLAY -eq 0 ] && [ $RETAIN_DAYS -gt 0 ]; then
    echo "Buscando archivos con más de $RETAIN_DAYS días..."
    find "$DOWNLOAD_DIR" -type f -name "*.mp4" -mtime +$RETAIN_DAYS -delete -print
  fi
}

configurar() {
  clear
  echo "===== CONFIGURACIÓN ====="
  echo "1. Borrar capítulo después de reproducirlo: $([ $AUTO_DELETE_AFTER_PLAY -eq 1 ] && echo "SÍ" || echo "NO")"
  echo "2. Días de retención (si no se borra al reproducir): $RETAIN_DAYS días"
  echo "3. Ejecutar limpieza manual ahora"
  echo "0. Volver"
  echo -n "Elige: "
  read -r opt < /dev/tty
  case $opt in
    1)
      AUTO_DELETE_AFTER_PLAY=$((1 - AUTO_DELETE_AFTER_PLAY))
      guardar_config
      echo "Opción actualizada."
      ;;
    2)
      echo -n "Nuevos días de retención: "
      read -r days < /dev/tty
      if [[ "$days" =~ ^[0-9]+$ ]]; then
        RETAIN_DAYS=$days
        guardar_config
      fi
      ;;
    3)
      limpiar_antiguos
      ;;
    0) return ;;
    *) echo "Opción inválida";;
  esac
  sleep 1
  configurar
}

# ──────────────────────────────
# AYUDA
# ──────────────────────────────
mostrar_ayuda() {
  cat << EOF

     _______   ________   _______   _______   _______
    ╱       ╲╲╱       ╱ _╱       ╲╱╱       ╲╱╱       ╲
   ╱        ╱╱        ╲╱         ╱╱        ╱╱        ╱
  ╱         ╱         ╱         ╱        _╱        _╱
  ╲___╱____╱╲________╱╲________╱╲____╱___╱╲____╱___╱

Uso: $(basename "$0") [OPCIONES]

  $(basename "$0") <anime> <capítulo>   Descargar directamente
  $(basename "$0") "término"            Buscar anime
  $(basename "$0") -d                   Seleccionar desde base de datos
  $(basename "$0") -p                   Reproducir anime descargado
  $(basename "$0") -c                   Configuración
  $(basename "$0") -h                   Mostrar esta ayuda

Ejemplos:
  $(basename "$0") one-piece 10
  $(basename "$0") "dragon ball"
EOF
}

# ──────────────────────────────
# MAIN
# ──────────────────────────────
asegurar_dirs

if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
  printf "Error: Este script requiere una terminal interactiva.\n" >&2
  exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  mostrar_ayuda; exit 0
fi

if [ "$1" = "-c" ] || [ "$1" = "--config" ]; then
  configurar; exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  mostrar_ayuda; exit 1
fi

# Caso 1: directo  →  ahme.sh <anime> <cap>
if [ "$#" -eq 2 ]; then
  anime_input="$1"
  capitulo_input="$2"
  validar_slug "$anime_input" || exit 1

  printf "Verificando anime '%s'...\n" "$anime_input"
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: $UA" "$BASE_URL/$anime_input/")
  if [ "$http_code" -eq 200 ]; then
    descargar_rango "$anime_input" "$capitulo_input"
    exit 0
  else
    printf "No se encontró el anime '%s'.\n" "$anime_input"
    printf "Buscando coincidencias...\n"
    if resultado=$(buscar_anime "$anime_input"); then
      printf "\nUsando '%s' en su lugar.\n" "$resultado"
      descargar_rango "$resultado" "$capitulo_input"
      exit 0
    else
      printf "No se encontraron resultados para '%s'.\n" "$anime_input"
      exit 1
    fi
  fi
fi

# Caso 2: base de datos  →  ahme.sh -d
if [ "$1" = "-d" ]; then
  resultado=$(seleccionar_de_db) || exit 1
  anime_sel=$(echo "$resultado" | cut -d' ' -f1)
  cap_sel=$(echo "$resultado" | cut -d' ' -f2)
  siguiente=$((cap_sel + 1))
  descargar_rango "$anime_sel" "$siguiente"
  exit 0
fi

# Caso 3: reproducir → ahme.sh -p
if [ "$1" = "-p" ] || [ "$1" = "--play" ]; then
  reproducir_anime
  exit 0
fi

# Caso 4: búsqueda  →  ahme.sh "término"
resultado=$(buscar_anime "$1") || { printf "\n  Busqueda cancelada.\n"; exit 0; }
if [ -z "$resultado" ]; then
  printf "  No se selecciono ningun anime.\n"; exit 1
fi

printf "\n¿Desde que capitulo? [1]: "
read -r capitulo < /dev/tty
capitulo="${capitulo:-1}"
descargar_rango "$resultado" "$capitulo"
