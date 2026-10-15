# homelab-iac

Infraestructura como código para el Proxmox del homelab, con un modelo **GitOps estricto**: las VMs
y los clusters k3s se piden escribiendo un YAML en `requests/`, se revisan en un PR y solo el
pipeline los aplica. Terraform ([`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox))
crea la infraestructura; Ansible configura el interior (cuentas, Docker, k3s, monitorización y
[MVP de dataspace](docs/dataspace.md)).

```
fork → requests/x.yaml → PR ──► pr-validate (sin secretos) + pr-plan (solo lectura, comentado en el PR)
                                         │
                       admin revisa y mergea
                                         ▼
main ──► deploy: plan → apply del mismo plan → claves de host → Ansible
cada noche ──► drift: falla y abre un issue si Proxmox ≠ main (sin corregir)
```

## Empezar

| Si eres… | Lee |
|---|---|
| Colaborador o freelancer | [docs/inicio-rapido.md](docs/inicio-rapido.md) y [CONTRIBUTING.md](CONTRIBUTING.md) |
| Admin | [docs/bootstrap.md](docs/bootstrap.md) (una vez) y [docs/operador.md](docs/operador.md) |
| Curioso o auditor | [docs/diseno.md](docs/diseno.md) y [docs/seguridad.md](docs/seguridad.md) |

Índice completo: [docs/README.md](docs/README.md). `make` a secas lista los comandos.

## Seguridad, en una tabla

| Requisito | Cómo |
|---|---|
| Nadie aplica con credenciales locales | Solo el pipeline, desde `main`; secretos en el environment `production` |
| Código no revisado nunca con secretos | PRs validados en runners de GitHub sin secretos; el plan del PR usa el código de `main` y solo los YAML del PR |
| Runners separados | `homelab-plan` y `homelab-apply`, efímeros (un contenedor por job), en grupos restringidos a sus workflows |
| Deriva | `drift.yml` diario con `plan -detailed-exitcode`; falla sin corregir |
| TLS con Proxmox | `insecure = false` + CA del cluster |
| SSH verificado en Ansible | `host_key_checking = True` con claves publicadas por el pipeline; TOFU solo al crear la VM |
| Imagen base inmutable | Release fechada + sha256 + firma GPG verificada |
| Privilegios mínimos | Tokens de Proxmox con ACL solo en los pools de los proyectos; ninguna en `/`; sin SSH a los nodos |

Detalle, verificación y riesgos aceptados: [docs/seguridad.md](docs/seguridad.md).

## Estructura

```
.github/workflows/   pr-validate · pr-plan · deploy · drift
homelab.yaml         plataforma: nodos, red, storage, imagen base fijada
projects.yaml        admins, cuentas de servicio y proyectos (pool, rangos, miembros)
catalog/             flavors y perfiles (catalogo cerrado)
requests/            vms/*.yaml y clusters/*.yaml: lo que se pide
schema/              JSON Schema de las peticiones
terraform/           backend (HCP), provider, requests.tf, main.tf, modules/{vm,k3s-cluster}
ansible/             roles base, docker, k3s, monitoring, kind_host, dataspace_mvp
scripts/             iac (CLI), ca-bundle, encrypt-plan, image-pin, check-docs-links
runner/              imagen y supervisor de los runners efimeros del homelab
docs/                documentacion por rol y runbooks
```

## Estado

Al **14-oct-2026**:

- **Hecho y comprobado en local:** `terraform fmt` sin avisos y `terraform validate` correcto con
  claves SSH reales en `projects.yaml` (provider `bpg/proxmox` 0.111.1). Mientras las `ssh_key` de
  `projects.yaml` sigan en `TODO`, `validate` falla **a propósito** (`precondition` de
  `terraform/requests.tf`), y con él `make lint` y el job `pr-validate`: es lo primero que hay que
  rellenar. `iac check` con peticiones de ejemplo (VM con MVP y cluster), rechazo de `mvp.ref` con una
  rama, cifrado y descifrado del plan, comprobación de claves de host fijadas, `image-pin` con la
  firma GPG de Ubuntu verificada (release `20260926`), enlaces de la documentación y tabla del
  catálogo.
- **Pendiente de la puesta en marcha** ([bootstrap.md](docs/bootstrap.md)): crear la organización de
  GitHub (`teo-devops` es una cuenta personal), HCP, runners, ACL de Proxmox y CA; rellenar los `TODO`
  de `homelab.yaml` y `projects.yaml`.
- **Sin probar todavía contra un Proxmox real:** el plan y el apply, los permisos exactos del rol
  `IaCApply`, la importación por `import_from`, los workflows en GitHub y el despliegue del MVP con
  este rol. La verificación prevista está en [docs/bootstrap.md §9](docs/bootstrap.md#9-primer-deploy).

Historial: [CHANGELOG.md](CHANGELOG.md).
