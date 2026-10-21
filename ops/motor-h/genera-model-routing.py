#!/usr/bin/env python3
"""Genera docs/model-routing.md desde la conf compartida del motor (goncloud-motor-conf).

La conf se localiza así, en orden: $MOTOR_CONF, la clave `conf` de
~/.motor-arranque/maquina.toml, ~/.motor-arranque/conf. La salida es
determinista: mismo contenido de la conf, mismo Markdown.
"""
import os
import sys
import tomllib

MODES_NOTE = (
    "Si no hay nadie del carril `revisar`, revisa cualquier modelo que no "
    "trabajó el bloque."
)


def conf_dir():
    if os.environ.get("MOTOR_CONF"):
        return os.environ["MOTOR_CONF"]
    maquina = os.path.expanduser("~/.motor-arranque/maquina.toml")
    if os.path.exists(maquina):
        with open(maquina, "rb") as f:
            d = tomllib.load(f)
        if d.get("conf"):
            return d["conf"]
    return os.path.expanduser("~/.motor-arranque/conf")


def carga(conf, nombre):
    with open(os.path.join(conf, nombre), "rb") as f:
        return tomllib.load(f)


def main():
    conf = conf_dir()
    carriles = carga(conf, "modelos.toml")["carriles"]
    papeles = carga(conf, "papeles.toml")["papeles"]
    rutas = carga(conf, "rutas.toml")["rutas"]

    en_carril = {m for lista in carriles.values() for m in lista}

    out = []
    out.append("# Enrutado de modelos de OpenClaw")
    out.append("")
    out.append(
        "Generado desde goncloud-motor-conf (`modelos.toml`, `papeles.toml`,"
    )
    out.append(
        "`rutas.toml`) con `ops/motor-h/genera-model-routing.py`. No se edita a"
    )
    out.append(
        "mano: `bash ops/motor-h/comprueba-tabla.sh` exige que este archivo"
    )
    out.append("coincida con la conf.")
    out.append("")
    out.append("## Carriles (en orden de relevo)")
    out.append("")
    out.append("| Carril | Modelos |")
    out.append("| --- | --- |")
    for carril, modelos in carriles.items():
        out.append(f"| {carril} | {', '.join(modelos)} |")
    out.append("")
    out.append(MODES_NOTE)
    out.append("")
    out.append("## Papeles")
    out.append("")
    out.append("| Papel | Carril |")
    out.append("| --- | --- |")
    for papel, carril in papeles.items():
        out.append(f"| {papel} | {carril} |")
    out.append("")

    def tabla(titulo, modelos):
        out.append(f"## {titulo}")
        out.append("")
        out.append("| Modelo | Cuenta | CLI | Lanzamiento sin ventana |")
        out.append("| --- | --- | --- | --- |")
        for modelo in modelos:
            r = rutas[modelo]
            argv = " ".join(r["argv"])
            out.append(f"| {modelo} | {r['cuenta']} | {r['cli']} | `{argv}` |")
            if r.get("env"):
                claves = ", ".join(sorted(r["env"]))
                out.append(f"| {modelo} (env) | | | `{claves}` |")
        out.append("")

    tabla("Rutas de los carriles", [m for m in rutas if m in en_carril])
    tabla(
        "Rutas fuera de los carriles (solo entran si un plan las pide)",
        [m for m in rutas if m not in en_carril],
    )
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
