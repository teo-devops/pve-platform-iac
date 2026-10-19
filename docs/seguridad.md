# Seguridad

**Para quién:** admins, y cualquiera que audite la plataforma. Explica de qué se protege, con qué
control, dónde está ese control en el código y cómo comprobar que funciona, y el
[inventario de secretos](#inventario-de-secretos) con su alcance y su rotación.

**Regla general:** los devs y los freelancers **no tienen ninguna credencial de infraestructura**.
Piden por PR, y el pipeline aplica con secretos que solo ven los jobs de `main`.

## Modelo de amenazas

**Activos:** la API de Proxmox (crear o borrar cualquier VM), el estado de Terraform, las VMs de cada
proyecto y sus datos, y las credenciales (tokens de Proxmox y de HCP, la clave de Ansible y la clave
que cifra el plan).

**Quién hay:**

| Actor | Confianza | Puede |
|---|---|---|
| Admin (`admins` de `projects.yaml`) | Total | Mergear, gestionar secretos, aplicar en local (break-glass) |
| Colaborador de la empresa / freelancer | Limitada a su proyecto | Leer el repo, abrir PR desde su fork, entrar por SSH en las VMs de su proyecto |
| Ex-colaborador | Ninguna | Nada desde el `configure` siguiente a su baja ([operador.md](operador.md#alta-y-baja-de-una-persona)) |
| Atacante en la red de la plataforma | Ninguna | Intentar suplantar una VM o un nodo (MITM) |
| Dependencia comprometida | Ninguna | Una action, un provider o una imagen que cambia de contenido |

**Qué se quiere evitar, por orden:** 1) que código sin revisar se ejecute con credenciales de
infraestructura; 2) que alguien cambie la infraestructura sin pasar por un PR revisado; 3) que un
colaborador acceda a las VMs de otro proyecto; 4) que una suplantación (de Proxmox, de una VM o de la
imagen base) pase inadvertida; 5) que una credencial filtrada dé más poder del necesario.

## Controles

Cada requisito, el control que lo cumple, dónde está y cómo verificarlo.

| # | Requisito | Control | Dónde | Cómo verificarlo |
|---|---|---|---|---|
| R-01 | Código no revisado nunca con secretos | Las validaciones de PR corren en runners de GitHub, sin secretos ni red a la infraestructura | `.github/workflows/pr-validate.yml` | Un PR que imprime `env` no ve ningún secreto |
| R-02 | Plan de PR sin ejecutar código del PR | `pull_request_target` + checkout de main + solo `requests/` del PR | `.github/workflows/pr-plan.yml` | Un PR que toca `terraform/` no recibe plan; ver abajo |
| R-03 | TLS verificado con Proxmox | `insecure = false` + CA del cluster en el bundle | `terraform/versions.tf`, `scripts/ca-bundle.sh` | Sin la CA en el bundle, el plan falla con `x509` |
| R-04 | Ansible verifica las claves de host | `host_key_checking = True`, `StrictHostKeyChecking=yes` y claves publicadas | `ansible/ansible.cfg`, `scripts/iac` (`configure`, `known-hosts`) | Una clave alterada en `known_hosts` hace fallar Ansible |
| R-05 | Imagen base inmutable | Release fechada + sha256 + firma GPG verificada | `platform.yaml` (`image:`), `terraform/main.tf`, `scripts/image-pin.sh` | Un sha256 cambiado hace fallar la descarga en Proxmox |
| R-06 | Sin credenciales root de los nodos | `import_from` por API, sin `ssh {}` ni replicación por SSH | `terraform/modules/vm/main.tf`, `terraform/versions.tf` | `grep -rn "ssh {" terraform/` no encuentra nada |
| R-07 | Tokens con privilegios mínimos | ACL solo en pools, storages, zona SDN y nodos; nada en `/` | `scripts/iac` (`proxmox-acl`, `preflight`) | `make preflight` con el token exportado |
| R-08 | Runners separados y efímeros | Dos grupos (plan/apply) restringidos a workflows de main; un contenedor por job | `runner/`, [bootstrap.md §6](bootstrap.md#6-runners-propios) | Un workflow en otra rama no consigue runner |
| R-09 | Se aplica exactamente lo planificado | Plan guardado, cifrado entre jobs, sha256 comprobado | `.github/workflows/deploy.yml`, `scripts/encrypt-plan.sh` | Alterar el artefacto hace fallar `apply` |
| R-10 | Secretos de escritura solo en main | Secretos en el environment `production`, que solo despliega desde `main` | [bootstrap.md §5](bootstrap.md#5-environments-y-secretos) | `make preflight` (sin secretos a nivel de repo) |
| R-11 | Cadena de suministro del pipeline | Actions fijadas por SHA, `permissions` mínimos, Dependabot con 14 días de espera | `.github/workflows/*`, `.github/dependabot.yml` | Job `workflows` de pr-validate |
| R-12 | Deriva detectada | Plan diario con `-detailed-exitcode`; falla y abre un issue, sin corregir | `.github/workflows/drift.yml` | Cambiar una VM en la UI + lanzar drift a mano |
| R-13 | *(retirado el 19-oct-2026 junto con el perfil `dataspace-kind`)* | — | — | — |
| R-14 | Acceso a VMs por proyecto | Cuenta Linux solo para miembros del proyecto de la VM; las demás se borran | `terraform/outputs.tf` (`vm_access`), `ansible/roles/base/tasks/access.yml` | Un miembro de otro proyecto no tiene cuenta en la VM |
| R-15 | Nadie cambia main sin revisión | Ruleset: PR obligatorio, aprobación de CODEOWNERS, checks verdes, sin force-push ni bypass | [bootstrap.md §4](bootstrap.md#4-ruleset-de-main) | `make preflight` |

### R-02 Plan de PR sin ejecutar código del PR

El plan de un PR necesita credenciales (estado y API de Proxmox), y por eso es el punto más
delicado. Qué hace `pr-plan.yml`, en orden:

1. Se dispara con `pull_request_target`: el **workflow** que corre es el de `main`. Un PR que cambie
   `pr-plan.yml` no cambia lo que se ejecuta.
2. El job `gate` (runner de GitHub, sin secretos) lista los ficheros del PR por la API. Si alguno
   (o su nombre anterior, en un renombrado) no es `requests/{vms,clusters}/<nombre>.yaml`, no hay
   plan. Tampoco lo hay si el autor no es de confianza (dueño, miembro de la organización o
   colaborador) y el PR no lleva la etiqueta `plan`, que pone un admin tras leerlo y que un push
   nuevo retira.
3. El job `plan` hace checkout de `main` (el código revisado) y, aparte, del PR **solo
   `requests/`**. Comprueba que el commit es el del evento.
4. Aplica sobre `main` solo los ficheros que el PR añade, cambia o borra. Rechaza los enlaces
   simbólicos (un enlace a `/etc/...` lo leería `yamldecode` y saldría en el plan) y todo lo que no
   sea un fichero regular.
5. Valida con el esquema (`schema/`) y con `iac check` de `main`: estructura, rangos del proyecto,
   duplicados y perfiles.
6. `terraform plan -lock=false -refresh=false` con el token `iac@pve!plan` (PVEAuditor). No escribe
   nada en ningún sitio.

Lo que queda: los YAML del PR se interpretan con el código de `main`. Un YAML no puede ejecutar nada
en Terraform (`yamldecode` solo produce datos) ni en `iac check` (`yaml.safe_load`).

### R-04 Claves de host: cómo funciona

- El job `known-hosts` de `deploy.yml` lee las claves de todas las VMs **desde el runner, dentro de
  la red**, y las compara con las del deploy anterior (último artefacto `known_hosts` de main).
- Si una IP ya conocida presenta otra clave y su VM no se ha creado o reemplazado en este deploy, el
  deploy **se para** ([runbook](runbooks.md#clave-de-host-cambiada)).
- `configure` usa ese fichero, y solo ese, en modo estricto. `make ssh` y `make kubeconfig`
  bajan el mismo artefacto.
- El primer contacto con una VM nueva es TOFU ([A-2](#riesgos-aceptados)).

Los nodos de Proxmox no están en ningún `known_hosts` del pipeline, porque nadie entra en ellos por
SSH ([R-06](#controles)). Su identidad la garantiza TLS ([R-03](#controles)).

### R-07 Tokens de Proxmox con privilegios mínimos

`make proxmox-acl` genera los comandos `pveum` desde `platform.yaml` y `projects.yaml`:

| Token | Rol | Rutas |
|---|---|---|
| `iac@pve!apply` (privsep) | `IaCApply` (ver [abajo](#token-de-escritura-iacpveapply)) | `/pool/<pool de cada proyecto>`, `/storage/<datastore>`, `/storage/<image_datastore>`, `/sdn/zones/<zona>`, `/nodes/<cada nodo>` |
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
| A-3 | Los miembros de un proyecto son root en sus VMs (sudo, `docker`) | Son sus máquinas de desarrollo (D-12) | Solo en las VMs de su proyecto (R-14); ningún secreto del pipeline se deja en las VMs | Sin sudo y con roles de Ansible para lo que hoy hacen a mano |
| A-4 | Todos los colaboradores ven las peticiones de todos (nombres, IPs internas, tamaños) | Simplicidad (D-10) | No da acceso: las cuentas SSH son por proyecto | Un repo de peticiones por proyecto |
| A-5 | El PAT que crea los runners vive en el host de runners | Lo exige la API de runners JIT | Fine-grained, solo «Self-hosted runners», fichero `0600` de root, host sin acceso para nadie salvo admins | Una GitHub App con ese único permiso |
| A-6 | (Modelo A) La restricción de grupos de runners a workflows concretos puede no estar en el plan Team | Depende del plan de GitHub | Aunque falte, los devs no pueden crear ramas (D-04) y los runners son efímeros | Verificarlo al crear los grupos ([bootstrap.md §6](bootstrap.md#6-runners-propios)) |
| A-7 | El plan de PR no ve la deriva (`-refresh=false`) | Refrescar exige `VM.Config.Disk` (un permiso de modificación) | El plan de main sí refresca, y drift.yml lo hace a diario | — |
| A-8 | Lo que no gestiona el repo (otras VMs del cluster) queda fuera de la deriva | Terraform solo conoce su estado | Las ACL impiden que el token toque VMs fuera de los pools del repo | — |
| A-9 | Red plana: las VMs de todos los proyectos están en el mismo bridge y se ven entre sí (puertos de servicio incluidos, como la API de k3s) | Simplicidad: un solo bridge y una sola red | Las cuentas SSH son por proyecto (D-10); Cloudflare Gateway solo deja llegar al `:22`, y opcionalmente solo al rango del propio proyecto ([bootstrap.md §10](bootstrap.md#10-acceso-de-los-devs-a-las-vms-vpn), D-13) | Firewall de Proxmox con un grupo de seguridad por proyecto, o una VLAN o zona SDN por proyecto |
| A-10 | Si se pierde la clave de cifrado de las copias, no se puede restaurar ninguna | Es el precio de que ni PBS ni SeaweedFS vean los datos en claro (D-14) | Copia de la clave fuera de la infraestructura, en el gestor de contraseñas, en cuanto se crea ([abajo](#copias-de-seguridad)); restauración de prueba mensual | Una segunda clave maestra RSA de PBS (`proxmox-backup-client key create-master-key`) guardada en otro sitio |
| A-11 | Runners propios en un **repo público** de cuenta personal (modelo B de D-01): sin grupos limitados a workflows | Equipo pequeño sin organización; GitHub los desaconseja en repos públicos | Opt-in `PLATFORM_RUNNERS`; los jobs con runner propio solo salen de `main` (ruleset, sin bypass) o de `pr-plan` con la etiqueta `plan` que pone un admin, y un push nuevo la quita; ningún colaborador salvo los admins; aprobación obligatoria de los workflows de fuera; runners efímeros sin `docker.sock` y con cortafuegos (R-08) | Organización con grupos de runners (modelo A) |
| A-12 | En un repo público, la configuración de la instancia es pública: nodos, IPs internas, rangos, usuarios de GitHub y peticiones | Es GitOps: la fuente de verdad es el repo | Nada de eso da acceso: la red solo se alcanza por la VPN (D-13), las cuentas son por clave SSH y las claves públicas ya son públicas en `github.com/<usuario>.keys`; ningún secreto vive en el repo (R-10) | Repo privado en una organización (modelo A) |

## Inventario de secretos

Cada secreto y cada variable: qué es, dónde vive, quién lo ve, qué alcance tiene y cómo rotarlo. Si
alguno se filtra: [runbooks.md](runbooks.md#secreto-comprometido).

| Secreto / variable | Dónde vive | Lo usan | Alcance |
|---|---|---|---|
| `PM_APPLY_TOKEN` | env `production` | deploy (plan, apply), drift | Token `iac@pve!apply`: rol `IaCApply` en pools, storages, zona y nodos. Nada en `/` |
| `PM_PLAN_TOKEN` | env `plan` | pr-plan | Token `iac@pve!plan`: `PVEAuditor` en las mismas rutas. Solo lectura |
| `TF_API_TOKEN` | envs `production` y `plan` | todos los jobs con Terraform | Token de equipo owners de la organización de HCP, que solo contiene el workspace `pve-platform` |
| `ANSIBLE_SSH_KEY` | env `production` | deploy (configure) | Privada de la cuenta de servicio `ci`: entra como `ops` en todas las VMs |
| `PLAN_ENC_KEY` | env `production` | deploy (plan, apply) | Clave simétrica que cifra el plan entre jobs |
| `TF_CLOUD_ORGANIZATION` | variable del repo | todos | Nombre de la organización de HCP (no es secreto) |
| PAT de runners | `/etc/platform-runner/env` en el host de runners | `runner/supervisor.sh` | Fine-grained: «Self-hosted runners» de la organización, o «Administration» solo de este repo |
| Token del túnel de Cloudflare | servicio `cloudflared` en el LXC del conector | `cloudflared` | Permite levantar un conector de **ese** túnel ([abajo](#túnel-de-cloudflare)) |
| Secret de la OAuth App de GitHub | Zero Trust → Login methods | Cloudflare | Login de las personas en WARP; no da acceso a GitHub |
| Clave de cifrado de las copias | `/etc/pve/priv/storage/pbs-platform.enc` + **copia fuera de la infraestructura** | nodos PVE (vzdump) | Sin ella no se restaura nada ([abajo](#copias-de-seguridad)) |
| Token `pve@pbs!backup` | `/etc/pve/priv/storage/pbs-platform.pw` | nodos PVE | `DatastoreBackup` en `/datastore/platform`: hacer y restaurar sus copias |
| Access key S3 `pbs-platform` | endpoint S3 de PBS | PBS | Leer, escribir y listar solo el bucket `pbs-platform` |

Los environments `production` y `plan` solo despliegan desde `main` ([bootstrap.md §5](bootstrap.md#5-environments-y-secretos)),
así que ningún job de una rama o de un fork recibe estos secretos.

### Token de escritura `iac@pve!apply`

- **Creación:** `make proxmox-acl` ([bootstrap.md §8](bootstrap.md#8-proxmox-tokens-pools-y-acl)).
  Token con privsep: sus permisos son solo sus ACL, no los del usuario `iac@pve`.
- **Rol `IaCApply`** (`APPLY_PRIVS` en `scripts/iac`), privilegio a privilegio:

  | Privilegio | Para qué |
  |---|---|
  | `VM.Allocate`, `VM.Clone`, `VM.Audit` | Crear, borrar y leer VMs (en sus pools) |
  | `VM.Config.*` (CDROM, CPU, Cloudinit, Disk, HWType, Memory, Network, Options) | Configurar la VM; el CDROM es la unidad de cloud-init |
  | `VM.GuestAgent.Audit` | Leer el agente (el provider lo consulta) |
  | `VM.PowerMgmt` | Arrancar y parar la VM |
  | `Pool.Audit` | Ver los pools al asignar la VM |
  | `Datastore.AllocateSpace`, `Datastore.Audit` | Discos de las VMs |
  | `Datastore.AllocateTemplate` | Descargar la imagen base al storage de imágenes |
  | `Sys.AccessNetwork` (en el nodo) | Que el nodo descargue la imagen. Sustituye a `Sys.Modify` en `/` |
  | `SDN.Use` | Conectar la VM al bridge |
  | `Sys.Audit` | Leer el estado del nodo |
- **Rotar:**

  ```sh
  ssh root@<nodo> pveum user token remove iac@pve apply
  make proxmox-acl > acl.sh && scp acl.sh root@<nodo>: && ssh root@<nodo> bash acl.sh   # crea el token nuevo
  gh secret set PM_APPLY_TOKEN -R <OWNER>/pve-platform-iac --env production
  ```
  Después, lanza `drift` a mano: tiene que funcionar con el token nuevo.

### Token de lectura `iac@pve!plan`

Igual que el anterior, con `PVEAuditor`. Lo ven los jobs de `pr-plan` (environment `plan`). Lo peor
que permite es **leer** el inventario de los pools del repo. Para rotarlo, igual, con `plan` y
`PM_PLAN_TOKEN`.

### Token de HCP (`TF_API_TOKEN`)

En los workflows se expone como `TF_TOKEN_app_terraform_io`, que es el nombre que lee Terraform. Es
el token del equipo owners de una organización de HCP **dedicada**: puede leer y escribir el estado
del workspace `pve-platform`. El plan de PR también lo usa ([A-1](#riesgos-aceptados)).
**Rotar:** HCP → Organization settings → Teams → owners → Regenerate token →
`gh secret set TF_API_TOKEN` en `production` y en `plan`.

En local (solo admin):

```sh
export TF_CLOUD_ORGANIZATION=<HCP_ORG>
read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
```

### Clave de Ansible (`ANSIBLE_SSH_KEY`) y cuenta `ops`

`ops` es la cuenta de arranque y de automatización de todas las VMs. cloud-init la crea con las
claves de `admins` y `service` de `projects.yaml`, y el rol `base` las vuelve a sincronizar en cada
`configure` (lista completa: quitar una clave la revoca). **Rotar:** genera un par nuevo, cambia
`service.ci.ssh_key` por PR, mergea (el `configure` de ese deploy aún entra con la clave vieja e
instala la nueva) y después cambia el secreto:

```sh
ssh-keygen -t ed25519 -f ci -C pve-platform-iac-ci -N ''
# PR: projects.yaml -> service.ci.ssh_key = contenido de ci.pub ; merge y espera al deploy
gh secret set ANSIBLE_SSH_KEY -R <OWNER>/pve-platform-iac --env production < ci && shred -u ci
```

### Clave del plan (`PLAN_ENC_KEY`)

Cifra el artefacto del plan entre los jobs `plan` y `apply` ([R-09](#controles)). Se
puede rotar en cualquier momento salvo con un deploy en curso:
`openssl rand -base64 48 | gh secret set PLAN_ENC_KEY -R <OWNER>/pve-platform-iac --env production`.

### PAT de los runners

Lo usa `runner/supervisor.sh` para pedir a GitHub configuraciones JIT de runner. Fine-grained y con el
mínimo permiso: «Self-hosted runners: Read and write» de la organización (modelo A) o
«Administration: Read and write» solo de este repo (modelo B), como en
[runner/README.md](../runner/README.md). Vive en `/etc/platform-runner/env` (root, `0600`). En el host de runners solo entran los
admins. Caduca: pon una fecha y un recordatorio. **Rotar:** crea uno nuevo, cámbialo en el fichero y
`systemctl restart 'platform-runner@*'`.

### Túnel de Cloudflare

Hay dos credenciales:

- **Token del túnel.** Con él, cualquiera puede levantar un conector del túnel `platform`, que
  recibiría el tráfico de los devs hacia sus rutas. `cloudflared service install` lo guarda en la
  unidad systemd del LXC del conector, y en ese LXC solo entran los admins. **Rotar:** en Networks →
  Tunnels → `platform`, crea un túnel nuevo (`platform-2`), instala su conector, mueve las rutas,
  comprueba que llegas y borra el viejo.
- **Secret de la OAuth App de GitHub.** Vive en Zero Trust → Settings → Authentication. Solo sirve
  para el login de las personas. **Rotar:** genera uno nuevo en la OAuth App, pégalo en Cloudflare,
  pulsa Test y borra el viejo en GitHub.

Para quitarle el acceso a **una persona**:
[operador.md](operador.md#alta-y-baja-de-una-persona).

### Copias de seguridad

- **Clave de cifrado** (`pbs-platform.enc`). Es la más crítica: sin ella las copias no sirven, y vive
  en el mismo `/etc/pve` que protege. En cuanto la crees, guarda su contenido en el gestor de
  contraseñas:

  ```sh
  cat /etc/pve/priv/storage/pbs-platform.enc     # JSON: pégalo entero en el gestor de contraseñas
  ```
  Para restaurar en un Proxmox nuevo: añade el storage como en §11 paso 6, pero con
  `--encryption-key "$(cat clave.enc)"` en lugar de `autogen`. **Rotar** no tiene sentido: una clave
  nueva solo cifra las copias nuevas, y las antiguas siguen necesitando la vieja.
- **Token `pve@pbs!backup`.** Solo puede hacer copias y restaurar las suyas. **Rotar:**
  `proxmox-backup-manager user generate-token pve@pbs backup2`, después `acl update` como en el paso
  5, `pvesm set pbs-platform --username 'pve@pbs!backup2' --password '<nuevo>'` y, al final,
  `proxmox-backup-manager user delete-token pve@pbs backup`.
- **Access key S3.** Vive en la configuración del endpoint de PBS. **Rotar:** crea otra identidad
  en el `s3.json` de SeaweedFS, cámbiala en PBS (Configuration → Remotes → S3 Endpoints → Edit) y
  borra la vieja.
- **Para recuperar todo si cae el host**, necesitas tener **fuera de la infraestructura** la clave de
  cifrado, la access key S3 y el nombre del datastore (`platform`). Con eso, en un PBS nuevo:
  `datastore create platform … --reuse-datastore true --overwrite-in-use true`, y el storage en PVE
  como arriba.

### Lo que NO es una credencial

`terraform/certs/pve-root-ca.pem` (la CA del cluster, pública), las claves de host que publica el
artefacto `known_hosts` y las claves públicas de `projects.yaml`.
