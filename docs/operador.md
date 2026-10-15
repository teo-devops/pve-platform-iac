# Operación (admin)

**Para quién:** quien tenga el rol de admin (equipo `infra-admins` y `admins` en `projects.yaml`).
El admin es un **rol**, no una persona: todo lo que sigue lo puede hacer cualquiera que lo tenga.

**Qué necesitas:** `gh` con permisos de admin de la organización, acceso al host de runners y, solo
para break-glass, las credenciales de [credenciales.md](credenciales.md) en tu gestor de
contraseñas.

Puesta en marcha desde cero: [bootstrap.md](bootstrap.md).

## Revisar un PR

1. **¿Quién lo pide y para qué proyecto?** El autor tiene que ser miembro del `project` de la
   petición (`projects.yaml`). Si pide para un proyecto ajeno, se rechaza.
2. **¿Qué toca?**
   - Solo `requests/`: `pr-plan` ha comentado el plan. Comprueba que crea o cambia lo que dice el PR
     y que **no destruye ni recrea** nada que no se haya borrado o renombrado a propósito (el
     comentario lo marca en negrita, con un aviso).
   - Algo más (Terraform, Ansible, scripts, workflows, `projects.yaml`, `homelab.yaml`): no hay plan
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

- **Alta:** añade la organización (equipo `colaboradores`, rol Read en el repo) y su usuario de
  GitHub a `members` del proyecto (PR). Comprueba que su perfil tiene una clave SSH
  (`curl https://github.com/<usuario>.keys`): sin clave, el `configure` falla avisando.

  ```sh
  gh api -X PUT orgs/<ORG>/teams/colaboradores/memberships/<usuario> -f role=member
  ```
- **Baja:** quítalo de `members` (PR y merge). En el `configure` de ese deploy, el rol `base` borra
  su cuenta en todas las VMs (su `home` se queda, por si hay algo que recuperar). Después,
  sácalo de la organización:

  ```sh
  gh api -X DELETE orgs/<ORG>/memberships/<usuario>
  ```
  Si se va con conflicto, haz la baja de GitHub **primero** (pierde el acceso al repo al instante),
  y lanza el deploy a mano para que pierda el SSH.
- **Rotar su clave:** la cambia él en GitHub, y se aplica en el siguiente `configure` (o lanza deploy
  a mano).

## Alta de un admin

1. Equipo `infra-admins` en GitHub.
2. PR a `projects.yaml`: su usuario en `admins` con su `ssh_key` (entra en `ops` de todas las VMs y
   tiene cuenta personal en todas).
3. Acceso al host de runners y a las credenciales de break-glass.

## Subir la imagen base

```sh
make image-pin            # la última release (o REL=AAAAMMDD)
git diff homelab.yaml     # release, url y sha256 nuevos; firma verificada
```

PR. El plan tiene que **reemplazar solo** `proxmox_download_file.base_image[...]`, con **0 VMs**
cambiadas: las existentes no se recrean ([D-07](diseno.md#decisiones)). Las VMs nuevas arrancan de
la imagen nueva.

## Deriva

El workflow `drift` corre cada día. Si falla, hay un issue `drift`:
[runbooks/deriva-detectada.md](runbooks/deriva-detectada.md).

## Mantenimiento periódico

| Cada | Qué |
|---|---|
| semana | PRs de Dependabot (actions, provider, imagen del runner): revisar y mergear |
| mes | `make image-pin` (parches de seguridad de Ubuntu en las VMs nuevas) |
| mes | ¿Hay VMs que nadie usa? `make list` y preguntar a cada proyecto |
| antes de que caduque | PAT de runners y token de ghcr ([credenciales.md](credenciales.md)) |
| trimestre | Revisar miembros de la organización y de cada proyecto; `make preflight` |

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
make configure KNOWN_HOSTS=~/.ssh/known_hosts.homelab-iac   # Ansible; credenciales del MVP en credenciales.md
```

Después: un PR que deje `main` igual que lo aplicado (si no, el siguiente drift lo marcará como
deriva), y una línea en el registro.

### Registro de break-glass

| Fecha | Quién | Qué y por qué | PR de vuelta a main |
|---|---|---|---|
| — | — | — | — |
