# Diseño

**Para quién:** quien quiera entender cómo funciona la plataforma y por qué es así (admins y
colaboradores curiosos): arquitectura, [pipeline](#pipeline) y [decisiones](#decisiones). Para
usarla: [peticiones.md](peticiones.md). Para operarla: [operador.md](operador.md).

## Qué es

Una plataforma GitOps para un cluster Proxmox VE de 1 a N nodos. **La fuente de verdad es este repositorio**:
crear, cambiar o borrar una máquina es escribir, cambiar o borrar un YAML en `requests/`. Nadie
aplica con credenciales locales; solo el pipeline de GitHub Actions cambia la infraestructura, y solo
después de que un admin revise y mergee el PR.

- **Terraform** (provider [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)) crea
  las VMs a partir de los YAML.
- **Ansible** configura su interior: cuentas de usuario, Docker, k3s y monitorización.
- El **estado** de Terraform vive en HCP Terraform, con bloqueo.

## Flujo

```
 dev / freelancer (rol Read)                       admin (equipo infra-admins)
 ─────────────────────────                         ───────────────────────────
 fork → make new-vm → requests/x.yaml
   │
   └─► PR contra main ──┬─► pr-validate  (runner de GitHub, SIN secretos)
                        │     yamllint · esquema · iac check · fmt · validate · tflint · ansible-lint · actionlint
                        │
                        └─► pr-plan      (runner platform-plan, token Proxmox de SOLO LECTURA)
                              código de main + solo requests/ del PR → plan → comentario en el PR
                                                              │
                                                 revisa el plan y mergea  ◄┘
                                                              │
 main ◄───────────────────────────────────────────────────────┘
   └─► deploy  (runner platform-apply, environment production)
         plan (refresca, token de escritura) → apply DEL MISMO plan → known-hosts → configure (Ansible)

 cada noche ─► drift  (plan -detailed-exitcode): falla y abre un issue si Proxmox ≠ main. No corrige nada.
```

## Piezas

| Pieza | Dónde | Qué hace |
|---|---|---|
| Peticiones | `requests/vms/*.yaml`, `requests/clusters/*.yaml` | Una VM o un cluster k3s por fichero. El nombre del fichero es el de la VM. Referencia: [peticiones.md](peticiones.md) |
| Proyectos | `projects.yaml` | Admins, cuentas de servicio y proyectos (pool, rangos de VMID/IP, miembros). La unidad de aislamiento |
| Plataforma | `platform.yaml` | Nodos, red, almacenamiento e imagen base. Fuente única para Terraform y `scripts/iac` |
| Catálogo | `catalog/flavors.yaml`, `catalog/profiles.yaml` | Tamaños cerrados y perfiles (qué se instala) |
| Terraform | `terraform/` | `requests.tf` lee los YAML y repite las reglas; `main.tf` crea la imagen y las VMs; `modules/vm` y `modules/k3s-cluster` |
| Ansible | `ansible/` | Roles `base` (cuentas), `docker`, `k3s` y `monitoring` |
| CLI | `scripts/iac` + `Makefile` | Asistentes, validación, resúmenes del plan, claves de host, ACL de Proxmox y preflight |
| Pipeline | `.github/workflows/` | `pr-validate`, `pr-plan`, `deploy` y `drift`. Detalle: [Pipeline](#pipeline) |
| Runners | `runner/` | Dos runners efímeros junto al cluster. Detalle: [runner/README.md](../runner/README.md) |

## Decisiones

Cada decisión, con fecha, alternativas descartadas y motivo. El código que las implementa las cita
por su número (p. ej. `D-05`).

### D-01 · Organización de GitHub o cuenta personal con repo público — 14-oct-2026 (rev. 15-oct-2026)

**Decisión:** las dos formas son válidas ([bootstrap.md §1](bootstrap.md#1-organización-de-github-o-cuenta-personal)).
Para una empresa, la recomendada es una **organización**: roles finos (Read/Triage/Write), equipos
y grupos de runners limitados a workflows concretos. La **cuenta personal con repo público** sirve
para equipos pequeños: los devs hacen fork sin ningún rol, y en un repo público los rulesets y los
environments son gratis.
**Alternativas:** cuenta personal con un repo privado. Necesita GitHub Pro para los rulesets y los
environments, y cada colaborador tendría permiso de escritura.
**Por qué:** en una cuenta personal no existe el rol Read: un colaborador podría crear ramas y lanzar
workflows sobre los runners propios. En el modelo B eso se evita así: no hay más colaboradores que
los admins; los jobs con runner propio son opt-in (`PLATFORM_RUNNERS`) y solo se disparan desde
`main` o con la etiqueta `plan` que pone un admin; y las personas de fuera necesitan aprobación
([A-11](seguridad.md#riesgos-aceptados)).
**Instancia de referencia:** `teo-devops/pve-platform-iac` usa el modelo B.

### D-02 · Runners propios en la infraestructura, efímeros y en dos grupos — 14-oct-2026

**Decisión:** dos tipos de runner en un único host de la plataforma (LXC o VM): `platform-plan` y
`platform-apply`. Cada job corre en un contenedor nuevo que se destruye al terminar (configuración
JIT de un solo uso).
**Alternativas:** runners de GitHub con VPN o túnel a la infraestructura; un solo runner para todo; runners
persistentes.
**Por qué:** la API de Proxmox está en una red privada, así que un runner de GitHub no llega a ella.
Separar los grupos impide que el código que planifica un PR comparta máquina o credenciales con el
apply. Al ser efímeros, nada de un job (ficheros, procesos, credenciales) llega al siguiente. «No
dedicado» en el sentido de que no hace falta una máquina física aparte: es un contenedor por job en
un host pequeño.

### D-03 · Estado en HCP Terraform (Free), con ejecución local — 14-oct-2026

**Decisión:** bloque `cloud {}` con un workspace `pve-platform` en modo de ejecución **Local**: HCP solo
guarda el estado (cifrado y versionado) y hace de lock. Los plan/apply corren en nuestros runners.
**Alternativas:** MinIO (S3) en la infraestructura con `use_lockfile`; PostgreSQL en la infraestructura.
**Por qué:** no necesita infraestructura previa (con MinIO, el estado dependería de una pieza que
también hay que crear y mantener), tiene historial de versiones del estado y bloqueo nativo.
**Coste:** el plan Free no tiene tokens de equipo de solo lectura. Ver riesgo aceptado
[A-1](seguridad.md#riesgos-aceptados).

### D-04 · Devs con rol Read y trabajo con forks — 14-oct-2026

**Decisión:** freelancers y colaboradores de la empresa entran en la organización con rol **Read**
sobre el repo y abren sus PR **desde un fork**. Solo `infra-admins` tiene Maintain/Admin.
**Alternativas:** rol Write y ramas en el propio repo.
**Por qué:** con Write, cualquiera podría crear una rama con un workflow modificado (`on: push`) y
ejecutarlo en los runners de la plataforma. Con Read no se pueden crear ramas en el repo, y los workflows
de un fork no tienen acceso a nuestros runners ni a nuestros secretos.

### D-05 · El plan de los PR no ejecuta código del PR — 14-oct-2026

**Decisión:** `pr-plan.yml` usa `pull_request_target` (el workflow siempre es el de `main`), hace
checkout de `main` y aplica encima **solo los ficheros de `requests/`** que cambia el PR, y solo si
el PR no toca nada más. Los YAML pasan el esquema y `iac check` antes de Terraform.
**Alternativas:** `pull_request` con el código del PR (lo ejecutaría en la infraestructura con credenciales);
no hacer plan en los PR (el admin revisaría a ciegas).
**Por qué:** las peticiones son **datos**, no código. Terraform las lee con `yamldecode`, que no
ejecuta nada. Un PR que cambia código (Terraform, Ansible, scripts o workflows) no tiene plan
automático: lo revisa y planifica el admin. Detalle de las comprobaciones (enlaces simbólicos,
rutas, carreras entre pushes) en [seguridad.md R-02](seguridad.md#r-02-plan-de-pr-sin-ejecutar-código-del-pr).

### D-06 · En main: plan refrescando y apply del mismo plan, cifrado entre jobs — 14-oct-2026

**Decisión:** el job `plan` refresca el estado con el token de escritura y guarda `tfplan`. El job
`apply` aplica **ese** fichero, sin recalcular, tras comprobar su sha256. Entre jobs, el plan viaja
cifrado (AES-256, `PLAN_ENC_KEY`) y el artefacto se borra al día.
**Alternativas:** `terraform apply` sin plan guardado (podría aplicar algo distinto de lo revisado);
plan y apply en el mismo job (se pierde el resumen separado y el punto de corte).
**Por qué:** lo que se aplica es exactamente lo que se ha calculado y resumido. Si el estado cambia
entre medias, Terraform rechaza el plan («Saved plan is stale») en vez de aplicar a ciegas. El
cifrado es necesario porque cualquiera con rol Read puede descargar los artefactos.

### D-07 · Imagen base fijada por release y sha256 — 14-oct-2026

**Decisión:** la imagen de Ubuntu 24.04 se descarga desde una release **fechada**
(`release-AAAAMMDD`), nunca desde `current`, con `checksum` sha256 que Proxmox comprueba.
`make image-pin` elige la release y verifica la firma GPG de `SHA256SUMS` con la clave de Canonical
(huella fijada en el script). Las VMs ignoran los cambios de imagen (`ignore_changes`).
**Alternativas:** `current/` (cambia sin aviso y sin revisión); una plantilla de VM hecha a mano.
**Por qué:** la imagen es parte de la infraestructura revisada. Cambiarla es un PR y no recrea las
VMs existentes, solo afecta a las nuevas.

### D-08 · Ninguna conexión SSH a los nodos de Proxmox — 14-oct-2026

**Decisión:** el disco de cada VM se importa con `import_from` (contenido `import`, por la API) y no
con `file_id`, que el provider importa por SSH. No hay replicación por `pvesh` sobre SSH (en
el diseño anterior sí). El provider no tiene bloque `ssh {}`.
**Alternativas:** dar al pipeline la clave root de los nodos, como en el diseño anterior.
**Por qué:** una clave root de los nodos anula cualquier restricción de los tokens. Sin ella, todo lo
que hace el pipeline pasa por la API y por las ACL de [R-07](seguridad.md#r-07-tokens-de-proxmox-con-privilegios-mínimos).
**Requisito:** Proxmox VE con soporte del contenido `import` (8.4 o posterior; el provider se prueba
con 9.x).

### D-09 · Claves de host: TOFU solo al crear la VM, después estrictas — 14-oct-2026

**Decisión:** el job `known-hosts` lee las claves con `ssh-keyscan` **desde dentro de la red**,
minutos después del apply. Una VM ya conocida tiene que presentar la misma clave que en el deploy
anterior; solo las VMs que el plan crea o reemplaza pueden traer una nueva. Ansible verifica
siempre (`StrictHostKeyChecking=yes`, `UserKnownHostsFile` = esas claves).
**Alternativas:** `host_key_checking = False` (lo que había en el diseño anterior); fijar la clave de host
desde Terraform con cloud-init (sin TOFU, pero deja claves privadas en el estado, necesita snippets
de cloud-init y solo sirve para VMs nuevas).
**Por qué:** cierra la suplantación de una VM existente (un cambio de clave inesperado para el
pipeline) con un cambio pequeño. La ventana de TOFU es la primera conexión a una VM recién creada,
desde el runner y dentro de la red. Ver [A-2](seguridad.md#riesgos-aceptados).

### D-10 · Aislamiento por proyecto: de acceso, no de visibilidad — 14-oct-2026

**Decisión:** cada proyecto tiene su pool de Proxmox, sus rangos de VMID/IP y sus miembros. Cada
miembro solo tiene cuenta (SSH) en las VMs de **su** proyecto. Todos los colaboradores ven todas las
peticiones del repo.
**Alternativas:** un repo de peticiones por proyecto, agregado por el pipeline central (aislamiento
también de lectura).
**Por qué:** es mucho más simple de operar, y lo que se ve (nombres, IPs internas y tamaños) no da
acceso a nada. Ver [A-4](seguridad.md#riesgos-aceptados). Si un cliente lo exige, la evolución es el
repo por proyecto.

### D-11 · *(retirada el 19-oct-2026)*

Perfil de ejemplo `dataspace-kind`. Se retiró para que la plantilla sea genérica; el número no se
reutiliza.

### D-12 · Los miembros tienen sudo en las VMs de su proyecto — 14-oct-2026

**Decisión:** las cuentas personales están en el grupo `iac-users`, con sudo sin contraseña, y en el
grupo `docker` en las VMs que lo tienen.
**Por qué:** son máquinas de desarrollo del propio proyecto; muchas cargas necesitan Docker, y el
grupo `docker` ya equivale a root. Restringirlo daría una falsa sensación de seguridad.
Lo que sí está aislado es **qué VMs** son suyas (D-10). Ver [A-3](seguridad.md#riesgos-aceptados).

### D-13 · VPN de los devs con Cloudflare Zero Trust (túnel + WARP) — 15-oct-2026

**Decisión:** los devs llegan a la red de las VMs con el cliente WARP, autenticados con su cuenta de
GitHub. El tráfico entra a la infraestructura por un túnel `cloudflared` saliente, desde un LXC dedicado, y las
políticas de Gateway lo limitan al `:22` de la red de las VMs. Cómo se monta:
[bootstrap.md §10](bootstrap.md#10-acceso-de-los-devs-a-las-vms-vpn).
**Por qué:**
- No se abre ningún puerto del router ni hace falta una IP pública.
- La identidad es la misma cuenta de GitHub de `projects.yaml`.
- Cada acceso se revoca por persona y por dispositivo, y queda un registro de conexiones.
- El plan Free cubre hasta 50 usuarios.

**Alternativas:**
- *Tailscale*: igual de sencillo, pero las ACL de grupo son de pago a partir de cierto tamaño y
  añade otra cuenta más.
- *WireGuard propio*: exige abrir un puerto en el router, y la gestión de claves por persona es
  manual.
- *Bastión SSH expuesto*: Internet llega a un SSH de la infraestructura.

**Coste:** Cloudflare ve los metadatos (quién se conecta, a qué IP y puerto y cuándo), pero no el
contenido, porque SSH va cifrado de extremo a extremo. Si Cloudflare cae, no se puede entrar a las
VMs, aunque las VMs y el pipeline siguen funcionando: los runners no usan el túnel.

### D-14 · Copias con Proxmox Backup Server sobre S3 (SeaweedFS) — 15-oct-2026

**Decisión:** Proxmox VE copia cada noche todas las VMs y LXC a Proxmox Backup Server 4. El
datastore de PBS usa como *backend* un bucket S3 (SeaweedFS en el ejemplo) en otra máquina. Las copias
se cifran en el nodo con una clave que se guarda fuera de la infraestructura. Cómo se monta:
[bootstrap.md §11](bootstrap.md#11-copias-de-seguridad-proxmox-backup-server-sobre-seaweedfs-s3).
**Por qué:**
- Proxmox VE no escribe en S3; PBS sí, desde la versión 4.
- PBS deduplica y hace copias incrementales: cada noche solo sube lo que ha cambiado.
- El cifrado en el cliente evita confiar en el almacenamiento.
- Cualquier S3 compatible sirve; SeaweedFS es ligero y autoalojado.

**Alternativas:**
- *MinIO*: su edición comunitaria ha dejado de mantenerse.
- *`vzdump` a un directorio y después `rclone` a S3*: copias completas cada vez, sin deduplicar,
  y más scripts que mantener.
- *PBS con un disco local*: queda en el mismo hardware que lo que protege.

**Coste:**
- El backend S3 de PBS es reciente (PBS 4, 2025): hay que probar la restauración de verdad, no solo
  que la copia termina.
- PBS necesita una caché local de 64–128 GiB.
- Un datastore S3 solo lo puede usar una instancia de PBS a la vez.
- Si se pierde la clave de cifrado, las copias no sirven ([A-10](seguridad.md#riesgos-aceptados)).

## Qué viene del diseño anterior y qué cambia

Este repo deriva de un diseño GitOps anterior para Proxmox (un proyecto interno, en GitLab). Se
reutiliza la idea y buena parte del código: las peticiones YAML, el catálogo cerrado, las reglas de `iac check`
repetidas como `precondition`, el rol `base` de cuentas personales y el inventario generado. Cambia:

| Diseño anterior | pve-platform-iac | Por qué |
|---|---|---|
| GitLab CI, estado en GitLab | GitHub Actions, estado en HCP | D-01, D-03 |
| `team.yaml` (personas con rangos) | `projects.yaml` (proyectos con miembros) | D-10 |
| Claves del perfil de GitLab | Claves de `github.com/<usuario>.keys` | Identidad en GitHub |
| Un runner para todo | Dos grupos efímeros | D-02 |
| `insecure = true` | `insecure = false` + CA del cluster | [R-03](seguridad.md#controles) |
| `host_key_checking = False` | Estricto con claves publicadas | D-09 |
| Imagen `current` | Release fechada + sha256 | D-07 |
| Token con ACL en `/` | ACL solo en pools, storage, zona y nodos | [R-07](seguridad.md#r-07-tokens-de-proxmox-con-privilegios-mínimos) |
| SSH root a los nodos (replicación) | Sin SSH a los nodos | D-08 |

## Pipeline

Cada workflow y cada job: cuándo se dispara, dónde corre, qué secretos ve, qué hace y cómo
depurarlo. El porqué de cada control está en [seguridad.md](seguridad.md).


| Workflow | Cuándo | Runner | Secretos | Qué hace |
|---|---|---|---|---|
| `pr-validate.yml` | PR, push a main y a mano | GitHub (`ubuntu-latest`) | ninguno | Linters y validaciones sin credenciales |
| `pr-plan.yml` | PR abierto o actualizado | `platform-plan` | env `plan` | Plan de solo lectura de las peticiones del PR, comentado en el PR |
| `deploy.yml` | push a main (salvo solo docs) y a mano | `platform-apply` | env `production` | plan → apply → known-hosts → configure |
| `drift.yml` | cada día 05:17 UTC y a mano | `platform-apply` | env `production` | Plan de deriva; falla y abre un issue si hay cambios |

### pr-validate

Corre el código del PR **tal cual**, por eso va en runners de GitHub, sin secretos ni red a la infraestructura
([R-01](seguridad.md#controles)). Sus jobs son los checks obligatorios del ruleset.

| Job | Comprueba | Si falla |
|---|---|---|
| `peticiones y catalogo` | yamllint, esquema de `schema/` sobre `requests/`, `iac check` (rangos, duplicados, perfiles), tabla del catálogo y enlaces de `docs/` | El mensaje dice el fichero y la regla. En local: `make check`, `make lint` |
| `terraform` | `fmt -check`, `validate` (sin backend, lockfile de solo lectura) y tflint | `make fmt` y `make validate` |
| `ansible` | `--syntax-check` de cada playbook, ansible-lint, shellcheck y compilación de los scripts de Python | El log señala el fichero |
| `workflows (actionlint)` | actionlint y que toda action esté fijada por SHA completo | Fija la action por SHA, con la versión en un comentario |

> Un PR desde un fork necesita que un admin pulse **Approve and run** la primera vez
> ([bootstrap.md §1](bootstrap.md#1-organización-de-github-o-cuenta-personal), paso 5).

### pr-plan

Detalle de seguridad en [seguridad.md R-02](seguridad.md#r-02-plan-de-pr-sin-ejecutar-código-del-pr).

| Job | Dónde | Qué hace |
|---|---|---|
| `gate` | GitHub, sin secretos | Lista los ficheros del PR. Solo sigue si **todos** son `requests/{vms,clusters}/*.yaml` y el autor es de confianza (dueño, miembro o colaborador) o el PR lleva la etiqueta `plan` |
| `plan` | `platform-plan`, env `plan` | Checkout de main + ficheros del PR → esquema + `iac check` → `terraform plan -lock=false -refresh=false` → comentario en el PR (uno por PR, se actualiza en cada push) |

**El comentario:** una tabla por petición (crear, modificar, recrear y destruir), un aviso si algo
se destruye y el plan completo plegado. Si el PR toca algo fuera de `requests/`, el resumen del run
dice «Sin plan automático»: es lo esperado, y lo planifica el admin.

**Depurar:**
- «refs/pull apunta a … y el evento es de …»: llegó un push mientras tanto; el evento siguiente hace
  el plan.
- Falla `iac check`: el mensaje es el mismo que da `make check` en local.
- Falla `terraform init` con 401: token de HCP caducado o mal copiado
  ([seguridad.md](seguridad.md#token-de-hcp-tf_api_token)).
- `x509: certificate signed by unknown authority`: la CA de `terraform/certs/` no es la del cluster
  ([bootstrap.md §3](bootstrap.md#3-ca-del-cluster-proxmox-tls-verificado)).
- El job se queda en «Waiting for a runner»: [runbooks.md](runbooks.md#runner-caído).

### deploy

Un deploy detrás de otro (`concurrency: deploy`, sin cancelar el que está en marcha).

| Job | Qué hace | Salida |
|---|---|---|
| `plan` | `iac check` → `terraform plan -detailed-exitcode -out=tfplan` **refrescando** con el token de escritura → resumen en el run → `sha256` → cifra el plan (`scripts/encrypt-plan.sh`) → artefacto `tfplan` (1 día) | `changes`, `sha256`, `new_vms` |
| `apply` | Solo si hay cambios. Descarga y descifra, comprueba el `sha256` y aplica `terraform apply tfplan` | — |
| `known-hosts` | Baja el `known_hosts` del deploy anterior. `iac known-hosts --scan --wait 300 --pinned … --allow-new <new_vms>` → artefacto `known_hosts` (90 días) | El fichero que usan configure y `make ssh` |
| `configure` | Inventario desde el estado → playbooks de los perfiles en uso (`iac configure --known-hosts known_hosts`), con la clave de `ci` en un ssh-agent | — |

`known-hosts` y `configure` corren también **sin cambios de infraestructura**: un cambio en
`members` solo necesita Ansible.

**Lanzar a mano** (Actions → deploy → Run workflow, solo admins): reaplica todo. El campo
`accept_host_keys` acepta la clave nueva de las VMs indicadas
([runbook](runbooks.md#clave-de-host-cambiada)).

**Depurar:**
- `apply`: «Saved plan is stale»: el estado cambió entre el plan y el apply (otro apply, o un
  break-glass). Relanza el deploy.
- `apply`: «El plan descifrado no es el que generó el job plan»: el artefacto se ha alterado. **No
  lo relances sin investigarlo** ([runbook](runbooks.md#secreto-comprometido)).
- `apply` falla a medias: [runbooks.md](runbooks.md#apply-fallido).
- `known-hosts`: «La clave de host de … NO coincide»: [runbooks.md](runbooks.md#clave-de-host-cambiada).
- `configure` con `Host key verification failed`: la VM no respondió al escaneo (¿apagada?). Mira la
  salida del job `known-hosts`.
- Estado bloqueado: [runbooks.md](runbooks.md#estado-bloqueado).

### drift

`terraform plan -detailed-exitcode -lock=false` refrescando contra Proxmox: código 0 = todo bien; 2 =
deriva (el job falla y abre o comenta el issue `drift`); 1 = error. **No corrige nada**: lo decide el
admin ([runbooks.md](runbooks.md#deriva-detectada)).

Tiene su propio grupo de concurrencia: en GitHub, un run pendiente nuevo cancela al pendiente
anterior del mismo grupo, y un drift no debe cancelar un deploy en cola.

### Comandos de `scripts/iac` que usa el pipeline

| Comando | Job |
|---|---|
| `iac check` | pr-validate, pr-plan, deploy/plan |
| `iac flavors --check-docs` | pr-validate |
| `iac plan-summary --markdown [--plan f]` | pr-plan, deploy/plan, drift |
| `iac plan-new-vms` | deploy/plan |
| `iac known-hosts --scan --pinned … --allow-new …` | deploy/known-hosts |
| `iac configure --known-hosts known_hosts` | deploy/configure |

### Versiones fijadas

Terraform `1.16.5` (`TF_VERSION` en cada workflow), el provider en `terraform/.terraform.lock.hcl`, las
actions por SHA, las herramientas de Python con `==`, tflint y actionlint por etiqueta de imagen, y el
runner en `runner/Dockerfile`. Dependabot propone las subidas con al menos 14 días de antigüedad.
Subir Terraform: cambia `TF_VERSION` en los cuatro workflows en el mismo PR.
