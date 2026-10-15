# Seguridad

**Para quién:** admins, y cualquiera que audite la plataforma. Explica de qué se protege, con qué
control, dónde está ese control en el código y cómo comprobar que funciona.

## Modelo de amenazas

**Activos:** la API de Proxmox (crear o borrar cualquier VM), el estado de Terraform, las VMs de cada
proyecto y sus datos, y las credenciales (tokens de Proxmox y de HCP, la clave de Ansible, el token
de ghcr y la deploy key de dataspace-mvp).

**Quién hay:**

| Actor | Confianza | Puede |
|---|---|---|
| Admin (`infra-admins`) | Total | Mergear, gestionar secretos, aplicar en local (break-glass) |
| Colaborador de la empresa / freelancer | Limitada a su proyecto | Leer el repo, abrir PR desde su fork, entrar por SSH en las VMs de su proyecto |
| Ex-colaborador | Ninguna | Nada desde el `configure` siguiente a su baja ([operador.md](operador.md#alta-y-baja-de-una-persona)) |
| Atacante en la red del homelab | Ninguna | Intentar suplantar una VM o un nodo (MITM) |
| Dependencia comprometida | Ninguna | Una action, un provider o una imagen que cambia de contenido |

**Qué se quiere evitar, por orden:** 1) que código sin revisar se ejecute con credenciales de
infraestructura; 2) que alguien cambie la infraestructura sin pasar por un PR revisado; 3) que un
colaborador acceda a las VMs de otro proyecto; 4) que una suplantación (de Proxmox, de una VM o de la
imagen base) pase inadvertida; 5) que una credencial filtrada dé más poder del necesario.

## Controles

Cada requisito, el control que lo cumple, dónde está y cómo verificarlo.

| # | Requisito | Control | Dónde | Cómo verificarlo |
|---|---|---|---|---|
| R-01 | Código no revisado nunca con secretos | Las validaciones de PR corren en runners de GitHub, sin secretos ni red al homelab | `.github/workflows/pr-validate.yml` | Un PR que imprime `env` no ve ningún secreto |
| R-02 | Plan de PR sin ejecutar código del PR | `pull_request_target` + checkout de main + solo `requests/` del PR | `.github/workflows/pr-plan.yml` | Un PR que toca `terraform/` no recibe plan; ver abajo |
| R-03 | TLS verificado con Proxmox | `insecure = false` + CA del cluster en el bundle | `terraform/versions.tf`, `scripts/ca-bundle.sh` | Sin la CA en el bundle, el plan falla con `x509` |
| R-04 | Ansible verifica las claves de host | `host_key_checking = True`, `StrictHostKeyChecking=yes` y claves publicadas | `ansible/ansible.cfg`, `scripts/iac` (`configure`, `known-hosts`) | Una clave alterada en `known_hosts` hace fallar Ansible |
| R-05 | Imagen base inmutable | Release fechada + sha256 + firma GPG verificada | `homelab.yaml` (`image:`), `terraform/main.tf`, `scripts/image-pin.sh` | Un sha256 cambiado hace fallar la descarga en Proxmox |
| R-06 | Sin credenciales root de los nodos | `import_from` por API, sin `ssh {}` ni replicación por SSH | `terraform/modules/vm/main.tf`, `terraform/versions.tf` | `grep -rn "ssh {" terraform/` no encuentra nada |
| R-07 | Tokens con privilegios mínimos | ACL solo en pools, storages, zona SDN y nodos; nada en `/` | `scripts/iac` (`proxmox-acl`, `preflight`) | `make preflight` con el token exportado |
| R-08 | Runners separados y efímeros | Dos grupos (plan/apply) restringidos a workflows de main; un contenedor por job | `runner/`, [bootstrap.md §6](bootstrap.md#6-runners-del-homelab) | Un workflow en otra rama no consigue runner |
| R-09 | Se aplica exactamente lo planificado | Plan guardado, cifrado entre jobs, sha256 comprobado | `.github/workflows/deploy.yml`, `scripts/encrypt-plan.sh` | Alterar el artefacto hace fallar `apply` |
| R-10 | Secretos de escritura solo en main | Secretos en el environment `production`, que solo despliega desde `main` | [bootstrap.md §5](bootstrap.md#5-environments-y-secretos) | `make preflight` (sin secretos a nivel de repo) |
| R-11 | Cadena de suministro del pipeline | Actions fijadas por SHA, `permissions` mínimos, Dependabot con 14 días de espera | `.github/workflows/*`, `.github/dependabot.yml` | Job `workflows` de pr-validate |
| R-12 | Deriva detectada | Plan diario con `-detailed-exitcode`; falla y abre un issue, sin corregir | `.github/workflows/drift.yml` | Cambiar una VM en la UI + lanzar drift a mano |
| R-13 | Credenciales del MVP temporales | Deploy key y token de ghcr borrados al terminar (bloque `always`) | `ansible/roles/dataspace_mvp/tasks/main.yml` | Tras el deploy: ni `~/.ssh/deploy_key` ni `~/.docker-mvp-deploy` en la VM |
| R-14 | Acceso a VMs por proyecto | Cuenta Linux solo para miembros del proyecto de la VM; las demás se borran | `terraform/outputs.tf` (`vm_access`), `ansible/roles/base/tasks/access.yml` | Un miembro de otro proyecto no tiene cuenta en la VM |
| R-15 | Nadie cambia main sin revisión | Ruleset: PR obligatorio, aprobación de CODEOWNERS, checks verdes, sin force-push ni bypass | [bootstrap.md §4](bootstrap.md#4-ruleset-de-main) | `make preflight` |

### R-02 Plan de PR sin ejecutar código del PR

El plan de un PR necesita credenciales (estado y API de Proxmox), y por eso es el punto más
delicado. Qué hace `pr-plan.yml`, en orden:

1. Se dispara con `pull_request_target`: el **workflow** que corre es el de `main`. Un PR que cambie
   `pr-plan.yml` no cambia lo que se ejecuta.
2. El job `gate` (runner de GitHub, sin secretos) lista los ficheros del PR por la API. Si alguno
   (o su nombre anterior, en un renombrado) no es `requests/{vms,clusters}/<nombre>.yaml`, no hay
   plan. Tampoco lo hay si el autor no es de la organización ni colaborador.
3. El job `plan` hace checkout de `main` (el código revisado) y, aparte, del PR **solo
   `requests/`**. Comprueba que el commit es el del evento.
4. Aplica sobre `main` solo los ficheros que el PR añade, cambia o borra. Rechaza los enlaces
   simbólicos (un enlace a `/etc/...` lo leería `yamldecode` y saldría en el plan) y todo lo que no
   sea un fichero regular.
5. Valida con el esquema (`schema/`) y con `iac check` de `main`: estructura, rangos del proyecto,
   duplicados, perfiles y el `ref` del MVP.
6. `terraform plan -lock=false -refresh=false` con el token `iac@pve!plan` (PVEAuditor). No escribe
   nada en ningún sitio.

Lo que queda: los YAML del PR se interpretan con el código de `main`. Un YAML no puede ejecutar nada
en Terraform (`yamldecode` solo produce datos) ni en `iac check` (`yaml.safe_load`).

### R-04 Claves de host: cómo funciona

- El job `known-hosts` de `deploy.yml` lee las claves de todas las VMs **desde el runner, dentro de
  la red**, y las compara con las del deploy anterior (último artefacto `known_hosts` de main).
- Si una IP ya conocida presenta otra clave y su VM no se ha creado o reemplazado en este deploy, el
  deploy **se para** ([runbook](runbooks/clave-de-host-cambiada.md)).
- `configure` usa ese fichero, y solo ese, en modo estricto. `make ssh`, `make tunnel` y
  `make kubeconfig` bajan el mismo artefacto.
- El primer contacto con una VM nueva es TOFU ([A-2](#riesgos-aceptados)).

Los nodos de Proxmox no están en ningún `known_hosts` del pipeline, porque nadie entra en ellos por
SSH ([R-06](#controles)). Su identidad la garantiza TLS ([R-03](#controles)).

### R-07 Tokens de Proxmox con privilegios mínimos

`make proxmox-acl` genera los comandos `pveum` desde `homelab.yaml` y `projects.yaml`:

| Token | Rol | Rutas |
|---|---|---|
| `iac@pve!apply` (privsep) | `IaCApply` (ver [credenciales.md](credenciales.md#token-de-escritura-iacpveapply)) | `/pool/<pool de cada proyecto>`, `/storage/<datastore>`, `/storage/<image_datastore>`, `/sdn/zones/<zona>`, `/nodes/<cada nodo>` |
| `iac@pve!plan` (privsep) | `PVEAuditor` | las mismas |

Ninguno tiene ACL en `/`. Como las VMs se crean con `pool_id`, el permiso `VM.Allocate` sobre el pool
basta para crearlas, y una VM que no está en un pool del repo queda fuera del alcance del token. La
imagen se descarga con `Sys.AccessNetwork` en el nodo, en vez de `Sys.Modify` en `/` (Proxmox admite
los dos).

## Riesgos aceptados

| # | Riesgo | Por qué se acepta | Mitigación | Cómo quitarlo |
|---|---|---|---|---|
| A-1 | El token de HCP del plan de PR puede **escribir** el estado | HCP Free no tiene tokens de equipo de solo lectura | Ese job solo ejecuta código de main (R-02) y usa `-lock=false`; HCP guarda versiones del estado | Plan Standard de HCP con un token de equipo de solo lectura |
| A-2 | TOFU en la primera conexión a una VM nueva | Fijar la clave por cloud-init deja privadas en el estado | Se lee desde dentro de la red, minutos después de crearla; después es estricta (D-09) | Generar las claves de host en Terraform e inyectarlas por cloud-init |
| A-3 | Los miembros de un proyecto son root en sus VMs (sudo, `docker`), y durante un despliegue de MVP podrían leer el token de ghcr | Son sus máquinas de desarrollo; kind necesita Docker (D-12) | El token es de solo `read:packages` y existe en la VM solo durante el despliegue (R-13) | Una cuenta máquina de GitHub con acceso solo a los paquetes del dataspace, y su token |
| A-4 | Todos los colaboradores ven las peticiones de todos (nombres, IPs internas, tamaños) | Simplicidad (D-10) | No da acceso: las cuentas SSH son por proyecto | Un repo de peticiones por proyecto |
| A-5 | El PAT que crea los runners vive en el host de runners | Lo exige la API de runners JIT | Fine-grained, solo «Self-hosted runners», fichero `0600` de root, host sin acceso para nadie salvo admins | Una GitHub App con ese único permiso |
| A-6 | La restricción de grupos de runners a workflows concretos puede no estar en el plan Team | Depende del plan de GitHub | Aunque falte, los devs no pueden crear ramas (D-04) y los runners son efímeros | Verificarlo al crear los grupos ([bootstrap.md §6](bootstrap.md#6-runners-del-homelab)) |
| A-7 | El plan de PR no ve la deriva (`-refresh=false`) | Refrescar exige `VM.Config.Disk` (un permiso de modificación) | El plan de main sí refresca, y drift.yml lo hace a diario | — |
| A-8 | Lo que no gestiona el repo (otras VMs del homelab) queda fuera de la deriva | Terraform solo conoce su estado | Las ACL impiden que el token toque VMs fuera de los pools del repo | — |

## Qué hacer si…

- **Se filtra un secreto:** [runbooks/token-comprometido.md](runbooks/token-comprometido.md).
- **Cambia la clave de host de una VM:** [runbooks/clave-de-host-cambiada.md](runbooks/clave-de-host-cambiada.md).
- **drift abre un issue:** [runbooks/deriva-detectada.md](runbooks/deriva-detectada.md).
- **Un colaborador deja el proyecto:** [operador.md](operador.md#alta-y-baja-de-una-persona).
