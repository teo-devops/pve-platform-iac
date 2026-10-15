# Inicio rápido: de cero a tu primera VM

**Para quién:** colaboradores de la empresa y freelancers. No necesitas saber Terraform ni tener
ninguna credencial de infraestructura: pides por PR y el pipeline lo crea cuando un admin lo
aprueba.

**Qué necesitas antes de empezar:**

- Una cuenta de GitHub, que el admin haya añadido a la organización y como miembro de tu proyecto en
  `projects.yaml` ([operador.md](operador.md#alta-y-baja-de-una-persona)).
- Una clave SSH en tu perfil de GitHub (GitHub → Settings → SSH and GPG keys). Si no tienes:
  `ssh-keygen -t ed25519` y pega el contenido de `~/.ssh/id_ed25519.pub`. Con esa clave entrarás en
  tus VMs.
- `git`, `python3` con PyYAML (`sudo apt install python3-yaml`), `ssh` y, muy recomendable, la CLI
  de GitHub [`gh`](https://cli.github.com) autenticada (`gh auth login`).
- Acceso de red al homelab (VPN) para entrar en las VMs. Para pedirlas no hace falta.

**Cómo sabrás que ha salido bien:** `make ssh NAME=<tu-vm>` te deja dentro de la VM con tu usuario.

## 1. Fork y clon

Tienes permiso de **lectura** sobre el repo: los cambios se proponen desde tu fork.

```sh
gh repo fork <ORG>/homelab-iac --clone --remote   # origin = tu fork, upstream = el repo central
cd homelab-iac
make setup && make doctor
```

`make doctor` tiene que decir quién eres en GitHub, en qué proyectos estás y cuántas claves SSH
tiene tu perfil.

## 2. Pide la VM

```sh
git switch main && git pull upstream main     # parte siempre de lo último
make flavors                                  # tamaños y perfiles
make new-vm                                   # asistente
```

El asistente pregunta el proyecto (si estás en varios), para qué es la VM (el perfil), el tamaño y
el nombre. Asigna solo un VMID y una IP libres **del rango de tu proyecto**, y escribe
`requests/vms/<nombre>.yaml`. Para un MVP de dataspace, ver [dataspace.md](dataspace.md).

> [!WARNING]
> No cambies `vmid` ni `ip` a mano: fuera de tu rango pueden ser los de otro proyecto (y `make check`
> lo rechaza). **Renombrar** el fichero destruye y recrea la VM; **borrarlo** la destruye.

## 3. Abre el PR

```sh
git switch -c pide-<nombre>
git add requests/vms/<nombre>.yaml && git commit -m "Pide <nombre>"
git push -u origin pide-<nombre>
gh pr create --repo <ORG>/homelab-iac --fill
```

En el PR verás:

1. **pr-validate**: comprobaciones sin credenciales. La primera vez, un admin tiene que pulsar
   «Approve and run» (es un PR desde un fork).
2. **pr-plan**: un comentario con el plan: qué se crea, en qué proyecto, y un aviso si algo se
   destruye. Solo sale si tu PR toca **únicamente** `requests/`.

Si algo falla, el mensaje dice qué fichero y qué regla. Arréglalo, `git commit` y `git push`: el PR
se actualiza solo.

## 4. Espera al merge

Un admin revisa el plan y mergea. Entonces el pipeline crea la VM y la configura (cuentas, Docker,
el MVP…). Lo puedes seguir en la pestaña Actions → deploy. Un MVP de dataspace tarda 10-25 minutos
más.

## 5. Entra

```sh
make ssh NAME=<nombre>
```

Tu usuario en la VM es tu usuario de GitHub en minúsculas, y tienes `sudo`. `make ssh` baja las claves
de host que publica el pipeline y las usa en modo estricto: si alguna vez ves «HOST IDENTIFICATION
HAS CHANGED» con `make ssh`, **no entres** y avisa al admin.

Para un MVP de dataspace: `make tunnel NAME=<nombre>` ([dataspace.md](dataspace.md#acceder)).

## 6. Cuando termines

```sh
git switch main && git pull upstream main
make remove NAME=<nombre>
git switch -c quita-<nombre> && git commit -am "Quita <nombre>" && git push -u origin quita-<nombre>
gh pr create --repo <ORG>/homelab-iac --fill
```

En el plan del PR tienen que salir **solo** tus VMs como destruidas.

## Problemas habituales

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `make doctor`: «no sé quién eres» | Sin `gh` autenticado | `gh auth login`, o `export GITHUB_USER=<tu-usuario>` |
| `make doctor`: «proyectos: ninguno» | No estás en `members` de ningún proyecto | Pídeselo al admin |
| `iac check`: «fuera de los rangos de …» | `vmid`/`ip` cambiados a mano, o de otro proyecto | Vuelve a generar la petición con `make new-vm` |
| El PR no tiene comentario de plan | Tu PR toca algo más que `requests/` | Sepáralo: un PR solo con la petición |
| `Permission denied (publickey)` al entrar | Tu clave no está en tu perfil de GitHub, o el deploy aún no ha terminado | Añádela en GitHub; se aplica en el siguiente deploy |
| `make ssh` pregunta por la huella | La VM aún no tiene clave publicada | Espera a que termine el deploy, o compárala con `make known-hosts` |

Más contexto: [peticiones.md](peticiones.md) (todos los campos) y [diseno.md](diseno.md) (cómo
funciona). Normas de colaboración: [CONTRIBUTING.md](../CONTRIBUTING.md).
