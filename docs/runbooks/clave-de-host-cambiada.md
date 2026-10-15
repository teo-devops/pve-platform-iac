# Runbook: clave de host cambiada

**Síntoma:** el job `known-hosts` de deploy falla con «La clave de host de `<vm>` (`<ip>`) NO coincide
con la publicada y su VM no se ha creado en este deploy», o `make ssh` avisa de «REMOTE HOST
IDENTIFICATION HAS CHANGED».
**Quién:** un admin.
**Resultado esperado:** o se demuestra que es legítimo y se acepta la clave nueva, o se trata como un
incidente.

> [!CAUTION]
> Hasta saber qué pasa, **no entres en esa VM** ni aceptes la clave: si es una suplantación, es
> justo lo que busca el atacante.

## 1. Mirar la clave real en la VM, por un canal que no sea SSH

Consola de Proxmox (noVNC o xterm.js de la VM), con la cuenta `ops` o como root:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compárala con la que ha leído el pipeline (salida del job `known-hosts`) y con la publicada antes
(`make known-hosts`, columna de la VM).

## 2. Decidir

| La consola dice… | Significa | Qué hacer |
|---|---|---|
| La **misma** clave que la publicada | Quien responde en esa IP **no es la VM**: suplantación o conflicto de IP | Incidente: busca quién tiene esa IP (`ip neigh`, la tabla ARP del router o DHCP). No sigas con el deploy |
| La **nueva** (la que leyó el pipeline) | La VM regeneró sus claves: recreada fuera del pipeline, restaurada de un backup o con cloud-init relanzado | Averigua quién y por qué ([registro de break-glass](../operador.md#registro-de-break-glass)); después, acéptala (paso 3) |

## 3. Aceptar la clave nueva (solo si el paso 2 lo justifica)

Actions → deploy → Run workflow → `accept_host_keys`: el nombre de la VM (separa varias con comas).
El deploy publica la clave nueva y desde ahí vuelve a ser estricta.

## 4. Apuntarlo

Una línea en el registro de break-glass: qué VM, qué causa y quién lo ha aceptado.
