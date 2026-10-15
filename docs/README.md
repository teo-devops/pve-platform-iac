# Documentación

Qué leer según quién seas.

## Colaborador o freelancer

| Documento | Para |
|---|---|
| [inicio-rapido.md](inicio-rapido.md) | De cero a tu primera VM: fork, petición, PR y `make ssh` |
| [peticiones.md](peticiones.md) | Cada campo de los YAML de `requests/`, perfiles y tamaños |
| [dataspace.md](dataspace.md) | Pedir un MVP de dataspace, acceder, lanzar las pruebas y qué hacer si falla |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Normas: qué puedes tocar y cómo |

## Admin

| Documento | Para |
|---|---|
| [bootstrap.md](bootstrap.md) | Montar todo desde cero: organización, ruleset, environments, HCP, runners, Proxmox |
| [operador.md](operador.md) | El día a día: revisar PRs, altas y bajas, imagen base y break-glass |
| [credenciales.md](credenciales.md) | Cada secreto: qué es, dónde vive, alcance y cómo rotarlo |
| [pipeline.md](pipeline.md) | Cada workflow y job, y cómo depurarlo |
| [../runner/README.md](../runner/README.md) | El host de runners |
| [runbooks/](runbooks/) | Incidentes: [deriva](runbooks/deriva-detectada.md), [clave de host cambiada](runbooks/clave-de-host-cambiada.md), [lock del estado](runbooks/lock-estado.md), [apply fallido](runbooks/apply-fallido.md), [runner caído](runbooks/runner-caido.md), [secreto comprometido](runbooks/token-comprometido.md) |

## Todos

| Documento | Para |
|---|---|
| [diseno.md](diseno.md) | Cómo funciona y por qué: arquitectura, flujo y decisiones (D-01…D-13) |
| [seguridad.md](seguridad.md) | Modelo de amenazas, controles (R-01…R-15) y riesgos aceptados (A-1…A-8) |

## Convenciones de esta documentación

- Cada documento dice **para quién es**, **qué necesitas antes** y **cómo saber que ha salido bien**.
- Las decisiones (`D-nn`), los controles (`R-nn`) y los riesgos aceptados (`A-n`) se citan con ese
  número también desde el código.
- Un cambio de comportamiento lleva su cambio de documentación **en el mismo PR**. El CI comprueba
  los enlaces internos (`scripts/check-docs-links.py`) y la tabla del catálogo (`make docs`).
- Las fechas, en formato `14-oct-2026`.
