# Guía del desarrollador: pedir y usar infraestructura

**Para quién:** quien necesita VMs o clusters k3s en el Proxmox de su empresa: miembros de un
proyecto, colaboradores y freelancers. No necesitas saber Terraform ni Ansible, ni tener ninguna
credencial de infraestructura: pides por PR y el pipeline lo crea cuando un admin lo aprueba.

**Cómo sabrás que ha salido bien:** `make ssh NAME=<tu-vm>` te deja dentro de la VM con tu usuario
(o `make kubeconfig NAME=<tu-cluster>` te deja un `kubectl` funcionando).

## 1. Antes de empezar

- **Una cuenta de GitHub** que el admin haya añadido a `members` de tu proyecto en `projects.yaml`
  ([operador.md](operador.md#alta-y-baja-de-una-persona)). Si la instalación vive en una
  organización, además te añade a ella; si es un repo público, basta con un fork.
- **Una clave SSH en tu perfil de GitHub** (Settings → SSH and GPG keys). Con ella entrarás en tus
  VMs. Si no tienes: `ssh-keygen -t ed25519` y pega el contenido de `~/.ssh/id_ed25519.pub`.
- **Herramientas:** `git`, `make`, `python3` con PyYAML, `ssh` y, muy recomendable, la CLI de GitHub
  [`gh`](https://cli.github.com) autenticada (`gh auth login`).

  ```sh
  sudo apt install git make python3 python3-yaml openssh-client   # Ubuntu / Debian
  ```
- **Acceso a la red de las VMs** para entrar en ellas (para pedirlas no hace falta). Si tu
  instalación usa Cloudflare WARP, instálalo desde <https://one.one.one.one> y:

  ```sh
  warp-cli registration new <TEAM>   # abre el navegador: entra con tu cuenta de GitHub
  warp-cli connect
  ```
  El admin te dice el `<TEAM>` y te da de alta. Con WARP llegas al SSH de tus VMs y a nada más.

## 2. Fork, clon y comprobación

Los cambios se proponen siempre desde tu fork: nadie (tampoco los admins) empuja a `main`.

```sh
gh repo fork <OWNER>/pve-platform-iac --clone --remote   # origin = tu fork, upstream = el repo central
cd pve-platform-iac
make setup && make doctor
```

`make doctor` dice quién eres en GitHub, en qué proyectos estás y cuántas claves SSH tiene tu
perfil. Si dice «proyectos: ninguno», pide al admin que te dé de alta.

## 3. Pide lo que necesitas

```sh
git switch main && git pull upstream main   # parte siempre de lo último
make flavors                                # tamaños y perfiles disponibles
make new-vm                                 # asistente: una VM
make new-cluster                            # asistente: un cluster k3s
```

El asistente pregunta el proyecto (si estás en varios), el perfil, el tamaño y el nombre. Busca un
VMID y una IP libres **en el rango de tu proyecto** y escribe el fichero en `requests/`. También se
puede usar sin preguntas: `make new-vm NAME=equipo-a-db PROFILE=vm FLAVOR=vm-medium`.

Un cluster k3s son un master y N workers, repartidos por turnos entre los nodos físicos de Proxmox:
si cae un nodo, cae una parte del cluster, no el cluster entero.

## 4. Abre el PR y revisa el plan

```sh
git switch -c pide-<nombre>
git add requests/ && git commit -m "Pide <nombre>"
git push -u origin pide-<nombre>
gh pr create --repo <OWNER>/pve-platform-iac --fill
```

En el PR verás:

1. **pr-validate**: comprobaciones sin credenciales. La primera vez, un admin tiene que pulsar
   «Approve and run» (es un PR desde un fork).
2. **pr-plan**: un comentario con el plan de Terraform resumido por petición. Solo sale si tu PR
   toca **únicamente** `requests/`. En un repo público, si no eres colaborador, aparece cuando un
   admin revisa el YAML y le pone la etiqueta `plan`.

Qué esperar en el plan:

- **Normal:** solo `+ crear` de lo que has pedido (o `~ modificar`, si has cambiado el tamaño).
- **Para y avisa al admin** si ves `destruir` o `recrear` de algo que no has borrado o renombrado
  a propósito, o cambios en VMs de otro proyecto.

Si algo falla, el mensaje dice qué fichero y qué regla. Arréglalo, haz commit y push: el PR se
actualiza solo. Cuando el admin mergea, el pipeline crea y configura la VM (2-5 minutos). Lo puedes
seguir en Actions → deploy.

## 5. Usa lo que has creado

```sh
git switch main && git pull upstream main
make ssh NAME=<vm>              # entra con tu usuario de GitHub (en minúsculas) y tienes sudo
make ssh NAME=<cluster>         # en un cluster, entra en el master
make kubeconfig NAME=<cluster>  # deja el kubeconfig en ansible/kubeconfigs/<cluster>.yaml
make list                       # lo pedido en requests/
```

`make ssh` baja las claves de host que publica el pipeline y las usa en modo estricto. Si alguna vez
ves «REMOTE HOST IDENTIFICATION HAS CHANGED» con `make ssh`, **no entres** y avisa al admin.

En tus VMs tienes `sudo` (son tus máquinas de desarrollo), pero no cambies su red ni su
configuración de SSH: lo gestiona Ansible y se revertiría en el siguiente deploy.

## 6. Cambiar o borrar

Todo cambio es un PR que edita tu fichero de `requests/`:

- **Más o menos recursos:** cambia `flavor` (VM) o `workers` (cluster) por un valor admitido. CPU y
  RAM se ajustan sin recrear la VM; el disco solo puede crecer.
- **Borrar** cuando termines (la capacidad es compartida):

  ```sh
  git switch main && git pull upstream main
  make remove NAME=<nombre>
  git switch -c quita-<nombre> && git commit -am "Quita <nombre>" && git push -u origin quita-<nombre>
  gh pr create --repo <OWNER>/pve-platform-iac --fill
  ```
  En el plan del PR tienen que salir **solo** tus VMs como destruidas.

## Reglas comunes

- **Un fichero = una VM o un cluster.** El nombre del fichero (sin `.yaml`) es el nombre de la VM
  (el hostname) o el prefijo del cluster: minúsculas, números y `-`, sin empezar ni terminar en `-`.
  Por convención, empieza por el proyecto (`equipo-a-db`).
- **Extensión `.yaml`**, no `.yml`: Terraform no lee los `.yml` (`make check` avisa).
- **Renombrar el fichero destruye y recrea** sus VMs; **borrarlo las destruye**. Discos incluidos.
- **No cambies `vmid` ni `ip` a mano:** tienen que estar en los rangos de tu proyecto
  (`projects.yaml`), no repetirse y no caer en `network.reserved_ips` de `platform.yaml`. Fuera de tu
  rango pueden ser los de otro proyecto, y `make check` lo rechaza.
- `project` decide el pool de Proxmox, los rangos válidos y quién entra. El pool **nunca** se escribe
  en la petición.
- **Nunca subas secretos** (tokens, claves privadas, kubeconfigs) al repo: lo leen todos los
  colaboradores y, si el repo es público, cualquiera.

`make check` aplica las mismas reglas que el CI y el plan. Los esquemas de `schema/` dan
autocompletado en editores con YAML Language Server: la primera línea de cada fichero generado los
enlaza.

## Referencia: VM suelta (`requests/vms/<nombre>.yaml`)

```yaml
# yaml-language-server: $schema=../../schema/vm.schema.json
project: equipo-a         # obligatorio: proyecto de projects.yaml
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
| `profile` | no (`vm`) | `vm`, `monitoring` |
| `vmid` | sí | Entero en el rango de VMIDs del proyecto |
| `ip` | sí | IPv4 de la red de `platform.yaml`, con el último octeto en el rango del proyecto |
| `description` | no | Texto de hasta 200 caracteres |

## Referencia: cluster k3s (`requests/clusters/<nombre>.yaml`)

```yaml
# yaml-language-server: $schema=../../schema/cluster.schema.json
project: equipo-a
flavor_size: k3s-mini     # familia de cluster_sizes
workers: 2                # por defecto, el de la familia; mínimo min_workers
vmid_base: 1110           # VMID del master; los workers usan los siguientes (1111, 1112)
ip_base: 110              # último octeto del master; los workers, los siguientes
k3s_version: v1.33.5+k3s1 # opcional; por defecto, la de la familia
```

Crea `<nombre>-master` y `<nombre>-worker-01..NN`, repartidos por turnos entre los nodos de
`platform.yaml`. Todo el bloque de VMIDs e IPs (`base` … `base + workers`) tiene que estar libre y
en el rango del proyecto: el asistente lo busca.

## Catálogo

Tabla generada desde `catalog/` (`make docs`; el CI comprueba que está al día):

<!-- catalogo:inicio (generado con `make docs`, no editar a mano) -->
| Flavor | vCPU | RAM | Disco | Para qué |
|---|:---:|:---:|:---:|---|
| `vm-small` | 2 | 4 GB | 40 GB | VM independiente por defecto |
| `vm-medium` | 4 | 8 GB | 80 GB | VM para servicios medianos (p. ej. monitorizacion) |
| `vm-large` | 8 | 16 GB | 160 GB | VM para servicios pesados |
| `k3s-mini-master` | 2 | 4 GB | 40 GB | Master de cluster k3s pequeño |
| `k3s-mini-worker` | 4 | 8 GB | 80 GB | Worker de cluster k3s pequeño |

| Familia de cluster k3s | Master | Worker | Workers (mín / por defecto) | k3s | Para qué |
|---|---|---|:---:|---|---|
| `k3s-mini` | `k3s-mini-master` | `k3s-mini-worker` | 1 / 2 | v1.33.5+k3s1 | Cluster k3s pequeño de pruebas |

| Perfil de VM | Flavors admitidos | Qué instala |
|---|---|---|
| `vm` | `vm-small`, `vm-medium`, `vm-large` | VM Ubuntu con la configuracion base (cuentas del proyecto, chrony, node-exporter) |
| `monitoring` | `vm-medium`, `vm-large` | Prometheus + Grafana que monitorizan todas las VMs del repo |
<!-- catalogo:fin -->

El catálogo es **cerrado**: si ningún tamaño te sirve, pídeselo al admin (un flavor nuevo es un PR,
[operador.md](operador.md#ampliar-el-catálogo)). Cambiar los números de un flavor afecta a **todas**
las VMs que lo usan en el siguiente deploy.

## Problemas habituales

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `make doctor`: «no sé quién eres» | Sin `gh` autenticado | `gh auth login`, o `export GITHUB_USER=<tu-usuario>` |
| `make doctor`: «proyectos: ninguno» | No estás en `members` de ningún proyecto | Pídeselo al admin |
| `iac check`: «fuera de los rangos de …» | `vmid`/`ip` cambiados a mano, o de otro proyecto | Vuelve a generar la petición con `make new-vm` |
| `iac check`: «campos desconocidos ['flavr']» | Errata en el YAML | El mensaje lista los campos válidos |
| `.yml IGNORADA por Terraform` | Extensión `.yml` | Renómbralo a `.yaml` antes del merge |
| El PR no tiene comentario de plan | Tu PR toca algo más que `requests/`, o falta la etiqueta `plan` | Un PR solo con la petición; en un repo público, espera a que un admin lo revise |
| `Permission denied (publickey)` al entrar | Tu clave no está en tu perfil de GitHub, o el deploy aún no ha terminado | Añádela en GitHub; se aplica en el siguiente deploy |
| `No route to host` / timeout con `make ssh` | Sin acceso a la red de las VMs, o el deploy no ha terminado | Comprueba WARP (`warp-cli status`) y Actions → deploy |
| `make ssh` pregunta por la huella | La VM aún no tiene clave publicada | Espera a que termine el deploy, o compárala con `make known-hosts` |
| «HOST IDENTIFICATION HAS CHANGED» con `make ssh` | La VM se ha recreado, o algo la suplanta | **No entres** y avisa al admin |
| El mismo aviso con `ssh` a secas | Tu `~/.ssh/known_hosts` tiene la clave de una VM anterior con esa IP | Usa siempre `make ssh` |
| La consola web de Proxmox pide contraseña | Las cuentas de las VMs no tienen contraseña, por diseño | Entra por SSH (`make ssh`) |

Si algo no se arregla así, abre un issue (o comenta en tu PR) con el enlace al run que falla.
