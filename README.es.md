# pve-platform-iac

[English](README.md) · **Español**

> **Beta (v0.1.0).** Diseño y documentación completos y validados en CI, pero **aún sin probar
> contra un Proxmox real**. Ver [Estado](#estado).

Autoservicio de máquinas virtuales para **equipos internos de empresas y pymes que virtualizan con
Proxmox VE**, con un modelo **GitOps estricto**: las VMs y los clusters k3s se piden escribiendo un
YAML en `requests/`, se revisan en un PR y solo el pipeline los aplica. Terraform
([`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)) crea la infraestructura;
Ansible configura el interior (cuentas por proyecto, Docker, k3s, monitorización).

Lo que se puede pedir es un **catálogo cerrado de sabores** (tamaños y perfiles) que cada
instalación amplía con los suyos ([docs/extender.md](docs/extender.md)). El perfil
[`dataspace-kind`](docs/dataspace.md) es un **extra opcional** de ejemplo.

El cluster Proxmox se instala antes con [platform-proxmox](https://github.com/teo-devops/platform-proxmox)
(de 2 a N nodos).

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
| Admin | [docs/bootstrap.md](docs/bootstrap.md) (una vez; empieza por `make init`), [docs/operador.md](docs/operador.md) y [docs/extender.md](docs/extender.md) |
| Curioso o auditor | [docs/diseno.md](docs/diseno.md) y [docs/seguridad.md](docs/seguridad.md) |

Índice completo: [docs/README.md](docs/README.md). `make` a secas lista los comandos.

## Seguridad, en una tabla

| Requisito | Cómo |
|---|---|
| Nadie aplica con credenciales locales | Solo el pipeline, desde `main`; secretos en el environment `production` |
| Código no revisado nunca con secretos | PRs validados en runners de GitHub sin secretos; el plan del PR usa el código de `main` y solo los YAML del PR |
| Runners separados | `platform-plan` y `platform-apply`, efímeros (un contenedor por job), en grupos restringidos a sus workflows |
| Deriva | `drift.yml` diario con `plan -detailed-exitcode`; falla sin corregir |
| TLS con Proxmox | `insecure = false` + CA del cluster |
| SSH verificado en Ansible | `host_key_checking = True` con claves publicadas por el pipeline; TOFU solo al crear la VM |
| Imagen base inmutable | Release fechada + sha256 + firma GPG verificada |
| Privilegios mínimos | Tokens de Proxmox con ACL solo en los pools de los proyectos; ninguna en `/`; sin SSH a los nodos |

Detalle, verificación y riesgos aceptados: [docs/seguridad.md](docs/seguridad.md).

## Estructura

```
.github/workflows/   pr-validate · pr-plan · deploy · drift
platform.yaml         plataforma: nodos, red, storage, imagen base fijada
projects.yaml        admins, cuentas de servicio y proyectos (pool, rangos, miembros)
catalog/             flavors y perfiles (catalogo cerrado)
requests/            vms/*.yaml y clusters/*.yaml: lo que se pide
schema/              JSON Schema de las peticiones
terraform/           backend (HCP), provider, requests.tf, main.tf, modules/{vm,k3s-cluster}
ansible/             roles base, docker, k3s, monitoring, kind_host, dataspace_mvp
scripts/             iac (CLI), ca-bundle, encrypt-plan, image-pin, check-docs-links
runner/              imagen y supervisor de los runners efimeros de la plataforma
docs/                documentacion por rol y runbooks
```

## Estado

Al **15-oct-2026**:

- **Hecho y comprobado en local:** `terraform fmt` y `terraform validate` sin avisos (provider
  `bpg/proxmox` 0.111.1; `validate` exige claves SSH reales en `projects.yaml`, rellenas desde el
  15-oct-2026), `iac check` con peticiones de ejemplo (VM con MVP y cluster), rechazo de `mvp.ref` con una
  rama, cifrado y descifrado del plan, comprobación de claves de host fijadas, `image-pin` con la
  firma GPG de Ubuntu verificada (release `20260926`), enlaces de la documentación y tabla del
  catálogo.
- **Pendiente de la puesta en marcha de la instancia de referencia** (`teo-devops`, modelo B de
  [D-01](docs/diseno.md#decisiones)): instalar el cluster, HCP, runners, ACL de Proxmox y CA;
  rellenar los `TODO` de `platform.yaml`; subir la clave SSH del admin a su perfil de GitHub.
- **Sin tests unitarios** de `scripts/iac` ni `terraform test`: es lo siguiente antes de una 1.0.
- **Sin probar todavía contra un Proxmox real:** el plan y el apply, los permisos exactos del rol
  `IaCApply`, la importación por `import_from`, los workflows en GitHub y el despliegue del MVP con
  este rol. La verificación prevista está en [docs/bootstrap.md §9](docs/bootstrap.md#9-primer-deploy).

Historial: [CHANGELOG.md](CHANGELOG.md).
