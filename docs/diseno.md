# Diseño

**Para quién:** quien quiera entender cómo funciona la plataforma y por qué es así (admins y
colaboradores curiosos). Para usarla: [inicio-rapido.md](inicio-rapido.md). Para operarla:
[operador.md](operador.md).

## Qué es

Una plataforma GitOps para el Proxmox del homelab. **La fuente de verdad es este repositorio**:
crear, cambiar o borrar una máquina es escribir, cambiar o borrar un YAML en `requests/`. Nadie
aplica con credenciales locales; solo el pipeline de GitHub Actions cambia la infraestructura, y solo
después de que un admin revise y mergee el PR.

- **Terraform** (provider [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)) crea
  las VMs a partir de los YAML.
- **Ansible** configura su interior: cuentas de usuario, Docker, k3s, monitorización y los MVP de
  dataspace.
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
                        └─► pr-plan      (runner homelab-plan, token Proxmox de SOLO LECTURA)
                              código de main + solo requests/ del PR → plan → comentario en el PR
                                                              │
                                                 revisa el plan y mergea  ◄┘
                                                              │
 main ◄───────────────────────────────────────────────────────┘
   └─► deploy  (runner homelab-apply, environment production)
         plan (refresca, token de escritura) → apply DEL MISMO plan → known-hosts → configure (Ansible)

 cada noche ─► drift  (plan -detailed-exitcode): falla y abre un issue si Proxmox ≠ main. No corrige nada.
```

## Piezas

| Pieza | Dónde | Qué hace |
|---|---|---|
| Peticiones | `requests/vms/*.yaml`, `requests/clusters/*.yaml` | Una VM o un cluster k3s por fichero. El nombre del fichero es el de la VM. Referencia: [peticiones.md](peticiones.md) |
| Proyectos | `projects.yaml` | Admins, cuentas de servicio y proyectos (pool, rangos de VMID/IP, miembros). La unidad de aislamiento |
| Plataforma | `homelab.yaml` | Nodos, red, almacenamiento e imagen base. Fuente única para Terraform y `scripts/iac` |
| Catálogo | `catalog/flavors.yaml`, `catalog/profiles.yaml` | Tamaños cerrados y perfiles (qué se instala) |
| Terraform | `terraform/` | `requests.tf` lee los YAML y repite las reglas; `main.tf` crea la imagen y las VMs; `modules/vm` y `modules/k3s-cluster` |
| Ansible | `ansible/` | Roles `base` (cuentas), `docker`, `k3s`, `monitoring`, `kind_host` y `dataspace_mvp` |
| CLI | `scripts/iac` + `Makefile` | Asistentes, validación, resúmenes del plan, claves de host, ACL de Proxmox y preflight |
| Pipeline | `.github/workflows/` | `pr-validate`, `pr-plan`, `deploy` y `drift`. Detalle: [pipeline.md](pipeline.md) |
| Runners | `runner/` | Dos runners efímeros en el homelab. Detalle: [runner/README.md](../runner/README.md) |

## Decisiones

Cada decisión, con fecha, alternativas descartadas y motivo. El código que las implementa las cita
por su número (p. ej. `D-05`).

### D-01 · Repositorio en una organización de GitHub (plan Team) — 14-oct-2026

**Decisión:** el repo vive en una organización de GitHub, no en la cuenta personal `teo-devops`.
**Alternativas:** cuenta personal con GitHub Pro; cuenta gratuita.
**Por qué:** en una cuenta personal, todo colaborador tiene permiso de escritura (no hay rol Read) y
podría crear ramas y lanzar workflows sobre los runners del homelab. Una organización da roles finos
(Read/Triage/Write), equipos, rulesets y grupos de runners. En repos privados, los rulesets y los
environments con restricciones de rama necesitan el plan Team.
**Hecho comprobado:** el 14-oct-2026, `teo-devops` es una cuenta personal (`type: User`). Hay que
crear la organización ([bootstrap.md](bootstrap.md#1-organización-de-github)). Los repos
`dataspace-mvp`, dsgen y los paquetes de ghcr pueden seguir en `teo-devops`: el homelab solo los lee.

### D-02 · Runners propios en el homelab, efímeros y en dos grupos — 14-oct-2026

**Decisión:** dos tipos de runner en un único host del homelab (LXC o VM): `homelab-plan` y
`homelab-apply`. Cada job corre en un contenedor nuevo que se destruye al terminar (configuración
JIT de un solo uso).
**Alternativas:** runners de GitHub con VPN o túnel al homelab; un solo runner para todo; runners
persistentes.
**Por qué:** la API de Proxmox está en una red privada, así que un runner de GitHub no llega a ella.
Separar los grupos impide que el código que planifica un PR comparta máquina o credenciales con el
apply. Al ser efímeros, nada de un job (ficheros, procesos, credenciales) llega al siguiente. «No
dedicado» en el sentido de que no hace falta una máquina física aparte: es un contenedor por job en
un host pequeño.

### D-03 · Estado en HCP Terraform (Free), con ejecución local — 14-oct-2026

**Decisión:** bloque `cloud {}` con un workspace `homelab` en modo de ejecución **Local**: HCP solo
guarda el estado (cifrado y versionado) y hace de lock. Los plan/apply corren en nuestros runners.
**Alternativas:** MinIO (S3) en el homelab con `use_lockfile`; PostgreSQL en el homelab.
**Por qué:** no necesita infraestructura previa (con MinIO, el estado dependería de una pieza que
también hay que crear y mantener), tiene historial de versiones del estado y bloqueo nativo.
**Coste:** el plan Free no tiene tokens de equipo de solo lectura. Ver riesgo aceptado
[A-1](seguridad.md#riesgos-aceptados).

### D-04 · Devs con rol Read y trabajo con forks — 14-oct-2026

**Decisión:** freelancers y colaboradores de la empresa entran en la organización con rol **Read**
sobre el repo y abren sus PR **desde un fork**. Solo `infra-admins` tiene Maintain/Admin.
**Alternativas:** rol Write y ramas en el propio repo.
**Por qué:** con Write, cualquiera podría crear una rama con un workflow modificado (`on: push`) y
ejecutarlo en los runners del homelab. Con Read no se pueden crear ramas en el repo, y los workflows
de un fork no tienen acceso a nuestros runners ni a nuestros secretos.

### D-05 · El plan de los PR no ejecuta código del PR — 14-oct-2026

**Decisión:** `pr-plan.yml` usa `pull_request_target` (el workflow siempre es el de `main`), hace
checkout de `main` y aplica encima **solo los ficheros de `requests/`** que cambia el PR, y solo si
el PR no toca nada más. Los YAML pasan el esquema y `iac check` antes de Terraform.
**Alternativas:** `pull_request` con el código del PR (lo ejecutaría en el homelab con credenciales);
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
proxmox-iac sí). El provider no tiene bloque `ssh {}`.
**Alternativas:** dar al pipeline la clave root de los nodos, como en proxmox-iac.
**Por qué:** una clave root de los nodos anula cualquier restricción de los tokens. Sin ella, todo lo
que hace el pipeline pasa por la API y por las ACL de [R-07](seguridad.md#r-07-tokens-de-proxmox-con-privilegios-mínimos).
**Requisito:** Proxmox VE con soporte del contenido `import` (8.4 o posterior; el provider se prueba
con 9.x).

### D-09 · Claves de host: TOFU solo al crear la VM, después estrictas — 14-oct-2026

**Decisión:** el job `known-hosts` lee las claves con `ssh-keyscan` **desde dentro de la red**,
minutos después del apply. Una VM ya conocida tiene que presentar la misma clave que en el deploy
anterior; solo las VMs que el plan crea o reemplaza pueden traer una nueva. Ansible verifica
siempre (`StrictHostKeyChecking=yes`, `UserKnownHostsFile` = esas claves).
**Alternativas:** `host_key_checking = False` (lo que había en proxmox-iac); fijar la clave de host
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

### D-11 · Dataspaces: el MVP se despliega con sus propios scripts, en un ref fijado — 14-oct-2026

**Decisión:** el perfil `dataspace-kind` clona `teo-devops/dataspace-mvp` en un **SHA o tag**
(nunca una rama) y ejecuta `scripts/ciclo-de-vida/kind-up.sh` del MVP indicado en `mvp.path`. Las
credenciales (una deploy key de solo lectura y un token de ghcr de solo `read:packages`) existen en
la VM solo durante el despliegue.
**Alternativas:** reimplementar el despliegue del MVP en Ansible; una rama como ref.
**Por qué:** dsgen ya genera un MVP completo y probado (`kind-up.sh`, `bruno.sh`): duplicarlo sería
mantenerlo dos veces. Con un ref fijado, lo desplegado es exactamente lo revisado en el PR. Detalle
en [dataspace.md](dataspace.md).

### D-12 · Los miembros tienen sudo en las VMs de su proyecto — 14-oct-2026

**Decisión:** las cuentas personales están en el grupo `iac-users`, con sudo sin contraseña, y en el
grupo `docker` en las VMs que lo tienen.
**Por qué:** son máquinas de desarrollo del propio proyecto; kind y los scripts del MVP necesitan
Docker, y el grupo `docker` ya equivale a root. Restringirlo daría una falsa sensación de seguridad.
Lo que sí está aislado es **qué VMs** son suyas (D-10). Ver [A-3](seguridad.md#riesgos-aceptados).

## Qué viene de proxmox-iac y qué cambia

Este repo deriva de `proxmox-iac`, el repo del cluster retech de i2cat, que sigue igual. Se reutiliza
la idea y buena parte del código: las peticiones YAML, el catálogo cerrado, las reglas de `iac check`
repetidas como `precondition`, el rol `base` de cuentas personales, el inventario generado y la
vigilancia del despliegue del dataspace. Cambia:

| proxmox-iac | homelab-iac | Por qué |
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
| Escenario de i2cat (GitLab) | MVP de `dataspace-mvp` (GitHub, dsgen) | D-11 |
