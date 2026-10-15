# Referencia de peticiones

**Para quién:** quien escribe o revisa un fichero de `requests/`. Lo normal es generarlo con
`make new-vm` o `make new-cluster`; aquí está cada campo por si hay que entenderlo o retocarlo.

**Cómo comprobar una petición:** `make check` (las mismas reglas que el CI y el plan). Los
esquemas de `schema/` dan autocompletado en editores con soporte de YAML Language Server: la primera
línea de cada fichero generado los enlaza.

## Reglas comunes

- **Un fichero = una VM o un cluster.** El nombre del fichero (sin `.yaml`) es el nombre de la VM
  (el hostname) o el prefijo del cluster: minúsculas, números y `-`, sin empezar ni terminar en `-`.
  Por convención, empieza por el proyecto (`dataspace-demo`).
- **Extensión `.yaml`**, no `.yml`: Terraform no lee los `.yml` (`make check` avisa).
- **Renombrar el fichero destruye y recrea** sus VMs; **borrarlo las destruye**. Discos incluidos.
- `project` decide el pool de Proxmox, los rangos válidos y quién entra. El pool **nunca** se
  escribe en la petición.
- VMID e IP tienen que estar en los rangos del proyecto (`projects.yaml`), no repetirse y no caer en
  `network.reserved_ips` de `homelab.yaml`.

## VM suelta: `requests/vms/<nombre>.yaml`

```yaml
# yaml-language-server: $schema=../../schema/vm.schema.json
project: dataspace        # obligatorio: proyecto de projects.yaml
flavor: vm-small          # tamaño (por defecto vm-small); tiene que admitirlo el perfil
profile: vm               # qué se instala (por defecto vm)
vmid: 1101                # obligatorio, en el rango del proyecto
ip: 192.168.50.101        # obligatorio, en el rango del proyecto
description: Base de datos de pruebas   # opcional, solo informativo
```

| Campo | Obligatorio | Valores |
|---|---|---|
| `project` | sí | Un proyecto de `projects.yaml` |
| `flavor` | no (`vm-small`) | Uno de los que admite el perfil (tabla de abajo) |
| `profile` | no (`vm`) | `vm`, `monitoring`, `dataspace-kind` |
| `vmid` | sí | Entero en el rango de VMIDs del proyecto |
| `ip` | sí | IPv4 de la red de `homelab.yaml`, con el último octeto en el rango del proyecto |
| `mvp` | solo con `dataspace-kind` | Ver abajo |
| `description` | no | Texto de hasta 200 caracteres |

### Bloque `mvp:` (perfil `dataspace-kind`)

```yaml
mvp:
  repo: teo-devops/dataspace-mvp                 # owner/repo de GitHub
  ref: c5e82fc...(40 caracteres)                 # SHA completo o tag (v0.2.0). NUNCA una rama
  path: demo                                     # carpeta del MVP dentro del repo
```

`ref` no puede ser una rama: una rama cambia sin pasar por un PR, y lo desplegado dejaría de ser lo
revisado ([D-11](diseno.md#decisiones)). `make new-vm` convierte una rama en su SHA actual. Detalle
en [dataspace.md](dataspace.md).

## Cluster k3s: `requests/clusters/<nombre>.yaml`

```yaml
# yaml-language-server: $schema=../../schema/cluster.schema.json
project: dataspace
flavor_size: k3s-mini     # familia de cluster_sizes
workers: 2                # por defecto, el de la familia; minimo min_workers
vmid_base: 1110           # VMID del master; los workers usan los siguientes (1111, 1112)
ip_base: 110              # ultimo octeto del master; los workers, los siguientes
k3s_version: v1.33.5+k3s1 # opcional; por defecto, la de la familia
```

Crea `<nombre>-master` y `<nombre>-worker-01..NN`, repartidos por turnos entre los nodos de
`homelab.yaml`. Todo el bloque de VMIDs e IPs (`base` … `base + workers`) tiene que estar libre y
en el rango del proyecto: el asistente lo busca.

## Catálogo

Tabla generada desde `catalog/` (`make docs`; el CI comprueba que está al día):

<!-- catalogo:inicio (generado con `make docs`, no editar a mano) -->
| Flavor | vCPU | RAM | Disco | Para qué |
|---|:---:|:---:|:---:|---|
| `vm-small` | 2 | 4 GB | 40 GB | VM independiente por defecto |
| `vm-medium` | 4 | 8 GB | 80 GB | VM para servicios medianos (p. ej. monitorizacion) |
| `vm-large` | 8 | 16 GB | 160 GB | VM para servicios pesados |
| `ds-mvp-kind` | 8 | 16 GB | 120 GB | Dataspace: MVP completo en kind, con observabilidad |
| `ds-mvp-kind-lite` | 4 | 12 GB | 80 GB | Dataspace: MVP en kind sin observabilidad (observability.components vacio en mvp.yaml) |
| `k3s-mini-master` | 2 | 4 GB | 40 GB | Master de cluster k3s pequeño |
| `k3s-mini-worker` | 4 | 8 GB | 80 GB | Worker de cluster k3s pequeño |

| Familia de cluster k3s | Master | Worker | Workers (mín / por defecto) | k3s | Para qué |
|---|---|---|:---:|---|---|
| `k3s-mini` | `k3s-mini-master` | `k3s-mini-worker` | 1 / 2 | v1.33.5+k3s1 | Cluster k3s pequeño de pruebas |

| Perfil de VM | Flavors admitidos | Bloques obligatorios | Qué instala |
|---|---|---|---|
| `vm` | `vm-small`, `vm-medium`, `vm-large` | — | VM Ubuntu con la configuracion base (cuentas del proyecto, chrony, node-exporter) |
| `monitoring` | `vm-medium`, `vm-large` | — | Prometheus + Grafana que monitorizan todas las VMs del repo |
| `dataspace-kind` | `ds-mvp-kind`, `ds-mvp-kind-lite` | `mvp:` | Docker + kind con un MVP de dataspace (teo-devops/dataspace-mvp) desplegado |
<!-- catalogo:fin -->

Cambiar el catálogo lo hace el admin, por PR. Cambiar los números de un flavor afecta a **todas** las
VMs que lo usan en el siguiente deploy: Terraform cambia CPU y RAM en caliente, y el disco solo
crece.
