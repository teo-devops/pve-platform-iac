# Dataspaces en el homelab (perfil `dataspace-kind`)

**Para quién:** quien quiera un MVP de dataspace corriendo en una VM del homelab: miembros del
proyecto `dataspace` y el admin.

**Qué necesitas antes de empezar:** estar en un proyecto con rango libre (`make doctor`) y saber qué
MVP quieres: una carpeta de [`teo-devops/dataspace-mvp`](https://github.com/teo-devops/dataspace-mvp)
(hoy, `demo`) y un commit o tag de ese repo.

**Cómo sabrás que ha salido bien:** el job `configure` termina con «MVP demo desplegado en …», y
dentro de la VM `./scripts/pruebas/bruno.sh --todas` pasa todas las pruebas.

## Qué es un MVP aquí

Los MVP los genera [dsgen](https://github.com/teo-devops/dataspace-dsgen) a partir de una spec
(`mvp.yaml`): un dataspace completo con Eclipse EDC (participantes con conector, identidad y
credenciales DCP, las vías de datos, la plataforma del cluster, observabilidad y pruebas Bruno).
Cada carpeta de `dataspace-mvp` es un MVP que se levanta en kind con sus propios scripts:

```
<mvp>/scripts/ciclo-de-vida/kind-up.sh    cluster kind + plataforma + imágenes + manifiestos + seeds
<mvp>/scripts/pruebas/bruno.sh --todas    el flujo DSP por cada vía, y el control de acceso
<mvp>/scripts/ciclo-de-vida/kind-down.sh  lo destruye
```

Este repo **no reimplementa nada** de eso ([D-11](diseno.md#decisiones)): crea la VM, instala
Docker, kind, kubectl, helm y Bruno, clona `dataspace-mvp` en el ref fijado y ejecuta `kind-up.sh`
vigilando el progreso.

## Pedirlo

```sh
make new-vm PROFILE=dataspace-kind
```

El asistente pregunta el tamaño (`ds-mvp-kind`: 8 vCPU / 16 GB / 120 GB, para el MVP completo con
observabilidad; `ds-mvp-kind-lite` sin observabilidad), el repo (por defecto
`teo-devops/dataspace-mvp`), la carpeta (`demo`) y el ref. Si das una rama, la convierte en su SHA
actual. Resultado:

```yaml
project: dataspace
flavor: ds-mvp-kind
profile: dataspace-kind
vmid: 1100
ip: 192.168.50.100
mvp:
  repo: teo-devops/dataspace-mvp
  # SHA o tag, nunca una rama: lo desplegado es exactamente lo revisado en el PR.
  ref: c5e82fc...
  path: demo
```

Después: PR, revisión y merge, como cualquier petición ([inicio-rapido.md](inicio-rapido.md)).

## Qué pasa durante el despliegue

En el job `configure` de `deploy.yml`, el rol `ansible/roles/dataspace_mvp`:

1. Comprueba que la VM llega a GitHub y a los registries (ghcr.io, Docker Hub, quay.io y Elastic).
2. Instala la CLI de Bruno (versión fijada) y crea la cuenta de servicio `dataspace`, que despliega
   el MVP (no depende de qué personas haya en el proyecto).
3. Escribe la deploy key **temporal** y clona `dataspace-mvp` en `mvp.ref`, verificando la clave de
   host de github.com contra las publicadas por GitHub (fijadas en el rol). Después borra la clave.
4. Lee `KIND_CLUSTER` y `NAMESPACE` de `<path>/scripts/herramientas/mvp.env` (los decide la spec
   del MVP).
5. `docker login ghcr.io` con un directorio de configuración temporal y lanza `kind-up.sh` en
   segundo plano.
6. Cada 30 s escribe una línea de progreso (fase del script y pods listos). Para en cuanto hay una
   señal de que no se va a arreglar solo: un pod en `ErrImageNeverPull`, otro atascado 5 minutos en
   `ImagePullBackOff` o `CrashLoopBackOff`, o una línea `ERROR:` en el log. El límite total son
   45 minutos.
7. **Siempre**, falle o no, borra la deploy key y la configuración de docker con el token
   ([R-13](seguridad.md#controles)).
8. Deja a cada miembro del proyecto el kubeconfig del cluster kind (`kind export kubeconfig`).

`kind-up.sh` es idempotente: en un deploy en el que el MVP no cambia, reaplica sin borrar nada.

## Acceder

El MVP escucha en `127.0.0.2` **dentro** de la VM (lo fija la spec: `environments.kind.ip`); no se
expone a la red. Se entra por un túnel SSH:

```sh
make tunnel NAME=dataspace-demo
#   Entrada (Traefik):   http://localhost:8080/demo/<participante>/cp
#   Observabilidad:      http://localhost:8080/demo/kibana/   http://localhost:8080/demo/jaeger/
#   Descargas PULL:      http://localhost:8081/flows/<id>
```

`HTTP_PORT=…` y `ENVOY_PORT=…` cambian los puertos locales si están ocupados (p. ej. por un kind
local). Las rutas de cada MVP están en su `README.md`.

Las pruebas se lanzan **en la VM**:

```sh
make ssh NAME=dataspace-demo
cd /home/dataspace/dataspace-mvp/demo && ./scripts/pruebas/bruno.sh --todas
```

`kubectl` funciona directamente con tu cuenta (estás en el grupo `docker` y tienes el kubeconfig).

## Cambiar de versión o de MVP

- **Otra versión del MVP** (otro commit, o dsgen regenerado): PR que cambia `mvp.ref`. Como solo
  toca `requests/`, `pr-plan` lo comenta (sin cambios de infraestructura) y el deploy lo reaplica con
  `kind-up.sh`.
- **Otro MVP en la misma VM**: cambia `mvp.path`. El cluster kind del anterior se queda (cada MVP
  tiene su nombre de cluster). Para borrarlo, ver abajo.
- **Empezar de cero** (borra el cluster kind y sus datos): un admin lanza
  `make configure NAME=<vm> ARGS="-e mvp_recreate=true"` (break-glass) o lo hace a mano en la VM con
  `kind-down.sh`, y después relanza deploy.

## Si falla

El job `configure` vuelca el diagnóstico (pods que no están listos, últimos eventos de aviso y la
cola del log). Lo más habitual:

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| «La VM no alcanza ghcr.io…» | DNS o salida a Internet de la VM | Revisa `network.dns` y el gateway en `homelab.yaml` |
| `ImagePullBackOff` en `ghcr.io/teo-devops/*` | Token de ghcr caducado o sin `read:packages` | Rota `GHCR_READ_TOKEN` ([credenciales.md](credenciales.md#credenciales-del-mvp-de-dataspace)) |
| «Permission denied (publickey)» al clonar | La deploy key no está en `dataspace-mvp` o se ha rotado | `gh repo deploy-key list -R teo-devops/dataspace-mvp` |
| «… no tiene `<path>`/scripts/herramientas/mvp.env» | `mvp.path` no es una carpeta de MVP en ese ref | Corrige `path` o `ref` |
| `ErrImageNeverPull` | La precarga de imágenes en kind falló | Reintenta con `mvp_recreate=true` |
| Elasticsearch reiniciándose | Falta memoria | Flavor `ds-mvp-kind` (16 GB) |
| Se agota el tiempo | Descarga de imágenes lenta | Relanza deploy: lo ya bajado se reutiliza |

Log completo en la VM: `less /home/dataspace/dataspace-mvp/<path>/despliegue.log`.

## Más adelante

dsgen sabe generar un entorno `prod` (`environments.prod`: `overlays/prod` con MetalLB y
`storageClass`). El paso natural es un perfil de cluster `k3s-dataspace` que lo despliegue sobre un
cluster k3s del repo. No está en este repo todavía.
