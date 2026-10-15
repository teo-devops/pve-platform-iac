#!/usr/bin/env python3
"""Foto del despliegue de un MVP de dataspace en kind, en JSON, para que Ansible la vigile.

Lo llama el rol dataspace_mvp cada `mvp_poll` segundos mientras corre
kind-up.sh. No decide nada: dice en que fase va el script
(ultima linea util de su log), como estan los pods y que senales de "esto no se
va a arreglar solo" hay. Las reglas (cuanto esperar, cuando fallar) estan en el rol.

  python3 estado_mvp.py --log <mvp>/despliegue.log --context kind-<cluster> [--diagnostico]
"""
import argparse
import json
import re
import subprocess

# Estados de espera de un contenedor que Kubernetes no va a resolver por su cuenta.
# INSTANTANEOS: fallar ya. Por ejemplo ErrImageNeverPull: la imagen no esta en el
# nodo y la politica prohibe bajarla; esperar no cambia nada.
INSTANTANEOS = {"ErrImageNeverPull", "InvalidImageName"}
# PERSISTENTES: pueden ser pasajeros (una descarga lenta, un secret que crea otro
# job un poco despues); son fatales si siguen ahi varias comprobaciones seguidas.
PERSISTENTES = {"ImagePullBackOff", "ErrImagePull", "CrashLoopBackOff",
                "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
                "Unschedulable"}
# Lineas del log del despliegue que indican un fallo aunque el script siga
# (kind-up.sh no se para si falla `kind load`, p. ej.).
LOG_FATAL = re.compile(r"^(ERROR: |❌)")


# Contexto de kubectl del cluster del MVP (--context). Nunca el activo: en la VM
# puede haber otro cluster kind.
CONTEXT = []


def kubectl(*args, timeout=20):
    try:
        r = subprocess.run(["kubectl", *CONTEXT, *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def fase_y_errores(log):
    try:
        with open(log, errors="replace") as f:
            lines = [l.rstrip() for l in f if l.strip()]
    except OSError:
        return "(aun sin log)", [], []
    ultima = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", lines[-1])[:160] if lines else "(log vacio)"
    return ultima, [l[:220] for l in lines if LOG_FATAL.match(l)], lines[-30:]


def pods():
    out = kubectl("get", "pods", "-A", "-o", "json")
    if out is None:
        return None
    res = []
    for p in json.loads(out).get("items", []):
        st, meta = p.get("status", {}), p["metadata"]
        name = f"{meta['namespace']}/{meta['name']}"
        if st.get("phase") == "Succeeded":
            res.append({"pod": name, "listo": True})
            continue
        statuses = st.get("initContainerStatuses", []) + st.get("containerStatuses", [])
        listo = st.get("phase") == "Running" and all(c.get("ready") for c in st.get("containerStatuses", []))
        motivo, mensaje, reinicios = None, "", max([c.get("restartCount", 0) for c in statuses] or [0])
        for c in statuses:
            w = (c.get("state") or {}).get("waiting") or {}
            if w.get("reason") in INSTANTANEOS | PERSISTENTES:
                motivo, mensaje = w["reason"], f"{c['name']}: {w.get('message', '')}"
                break
        for cond in st.get("conditions", []):
            if cond.get("type") == "PodScheduled" and cond.get("reason") == "Unschedulable":
                motivo, mensaje = "Unschedulable", cond.get("message", "")
        res.append({"pod": name, "listo": listo, "motivo": motivo, "instantaneo": motivo in INSTANTANEOS,
                    "mensaje": mensaje[:240], "reinicios": reinicios})
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--context", help="contexto de kubectl del cluster del MVP (kind-<cluster>)")
    ap.add_argument("--diagnostico", action="store_true", help="ademas, eventos y cola del log")
    a = ap.parse_args()
    if a.context:
        CONTEXT[:] = ["--context", a.context]
    fase, errores_log, cola = fase_y_errores(a.log)
    ps = pods()
    out = {"fase": fase, "errores_log": errores_log, "cluster": ps is not None}
    if ps is not None:
        out.update({
            "total": len(ps),
            "listos": sum(p["listo"] for p in ps),
            "rotos": [p for p in ps if p.get("motivo")],
            "todo_listo": bool(ps) and all(p["listo"] for p in ps),
        })
    if a.diagnostico:
        out["no_listos"] = [f"{p['pod']}  {p.get('motivo') or 'no listo'}  {p.get('mensaje', '')}".strip()
                            for p in (ps or []) if not p["listo"]][:40]
        ev = kubectl("get", "events", "-A", "--field-selector", "type=Warning",
                     "--sort-by=.lastTimestamp", "-o",
                     "custom-columns=NS:.metadata.namespace,OBJ:.involvedObject.name,"
                     "MOTIVO:.reason,MENSAJE:.message", "--no-headers") or ""
        out["eventos"] = [l[:240] for l in ev.splitlines()[-25:]]
        out["cola_log"] = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", l)[:220] for l in cola]
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
