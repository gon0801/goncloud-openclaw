#!/usr/bin/env python3
"""Genera mensajes v14 de packing desde un backup `cron get --json` (Fase B1).

Uso: gen_v14.py --src <backup.json> --job 7h|11h|20h --out <archivo.v14.txt>
Aborta si un ancla no aparece exactamente 1 vez. Al final aserta: sin \\n,
todo ASCII 7-bit, `v14 single-line` presente, longitud >= 95% del original
(anti-truncado) y cada texto nuevo presente exactamente 1 vez.
NO aplica el edit; el lead corre `cron edit <uuid> --message "$(cat ...)"`
fuera de las ventanas cerradas (ver brief 1.6).
"""
import argparse
import json
import sys

JOBS = {
    "7h": "76b279ba-1a21-4d74-9a56-41da9514559e",
    "11h": "9e907473-a32e-46e6-b2bf-180aadf3f14c",
    "20h": "eeae2a74-6389-4e83-a80a-d0ae6cdc7988",
}
GUARD = ("GUARD: si D != fecha CDMX de hoy, el par de anoche no existe "
         "(fallo del 20h): ALERTA a David via tool message y ABORTAR, "
         "nunca continuar con baseline vieja.")

COMMON = [
    ("v13 single-line", "v14 single-line"),
    ("CENSUS V2 v4b con gate bash", "CENSUS V2 v4c con gate bash"),
    ("el run ABORTA con ALERTA inmediata a David y Claw por Telegram, NUNCA declara silencio;",
     "el run ABORTA con ALERTA inmediata a David via tool message "
     "(cuenta operaciones, al owner telegram:6470689715; NO depende de exec ni ssh) "
     "y a Claw via sessions_send agent:main:main, NUNCA declara silencio;"),
    ("verificar en Enviados que se cerro el compose",
     "antes de enviar confirmar que existe chip del destinatario (click en div[role=option]; "
     "Enter solo puede dejar el destinatario sin chip y el send falla en silencio); "
     "verificar entrega: en #drafts NO queda borrador con el asunto y en #sent el asunto "
     "aparece en una fila tr[role=row] (NUNCA usar body.innerText ni el cierre del compose como prueba)"),
    ("Telegram digest a Gon (TELEGRAM_CHAT_ID) e Isabel (TELEGRAM_CHAT_ID_2) via source "
     "/home/claw/.secrets/telegram-sales.env y curl sendMessage parse_mode=HTML por ssh en gonserver, "
     "nunca imprimir token ni chat ids; NUNCA a Wide en el digest;",
     "Telegram digest SOLO via helper /home/claw/send_sales_digest.sh "
     "<archivo_utf8 subido por scp a /tmp> (manda a Gon e Isabel, exige ok:true en ambos, "
     "exit 1 si falla; NUNCA curl a mano, nunca imprimir token ni chat ids; NUNCA a Wide en el digest);"),
]
EXTRA_7H_11H = [
    ("--set con resumen. Nunca inventar datos;",
     "--set con resumen + reportar a Claw (agente main) via sessions_send agent:main:main "
     "el resumen de lo enviado (a quien, que incluyo, personalizadas con sus msg ids) "
     "o el silencio verificado (sentinels). Nunca inventar datos;"),
]
EXTRA_7H = [
    ("(dedup: no reenviar lo ya reportado hoy).",
     "(dedup: no reenviar lo ya reportado hoy). " + GUARD),
]
EXTRA_11H = [
    ("(incluye extras de las 07:00 y cualquier corrida previa del dia: no reenviar nada ya reportado).",
     "(incluye extras de las 07:00 y cualquier corrida previa del dia: no reenviar nada ya reportado). " + GUARD),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--job", required=True, choices=JOBS)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    d = json.load(open(args.src))
    j = d.get("job", d)
    if j.get("id") != JOBS[args.job]:
        sys.exit(f"src no es el job {args.job}: id={j.get('id')}")
    m = (j.get("payload") or {}).get("message", "")
    orig_len = len(m)
    repls = list(COMMON)
    if args.job in ("7h", "11h"):
        repls += EXTRA_7H_11H
    if args.job == "7h":
        repls += EXTRA_7H
    if args.job == "11h":
        repls += EXTRA_11H
    for old, new in repls:
        n = m.count(old)
        if n != 1:
            sys.exit(f"ancla {old[:60]!r} aparece {n} veces (esperado 1); ABORTO")
        m = m.replace(old, new)
    emdash = m.count("—")
    m = m.replace("—", "-")
    assert "\n" not in m, "message con salto de linea"
    bad = sorted({c for c in m if ord(c) > 127})
    assert not bad, f"chars no-ASCII: {bad}"
    assert "v14 single-line" in m, "falta marker v14"
    assert len(m) >= 0.95 * orig_len, f"posible truncado: {len(m)} < 95% de {orig_len}"
    for _, new in repls:
        assert m.count(new) == 1, f"texto nuevo no-1x: {new[:60]!r}"
    assert m.count("—") == 0
    open(args.out, "w").write(m)
    print(f"{args.job}: orig={orig_len} nuevo={len(m)} delta=+{len(m)-orig_len} "
          f"emdash={emdash} anclas={len(repls)} OK -> {args.out}")


if __name__ == "__main__":
    main()
