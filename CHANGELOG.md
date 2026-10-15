# Changelog

Cambios con impacto para quien usa u opera la plataforma. Formato: versión y fecha, qué y dónde
está documentado. Versionado semántico; mientras sea `0.x`, puede haber cambios incompatibles entre
versiones menores.

## v0.1.0-beta — 15-oct-2026 — Plataforma para empresas y pymes, pública

- **Nombre y enfoque:** `homelab-iac` pasa a ser `pve-platform-iac`, autoservicio de VMs para
  equipos internos de empresas y pymes con Proxmox VE. README en inglés ([README.md](README.md));
  la documentación sigue en español ([README.es.md](README.es.md)).
- **Renombres** (cambio incompatible para una instalación existente):
  - `homelab.yaml` → `platform.yaml`;
  - las etiquetas de los runners → `platform-plan` y `platform-apply`, y la unidad →
    `platform-runner@.service`, en `/etc/platform-runner/`;
  - el workspace de HCP pasa a ser configurable (`TF_WORKSPACE`, por defecto `pve-platform`);
  - el datastore de PBS y el túnel de Cloudflare se llaman `platform`.
- **Repo público:**
  - Los jobs con runners propios son opt-in (variable `PLATFORM_RUNNERS=true`).
  - `pr-plan` solo planifica PRs de personas de fuera con la etiqueta `plan` de un admin.
  - Runners a nivel de repo para cuentas personales (`GH_REPO`).
  - Modelos A (organización) y B (cuenta personal con repo público) en D-01 y en
    [bootstrap.md §1](docs/bootstrap.md#1-organización-de-github-o-cuenta-personal).
  - Nuevos riesgos aceptados A-11 y A-12.
- **Plantilla:** `examples/` y `make init OWNER=…`.
- **Extender el catálogo:** [docs/extender.md](docs/extender.md).
  - `configure` ya no descarta los playbooks de perfiles nuevos.
  - `make check` comprueba que el esquema y el catálogo tienen los mismos perfiles.
- **Dataspace:** el perfil `dataspace-kind` pasa a ser un extra opcional. Sus secretos solo se
  exigen si hay peticiones de ese perfil.
- `LICENSE` (Apache-2.0), [SECURITY.md](SECURITY.md) y un [CONTRIBUTING.md](CONTRIBUTING.md) en
  dos partes.

## 15-oct-2026 — Puesta en marcha de Proxmox documentada

- [docs/bootstrap.md](docs/bootstrap.md) §0: preparar Proxmox antes del repo (disco y datastore, repos
  sin suscripción de PVE 9 en formato deb822, ARC de ZFS, bridge con VLAN, DNS, contenido `import`,
  cluster y quórum con dos nodos, cuenta de admin y segundo factor por usuario, copias de seguridad,
  capacidad y exposición).
- §1: transferir el repo si ya existe en una cuenta personal. §10: VPN para que los devs lleguen a
  las VMs.
- VPN de los devs con Cloudflare Zero Trust: túnel `cloudflared` y cliente WARP con login de GitHub
  (D-13, [docs/bootstrap.md §10](docs/bootstrap.md#10-acceso-de-los-devs-a-las-vms-vpn)), y sus
  credenciales en [docs/credenciales.md](docs/credenciales.md#túnel-de-cloudflare).
- Copias de seguridad con Proxmox Backup Server 4 y datastore en S3 (SeaweedFS), cifradas en el nodo
  (D-14, [docs/bootstrap.md §11](docs/bootstrap.md#11-copias-de-seguridad-proxmox-backup-server-sobre-seaweedfs-s3)),
  runbook [restaurar-vm.md](docs/runbooks/restaurar-vm.md) y riesgo A-10 (pérdida de la clave).
- [docs/seguridad.md](docs/seguridad.md): riesgo aceptado A-9 (red plana entre proyectos).
- `platform.yaml`: `image_datastore` necesita el contenido `import` (antes decía «iso», por error).
- Claves SSH del admin y del CI en `projects.yaml`; cómo cambia de PC un admin en
  [docs/operador.md](docs/operador.md#cambio-de-pc-de-un-admin).

## 14-oct-2026 — Primera versión

Plataforma GitOps para Proxmox VE, derivada de un diseño interno anterior. Decisiones en
[docs/diseno.md](docs/diseno.md); comparación con ese diseño en
[docs/diseno.md](docs/diseno.md#qué-viene-del-diseño-anterior-y-qué-cambia).

- GitHub Actions con cuatro workflows: `pr-validate`, `pr-plan`, `deploy` y `drift` ([docs/pipeline.md](docs/pipeline.md)).
- Estado en HCP Terraform, con ejecución local (D-03).
- Modelo por proyectos (`projects.yaml`): pool, rangos y miembros; acceso SSH solo a las VMs del
  propio proyecto, con las claves de GitHub (D-10).
- Endurecimiento: dos runners efímeros (D-02, R-08), plan de PR sin código del PR (D-05, R-02), plan
  cifrado y aplicado tal cual (D-06, R-09), TLS verificado (R-03), claves de host estrictas (D-09, R-04),
  imagen fijada y verificada (D-07, R-05), sin SSH a los nodos (D-08, R-06) y tokens sin ACL en `/` (R-07).
- Perfil `dataspace-kind` para los MVP de `teo-devops/dataspace-mvp` (D-11, [docs/dataspace.md](docs/dataspace.md)).
- Imagen base: Ubuntu 24.04 `release-20260926` (sha256 `6a81c375…bb4d2`, firma verificada).
