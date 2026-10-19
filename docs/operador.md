# Operación (admin)

**Para quién:** quien tenga el rol de admin: los `admins` de `projects.yaml` (con organización de
GitHub, también el equipo `infra-admins`). El admin es un **rol**, no una persona: todo lo que sigue
lo puede hacer cualquiera que lo tenga.

**Qué necesitas:** `gh` con permisos de admin del repo (y de la organización, en el modelo A),
acceso al host de runners y, solo para break-glass, las credenciales del
[inventario de secretos](seguridad.md#inventario-de-secretos) en tu gestor de contraseñas.

Puesta en marcha desde cero: [bootstrap.md](bootstrap.md). Incidentes: [runbooks.md](runbooks.md).

## Revisar un PR

1. **¿Quién lo pide y para qué proyecto?** El autor tiene que ser miembro del `project` de la
   petición (`projects.yaml`). Si pide para un proyecto ajeno, se rechaza.
2. **¿Qué toca?**
   - Solo `requests/` y el autor es de **fuera** (fork sin rol, en un repo público): `pr-plan` no
     planifica solo. Lee el YAML y, si es razonable, ponle la etiqueta **`plan`**
     (`gh pr edit <n> --add-label plan`). Si el autor hace otro push, la etiqueta desaparece y hay
     que volver a revisarlo.
   - Solo `requests/`: `pr-plan` ha comentado el plan. Comprueba que crea o cambia lo que dice el PR
     y que **no destruye ni recrea** nada que no se haya borrado o renombrado a propósito (el
     comentario lo marca en negrita, con un aviso).
   - Algo más (Terraform, Ansible, scripts, workflows, `projects.yaml`, `platform.yaml`): no hay plan
     automático, por diseño ([D-05](diseno.md#decisiones)). Lee el diff entero; si cambia
     infraestructura, haz el plan en local (`make plan`, abajo) o divide el PR.
   - Un PR que cambia `.github/` es el más delicado: puede cambiar qué código corre con secretos
     **después** del merge.
3. **Checks verdes** (los exige el ruleset) y aprobación de CODEOWNERS.
4. **Merge.** El deploy empieza solo. Síguelo en Actions → deploy.

> Un PR desde un fork necesita «Approve and run» para su primer `pr-validate`. Míralo antes: aunque
> corre sin secretos en un runner de GitHub, gasta minutos de la organización.

## Alta de un proyecto

1. PR a `projects.yaml`: el proyecto con su `pool` (p. ej. `proj-<nombre>`), un rango de VMIDs y
   otro de IPs que **no se solapen** con los demás (`make check` lo comprueba) y sus `members`.
2. En Proxmox, el pool y sus ACL. El script es idempotente: genera todo y no rompe lo que ya existe.

   ```sh
   make proxmox-acl > acl.sh && scp acl.sh root@<nodo>: && ssh root@<nodo> bash acl.sh
   ```
3. Merge. A partir de ahí, sus miembros pueden pedir VMs.

## Alta y baja de una persona

- **Alta:** añade su usuario de GitHub a `members` del proyecto (PR). Con organización (modelo A),
  añádelo también al equipo `colaboradores` (rol Read en el repo). Con un repo público (modelo B),
  **no** lo hagas colaborador: trabaja con un fork ([D-01](diseno.md#decisiones)). Comprueba que su perfil tiene una clave SSH
  (`curl https://github.com/<usuario>.keys`): sin clave, el `configure` falla avisando.

  ```sh
  gh api -X PUT orgs/<ORG>/teams/colaboradores/memberships/<usuario> -f role=member
  ```
  Añade su email a las listas de Cloudflare: inscripción de dispositivos y política `devs-ssh-vms`,
  o la de su proyecto ([bootstrap.md §10](bootstrap.md#10-acceso-de-los-devs-a-las-vms-vpn)).
- **Baja:** quítalo de `members` (PR y merge). En el `configure` de ese deploy, el rol `base` borra
  su cuenta en todas las VMs (su `home` se queda, por si hay algo que recuperar). Después,
  sácalo de la organización (solo con el modelo A):

  ```sh
  gh api -X DELETE orgs/<ORG>/memberships/<usuario>
  ```
  Si se va con conflicto, haz la baja de GitHub **primero** (pierde el acceso al repo al instante),
  y lanza el deploy a mano para que pierda el SSH.
  En Cloudflare Zero Trust, quita su email de las listas y revoca sus dispositivos y sesiones (My
  Team → Users → el usuario → Revoke). Así pierde también la red, aunque el deploy aún no haya
  borrado su cuenta.
- **Rotar su clave:** la cambia esa persona en GitHub, y se aplica en el siguiente `configure` (o lanza deploy
  a mano).

## Alta de un admin

1. En GitHub: con organización, al equipo `infra-admins`; con cuenta personal, colaborador del repo
   con rol Admin (los únicos colaboradores son los admins, [A-11](seguridad.md#riesgos-aceptados)).
2. PR a `projects.yaml`: su usuario en `admins` con su `ssh_key` (entra en `ops` de todas las VMs y
   tiene cuenta personal en todas).
3. Acceso al host de runners y a las credenciales de break-glass.

## Cambio de PC de un admin

Un admin tiene **dos** claves distintas en las VMs, y hay que cambiar las dos:

| Dónde vive | Para qué | Se cambia en |
|---|---|---|
| `projects.yaml` → `admins.<usuario>.ssh_key` | cuenta `ops` de todas las VMs | PR al repo |
| `https://github.com/<usuario>.keys` | su cuenta personal en las VMs | Settings → SSH keys de GitHub |

El pipeline entra con la clave del CI (`service.ci`, secreto `ANSIBLE_SSH_KEY`), **no** con la de
ningún admin. Por eso el cambio se aplica igual aunque el PC viejo ya no exista o se haya perdido:

```sh
# En el PC nuevo
ssh-keygen -t ed25519 -C "<usuario>@<pc-nuevo>"
gh ssh-key add ~/.ssh/id_ed25519.pub --title "<pc-nuevo>"   # pide el scope admin:public_key
# PR: projects.yaml -> admins.<usuario>.ssh_key = contenido de ~/.ssh/id_ed25519.pub ; merge
```

El `configure` de ese deploy sustituye la lista completa de claves de `ops` (la vieja queda
revocada) y vuelve a leer tus claves de GitHub. Las VMs que ya existían no se recrean: cloud-init
solo se usa en el primer arranque, y Terraform ignora ese cambio (`ignore_changes` en
`terraform/modules/vm/main.tf`). Comprueba que entras con `make ssh NAME=<vm>`. Al final, borra en
GitHub la clave del PC viejo; si lo has **perdido**, hazlo lo primero
([runbooks.md](runbooks.md#secreto-comprometido)).

Una sola clave por admin en `projects.yaml` es deliberado. Mientras haces el cambio, puedes seguir
entrando con la cuenta personal si ya has añadido la clave nueva en GitHub.

## Subir la imagen base

```sh
make image-pin            # la última release (o REL=AAAAMMDD)
git diff platform.yaml     # release, url y sha256 nuevos; firma verificada
```

PR. El plan tiene que **reemplazar solo** `proxmox_download_file.base_image[...]`, con **0 VMs**
cambiadas: las existentes no se recrean ([D-07](diseno.md#decisiones)). Las VMs nuevas arrancan de
la imagen nueva.

## Deriva

El workflow `drift` corre cada día. Si falla, hay un issue `drift`:
[runbooks.md](runbooks.md#deriva-detectada).

## Mantenimiento periódico

| Cada | Qué |
|---|---|
| semana | PRs de Dependabot (actions, provider, imagen del runner): revisar y mergear |
| mes | `make image-pin` (parches de seguridad de Ubuntu en las VMs nuevas) |
| mes | ¿Hay VMs que nadie usa? `make list` y preguntar a cada proyecto |
| antes de que caduque | PAT de runners ([seguridad.md](seguridad.md#pat-de-los-runners)) |
| mes | Restauración de prueba de una VM ([runbooks.md](runbooks.md#prueba-mensual)) y revisar en PBS que la copia diaria, la retención, la limpieza y la verificación salen en verde |
| trimestre | Revisar miembros de la organización y de cada proyecto; `make preflight` |

## Ampliar el catálogo

El catálogo es **cerrado** a propósito: los equipos solo pueden pedir lo que está en `catalog/`, y
así la capacidad es previsible. Ampliarlo es un PR del admin.

| Pieza | Qué decide | Fichero |
|---|---|---|
| **Flavor** | Cuánto: vCPU, RAM y disco | `catalog/flavors.yaml` |
| **Familia de cluster** | Flavors de master y worker, número de workers y versión de k3s | `catalog/flavors.yaml` (`cluster_sizes`) |
| **Perfil** | Para qué: qué playbooks se ejecutan en la VM | `catalog/profiles.yaml` |
| Playbook + rol | Cómo se instala | `ansible/playbooks/<perfil>.yml`, `ansible/roles/<rol>/` |

### Un flavor o una familia de cluster

1. En `catalog/flavors.yaml`:

   ```yaml
   flavors:
     db-medium:
       cores: 4
       memory: 16384     # MB
       disk: 200         # GB
       description: Base de datos mediana
   ```
   Una familia de cluster necesita sus dos flavors (`<familia>-master` y `<familia>-worker`) y su
   entrada en `cluster_sizes` (`min_workers`, `default_workers`, `k3s_version`), y se añade a
   `cluster_profiles.k3s.sizes` de `catalog/profiles.yaml`.
2. Añade el flavor a la lista `flavors:` de cada perfil que lo admita (`catalog/profiles.yaml`).
3. `make docs` regenera la tabla de [peticiones.md](peticiones.md#catálogo) (el CI comprueba que
   está al día) y `make check`.

Cambiar los números de un flavor que ya existe afecta a **todas** sus VMs en el siguiente apply:
Terraform redimensiona CPU y RAM, y el disco solo puede crecer.

### Un perfil

Ejemplo: un perfil `postgres`. El perfil `monitoring` (`ansible/playbooks/monitoring.yml` y
`ansible/roles/monitoring/`) es un ejemplo completo y real de lo que sigue.

1. **Catálogo** (`catalog/profiles.yaml`):

   ```yaml
   vm_profiles:
     postgres:
       description: PostgreSQL 16 con copias locales
       playbooks: [site, postgres]     # site (cuentas, chrony, node-exporter) siempre primero
       flavors: [vm-medium, db-medium]
   ```
2. **Esquema** (`schema/vm.schema.json`): añade `"postgres"` al `enum` de `profile`. `make check`
   falla si el esquema y el catálogo no tienen los mismos perfiles.
3. **Playbook** (`ansible/playbooks/postgres.yml`). El inventario agrupa las VMs sueltas por perfil
   (con `-` cambiado a `_`), así que el play apunta al grupo:

   ```yaml
   ---
   - name: PostgreSQL
     hosts: postgres
     become: true
     roles:
       - postgres
   ```
4. **Rol** (`ansible/roles/postgres/`): idempotente, porque `configure` lo vuelve a ejecutar en cada
   deploy. Sin secretos en el repo: si necesita uno, va al environment `production` y se pasa como
   variable de entorno en el job `configure` de `deploy.yml`.
5. `make docs` añade el perfil a la tabla del catálogo; `make lint` (incluye `ansible-lint` y
   `--syntax-check` en el CI) y PR.

`configure` ejecuta los playbooks conocidos en su orden (`site`, `k3s`, `monitoring`) y los de
perfiles nuevos después, en orden alfabético (`PLAYBOOK_ORDER` en `scripts/iac`).

Si el perfil necesita **parámetros propios** en la petición, añádelos con las mismas reglas en tres
sitios: el esquema (una propiedad con `if`/`then` sobre el perfil), `iac check` (`validate` en
`scripts/iac`) y una `precondition` en `terraform/requests.tf`. Si apuntan a código externo, que sea
por SHA o tag, nunca por rama: lo desplegado tiene que ser lo revisado.

## Break-glass

Aplicar sin pipeline es la **excepción**: GitHub caído, runner caído durante una emergencia o un
estado que hay que reparar. Todo lo que se haga se apunta en el registro de abajo.

```sh
export TF_CLOUD_ORGANIZATION=<HCP_ORG>
read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
read -rs TF_VAR_pm_api_token && export TF_VAR_pm_api_token      # iac@pve!apply
make plan        # check + plan + resumen; guarda terraform/tfplan
make apply       # aplica ESE plan; pide escribir 'aplicar' (o 'destruir')
make known-hosts SCAN=1      # claves de host (TOFU desde tu maquina: compara las huellas)
make configure KNOWN_HOSTS=~/.ssh/known_hosts.pve-platform-iac   # Ansible
```

Después: un PR que deje `main` igual que lo aplicado (si no, el siguiente drift lo marcará como
deriva), y una línea en el registro.

### Registro de break-glass

| Fecha | Quién | Qué y por qué | PR de vuelta a main |
|---|---|---|---|
| — | — | — | — |
