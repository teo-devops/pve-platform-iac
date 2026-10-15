# Extender el catálogo: sabores (flavors) y perfiles propios

**Para quién:** el admin de una instalación que quiere ofrecer a sus equipos tamaños de VM
distintos o un tipo de VM con su software ya instalado (una base de datos, un runner de CI, un
entorno de pruebas…).
**Qué necesitas antes:** la instalación en marcha ([bootstrap.md](bootstrap.md)) y saber escribir
un rol de Ansible.
**Cómo sabrás que ha salido bien:** `make check` y `make lint` en verde; una petición con el
perfil nuevo pasa `pr-plan` y, tras el merge, `configure` ejecuta tu playbook.

El catálogo es **cerrado** a propósito: los equipos solo pueden pedir lo que está en `catalog/`, y
así la capacidad de la infraestructura es previsible. Ampliarlo es un PR del admin.

| Pieza | Qué decide | Fichero |
|---|---|---|
| **Flavor** (sabor) | Cuánto: vCPU, RAM y disco | `catalog/flavors.yaml` |
| **Perfil** | Para qué: qué playbooks se ejecutan en la VM | `catalog/profiles.yaml` |
| Playbook + rol | Cómo se instala | `ansible/playbooks/<perfil>.yml`, `ansible/roles/<rol>/` |

## Añadir un flavor

1. En `catalog/flavors.yaml`:

   ```yaml
   flavors:
     db-medium:
       cores: 4
       memory: 16384     # MB
       disk: 200         # GB
       description: Base de datos mediana
   ```
2. Añádelo a la lista `flavors:` de cada perfil que lo admita (`catalog/profiles.yaml`).
3. `make docs` regenera la tabla de [peticiones.md](peticiones.md) (el CI comprueba que está al
   día), y `make check`.

Cambiar los números de un flavor que ya existe afecta a **todas** sus VMs en el siguiente apply:
Terraform redimensiona CPU y RAM, y el disco solo puede crecer.

## Añadir un perfil

Ejemplo: un perfil `postgres` que instala PostgreSQL.

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
4. **Rol** (`ansible/roles/postgres/`): idempotente, porque `configure` lo vuelve a ejecutar en
   cada deploy. Sin secretos en el repo. Si el rol necesita uno, va al environment `production`
   y se pasa como variable de entorno, que es lo que hace el extra `dataspace-kind`.
5. **Documentación:** una página `docs/<perfil>.md` (para quién, qué necesitas, cómo comprobarlo)
   y su enlace en [README.md](README.md). `make docs` añade el perfil a la tabla del catálogo.
6. `make lint` (incluye `ansible-lint` y `--syntax-check`) y PR.

`configure` ejecuta los playbooks conocidos en su orden (`site`, `k3s`, `monitoring`,
`dataspace-kind`) y los de perfiles nuevos después, en orden alfabético
(`PLAYBOOK_ORDER` en `scripts/iac`).

### Perfiles con datos propios en la petición

Si el perfil necesita parámetros (como el bloque `mvp:` de `dataspace-kind`), añádelos en tres
sitios y con las mismas reglas:
- en el esquema, como propiedad con un `if`/`then` sobre el perfil;
- en `requires:` del catálogo;
- en `iac check` (`validate` en `scripts/iac`) y como `precondition` en `terraform/requests.tf`.

Usa siempre referencias fijadas (un SHA o un tag, nunca una rama) para que lo desplegado sea lo
revisado ([D-11](diseno.md#decisiones)).

## El ejemplo completo: `dataspace-kind`

[dataspace.md](dataspace.md) es un perfil extra real, con todo lo anterior:
- catálogo con `requires: [mvp]`;
- esquema con `if`/`then`;
- `iac check` que rechaza una rama en `mvp.ref`;
- dos roles (`kind_host` y `dataspace_mvp`);
- secretos de despliegue temporales (R-13).
