# Cómo colaborar

Este repo es dos cosas a la vez, y se colabora distinto en cada una:

1. **La plataforma** (el código: Terraform, Ansible, workflows, `scripts/`, docs). Cualquiera puede
   proponer mejoras: [Contribuir a la plataforma](#contribuir-a-la-plataforma).
2. **Una instalación concreta** (su `platform.yaml`, `projects.yaml` y `requests/`). Ahí piden
   infraestructura los equipos de esa instalación: [Pedir infraestructura](#pedir-infraestructura).

## Contribuir a la plataforma

- **Issues** para fallos y propuestas; un **PR** por cambio, desde tu fork, contra `main`.
- Los fallos de seguridad **no** van en un issue: [SECURITY.md](SECURITY.md).
- `make lint` y `make check` en verde. Son los mismos checks que el CI (`pr-validate`), y corren en
  runners de GitHub sin secretos.
- Cada cambio de comportamiento lleva su documentación en el mismo PR, y si es una decisión de
  diseño, su entrada `D-nn` en [docs/diseno.md](docs/diseno.md).
- No metas datos de tu instalación (IPs, nombres de nodos, usuarios) en un PR a la plataforma.
- Licencia: al contribuir aceptas publicar tu aportación bajo [Apache-2.0](LICENSE).

## Pedir infraestructura

Para los equipos de una instalación (colaboradores de la empresa y freelancers). Paso a paso:
[docs/peticiones.md](docs/peticiones.md).

### Lo esencial

- **Trabajas desde tu fork.** Los cambios llegan por PR contra `main`. Nadie (tampoco los admins) empuja directamente a `main`.
- **Un PR = una cosa.** Lo ideal: un PR que solo toca `requests/`. Así recibe el plan automático en
  un comentario y se revisa rápido.
- **Pide solo para tus proyectos** y solo lo que vayas a usar. Bórralo cuando termines (`make remove`).
- **No escribas a mano `vmid` ni `ip`, ni renombres peticiones**: usa los asistentes
  ([reglas comunes](docs/peticiones.md#reglas-comunes)).
- **Nunca subas secretos** (tokens, claves privadas, kubeconfigs). Aunque el repo sea privado, lo
  leen todos los colaboradores de todos los proyectos; si es público, cualquiera.

### Qué puedes cambiar

| Ruta | ¿Por PR de un colaborador? | Notas |
|---|---|---|
| `requests/` | Sí | Plan automático en el PR |
| `docs/` | Sí | Bienvenido: si algo no estaba claro, arréglalo |
| `ansible/roles/`, `catalog/` | Sí, con revisión del admin | Sin plan automático; explica el porqué en el PR |
| `terraform/`, `scripts/`, `schema/` | Sí, con revisión del admin | Sin plan automático; el admin lo planifica |
| `.github/`, `runner/`, `projects.yaml`, `platform.yaml` | Solo el admin | Definen quién tiene acceso y qué se ejecuta con secretos |

### Requisitos de un PR

- `make check` y `make lint` en verde en local (son los mismos checks que el CI).
- Si cambias cómo funciona algo, cambias su documentación **en el mismo PR**. El CI comprueba los
  enlaces internos (`scripts/check-docs-links.py`) y la tabla del catálogo (`make docs`).
- Mensajes de commit en español o en inglés, en presente: «Pide equipo-a-db», «Add the X profile».
- Si tu PR destruye o recrea algo (renombrar o borrar una petición), dilo en la descripción.

### Acceso a las VMs

Cómo entras, qué puedes hacer en ellas y qué hacer si cambia la clave de host:
[docs/peticiones.md §5](docs/peticiones.md#5-usa-lo-que-has-creado).

### Si algo va mal

Abre un issue (o comenta en tu PR) con el enlace al run que falla. Para incidentes de seguridad
(una credencial expuesta o un acceso que no deberías tener), avisa al admin directamente.
