# Pipeline

**Para quién:** admins, y devs que quieran entender qué pasa con su PR. Cada workflow y cada job:
cuándo se dispara, dónde corre, qué secretos ve, qué hace y cómo depurarlo. El porqué de cada pieza
está en [diseno.md](diseno.md) y [seguridad.md](seguridad.md).

## Resumen

| Workflow | Cuándo | Runner | Secretos | Qué hace |
|---|---|---|---|---|
| `pr-validate.yml` | PR, push a main y a mano | GitHub (`ubuntu-latest`) | ninguno | Linters y validaciones sin credenciales |
| `pr-plan.yml` | PR abierto o actualizado | `platform-plan` | env `plan` | Plan de solo lectura de las peticiones del PR, comentado en el PR |
| `deploy.yml` | push a main (salvo solo docs) y a mano | `platform-apply` | env `production` | plan → apply → known-hosts → configure |
| `drift.yml` | cada día 05:17 UTC y a mano | `platform-apply` | env `production` | Plan de deriva; falla y abre un issue si hay cambios |

## pr-validate

Corre el código del PR **tal cual**, por eso va en runners de GitHub, sin secretos ni red a la infraestructura
([R-01](seguridad.md#controles)). Sus jobs son los checks obligatorios del ruleset.

| Job | Comprueba | Si falla |
|---|---|---|
| `peticiones y catalogo` | yamllint, esquema de `schema/` sobre `requests/`, `iac check` (rangos, duplicados, perfiles, `mvp.ref`), tabla del catálogo y enlaces de `docs/` | El mensaje dice el fichero y la regla. En local: `make check`, `make lint` |
| `terraform` | `fmt -check`, `validate` (sin backend, lockfile de solo lectura) y tflint | `make fmt` y `make validate` |
| `ansible` | `--syntax-check` de cada playbook, ansible-lint, shellcheck y compilación de los scripts de Python | El log señala el fichero |
| `workflows (actionlint)` | actionlint y que toda action esté fijada por SHA completo | Fija la action por SHA, con la versión en un comentario |

> Un PR desde un fork necesita que un admin pulse **Approve and run** la primera vez
> ([bootstrap.md §1](bootstrap.md#1-organización-de-github-o-cuenta-personal), paso 5).

## pr-plan

Detalle de seguridad en [seguridad.md R-02](seguridad.md#r-02-plan-de-pr-sin-ejecutar-código-del-pr).

| Job | Dónde | Qué hace |
|---|---|---|
| `gate` | GitHub, sin secretos | Lista los ficheros del PR. Solo sigue si **todos** son `requests/{vms,clusters}/*.yaml` y el autor es de la organización |
| `plan` | `platform-plan`, env `plan` | Checkout de main + ficheros del PR → esquema + `iac check` → `terraform plan -lock=false -refresh=false` → comentario en el PR (uno por PR, se actualiza en cada push) |

**El comentario:** una tabla por petición (crear, modificar, recrear y destruir), un aviso si algo
se destruye y el plan completo plegado. Si el PR toca algo fuera de `requests/`, el resumen del run
dice «Sin plan automático»: es lo esperado, y lo planifica el admin.

**Depurar:**
- «refs/pull apunta a … y el evento es de …»: llegó un push mientras tanto; el evento siguiente hace
  el plan.
- Falla `iac check`: el mensaje es el mismo que da `make check` en local.
- Falla `terraform init` con 401: token de HCP caducado o mal copiado
  ([credenciales.md](credenciales.md#token-de-hcp-tf_api_token)).
- `x509: certificate signed by unknown authority`: la CA de `terraform/certs/` no es la del cluster
  ([bootstrap.md §3](bootstrap.md#3-ca-del-cluster-proxmox-tls-verificado)).
- El job se queda en «Waiting for a runner»: [runbooks/runner-caido.md](runbooks/runner-caido.md).

## deploy

Un deploy detrás de otro (`concurrency: deploy`, sin cancelar el que está en marcha).

| Job | Qué hace | Salida |
|---|---|---|
| `plan` | `iac check` → `terraform plan -detailed-exitcode -out=tfplan` **refrescando** con el token de escritura → resumen en el run → `sha256` → cifra el plan (`scripts/encrypt-plan.sh`) → artefacto `tfplan` (1 día) | `changes`, `sha256`, `new_vms` |
| `apply` | Solo si hay cambios. Descarga y descifra, comprueba el `sha256` y aplica `terraform apply tfplan` | — |
| `known-hosts` | Baja el `known_hosts` del deploy anterior. `iac known-hosts --scan --wait 300 --pinned … --allow-new <new_vms>` → artefacto `known_hosts` (90 días) | El fichero que usan configure y `make ssh` |
| `configure` | Inventario desde el estado → playbooks de los perfiles en uso (`iac configure --known-hosts known_hosts`), con la clave de `ci` en un ssh-agent | — |

`known-hosts` y `configure` corren también **sin cambios de infraestructura**: un cambio en
`members` o en `mvp.ref` solo necesita Ansible.

**Lanzar a mano** (Actions → deploy → Run workflow, solo admins): reaplica todo. El campo
`accept_host_keys` acepta la clave nueva de las VMs indicadas
([runbook](runbooks/clave-de-host-cambiada.md)).

**Depurar:**
- `apply`: «Saved plan is stale»: el estado cambió entre el plan y el apply (otro apply, o un
  break-glass). Relanza el deploy.
- `apply`: «El plan descifrado no es el que generó el job plan»: el artefacto se ha alterado. **No
  lo relances sin investigarlo** ([runbook](runbooks/token-comprometido.md)).
- `apply` falla a medias: [runbooks/apply-fallido.md](runbooks/apply-fallido.md).
- `known-hosts`: «La clave de host de … NO coincide»: [runbooks/clave-de-host-cambiada.md](runbooks/clave-de-host-cambiada.md).
- `configure` con `Host key verification failed`: la VM no respondió al escaneo (¿apagada?). Mira la
  salida del job `known-hosts`.
- `configure` falla en un MVP: el diagnóstico (pods, eventos y log) sale en el propio job.
  [dataspace.md](dataspace.md#si-falla).
- Estado bloqueado: [runbooks/lock-estado.md](runbooks/lock-estado.md).

## drift

`terraform plan -detailed-exitcode -lock=false` refrescando contra Proxmox: código 0 = todo bien; 2 =
deriva (el job falla y abre o comenta el issue `drift`); 1 = error. **No corrige nada**: lo decide el
admin ([runbooks/deriva-detectada.md](runbooks/deriva-detectada.md)).

Tiene su propio grupo de concurrencia: en GitHub, un run pendiente nuevo cancela al pendiente
anterior del mismo grupo, y un drift no debe cancelar un deploy en cola.

## Comandos de `scripts/iac` que usa el pipeline

| Comando | Job |
|---|---|
| `iac check` | pr-validate, pr-plan, deploy/plan |
| `iac flavors --check-docs` | pr-validate |
| `iac plan-summary --markdown [--plan f]` | pr-plan, deploy/plan, drift |
| `iac plan-new-vms` | deploy/plan |
| `iac known-hosts --scan --pinned … --allow-new …` | deploy/known-hosts |
| `iac configure --known-hosts known_hosts` | deploy/configure |

## Versiones fijadas

Terraform `1.16.5` (`TF_VERSION` en cada workflow), el provider en `terraform/.terraform.lock.hcl`, las
actions por SHA, las herramientas de Python con `==`, tflint y actionlint por etiqueta de imagen, y el
runner en `runner/Dockerfile`. Dependabot propone las subidas con al menos 14 días de antigüedad.
Subir Terraform: cambia `TF_VERSION` en los cuatro workflows en el mismo PR.
