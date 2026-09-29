# routing-osrm-updater

Servicio de actualización de datos de enrutamiento. Descarga extracts de
OpenStreetMap, los valida/fusiona, construye datasets OSRM con MLD o CH,
y publica versiones inmutables. Puede integrase opcionalmente con un
runtime externo para validar cambios.

## Requisitos

- Docker
- Docker Compose (v2)
- GNU Make
- Bash
- Python 3
- curl

## Estructura

```
compose.yaml              # servicios data-tools y osrm-builder
Makefile                  # targets de build, publish y update
update-dataset.sh         # orquestación de update + rollback
scripts/
  lib/common.sh           # utilidades compartidas
  download.sh             # descarga PBF desde regiones
  merge.sh                # fusiona múltiples PBF
  build-graph.sh          # ejecuta osrm-extract y contract/partition según algoritmo
  publish-dataset.sh      # publica versión bajo data/releases
  activate-dataset.sh     # actualiza OSRM_DATASET_VERSION en .env externo
  smoke-test.sh           # valida /route y /table contra runtime
docker/
  data-tools/Dockerfile   # imagen con osmium, curl, etc.
config/
  regions/local.txt       # lista de regiones a descargar (local)
  regions/production.txt  # lista de regiones a descargar (prod)
data/
  work/raw/               # PBF descargados
  work/merged/            # PBF fusionados y datasets OSRM generados
  releases/               # versiones publicadas (inmutables)
.env.example              # plantilla de configuración
```

## Setup inicial

```bash
cp .env.example .env
```

Define las variables según tu entorno (mira sección de variables más abajo).

## Variables de entorno

| Variable | Descripción | Defecto |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | Nombre proyecto Docker Compose | `routing-osrm-updater` |
| `OSRM_IMAGE` | Imagen Docker de OSRM | `ghcr.io/project-osrm/osrm-backend:v26.6.5-debian` |
| `OSRM_ALGORITHM` | Algoritmo de enrutamiento (mld o ch) | `mld` |
| `RUNTIME_COMPOSE_FILE` | Ruta a compose.yaml del runtime externo (opcional) | `` |
| `RELEASES_DIRECTORY` | Ruta local a data/releases del runtime | `./data/releases` |
| `ENV_FILE` | Ruta a .env del runtime externo (opcional) | `` |

### Integración con runtime externo

Si tienes el runtime en otro repositorio/máquina, configura:

```bash
# .env del updater
RUNTIME_COMPOSE_FILE=/path/to/runtime/compose.yaml
ENV_FILE=/path/to/runtime/.env
RELEASES_DIRECTORY=/path/to/runtime/data/releases
```

Con esto, `make update-dataset` automáticamente:
1. Genera el nuevo dataset
2. Lo publica en `RELEASES_DIRECTORY`
3. Lo activa en el runtime externo
4. Corre smoke tests contra él
5. Revierte si los tests fallan

## Configuración de regiones

Edita según necesites:

- `config/regions/local.txt` — regiones para desarrollo local
- `config/regions/production.txt` — regiones para producción

Formato (una por línea):

```text
name|https://example.com/extract.osm.pbf
```

Nombres válidos: `^[A-Za-z0-9][A-Za-z0-9._-]*$`

## Comandos

### Build y validación

```bash
make config                     # valida configuración Docker Compose
make build-tools                # construye imagen data-tools
make osrm-check                 # verifica versión de osrm-extract
```

### Descarga de datos

```bash
make download-strict            # descarga de regiones (no stale)
make download-local             # descarga de config/regions/local.txt
make raw-files                  # lista ficheros descargados
```

### Merge y build

```bash
make merge-local                # fusiona PBF en data/work/merged/
make merged-file                # muestra tamaño del PBF fusionado
make build-graph-local          # ejecuta osrm-extract y contract/partition según OSRM_ALGORITHM
make graph-files                # lista ficheros OSRM generados
```

### Publicación y versiones

```bash
make publish-local              # publica como 'local' (reemplazable)
make publish-version DATASET_VERSION=<v>    # publica versión inmutable
make list-versions              # lista versiones publicadas
make release-files              # lista ficheros de versión actual
```

### Update completo

```bash
make prepare-local              # descarga → merge → build → publish → osrm-up → smoke-test
make update-dataset DATASET_VERSION=<v>    # update con validación y rollback
```

## Flujo de work local completo

```bash
make prepare-local
# → genera 'local' y arranca runtime para fumar validar
make publish-version DATASET_VERSION=2025-01-15T10:00:00Z
# → publica versión inmutable
make list-versions
# → lista versiones disponibles
```

## Flujo de update con runtime externo

```bash
# Configura variables en .env
RUNTIME_COMPOSE_FILE=/path/to/runtime/compose.yaml
ENV_FILE=/path/to/runtime/.env
RELEASES_DIRECTORY=/path/to/runtime/data/releases

# Ejecuta update
make update-dataset DATASET_VERSION=2025-01-15T10:00:00Z
# → descarga → merge → build → publica → activa en runtime → smoke test → rollback si falla
```

## Notas

- Los ficheros en `data/work/` son temporales y se regeneran.
- Las versiones en `data/releases/<version>` son inmutables (previene reescritura accidental).
- `update-dataset.sh` implementa rollback: si los smoke tests fallan post-activación,
  revierte a la versión anterior automáticamente.
- Para desarrollo rápido usa `make prepare-local` (genera 'local', reemplazable).
- Para producción usa `make publish-version` + versionado temporal.
