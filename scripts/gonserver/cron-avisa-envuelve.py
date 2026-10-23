#!/usr/bin/env python3
"""Envuelve las líneas activas de un crontab con /usr/local/bin/cron-avisa.

    cron-avisa-envuelve.py --destino usuario:root|usuario:gon|cron.d:<archivo> [--cuenta] < crontab > nuevo

`envuelve(texto, destino)` es una función pura: recibe el texto de un crontab (de usuario o de
/etc/cron.d, con su campo de usuario) y devuelve el texto nuevo. Los archivos de /etc/cron.d con un
punto en el nombre se devuelven igual, porque cron no los lee. `--cuenta` escribe en stderr
`envueltas=N quitadas=M`.
"""

from __future__ import annotations

import argparse
import re
import sys

AVISA = "/usr/local/bin/cron-avisa"

# fragmento del comando -> motivo por el que no se envuelve
NO_ENVOLVER = (
    ("sync_meli_orders.py", "ya avisa sola"),
    ("sync_amazon.py", "ya avisa sola"),
    ("sync_meli_ads.py", "ya avisa sola"),
    ("sync_amazon_finance_v2024.py", "ya avisa sola"),
    ("spapi-diario.sh", "ya avisa solo"),
    ("ingest diario", "ya avisa solo, con tres intentos al día"),
    ("actualiza-nextcloud", "ya avisa solo"),
    ("e2scrub", "mantenimiento del sistema"),
    ("debian-sa1", "mantenimiento del sistema (sysstat)"),
    ("/usr/lib/php/sessionclean", "mantenimiento del sistema (sesiones de php)"),
    (".meli_tokens.json", "chmod de un archivo, no hay nada que avisar"),
    ("docker_stats_log.sh", "solo escribe un log cada 5 minutos"),
)

# fragmento del comando -> frase llana que ve quien recibe el aviso
NOMBRES = (
    ("backfill_meli_mappings", "Reparación de equivalencias de MercadoLibre"),
    ("orbit/backup.sh", "Respaldo de Orbit"),
    ("refresh_estimacion.sh", "Actualización de estimaciones de Orbit"),
    ("orbit_meli_pase_copy.sh", "Copia del pase de MercadoLibre"),
    ("spapi_vigilante", "Vigilante de las ingestas de Amazon"),
    ("sync_fx_rates.py", "Tipo de cambio del día"),
    ("sync_cogs_odoo.py", "Costos de Odoo"),
    ("fetch_amazon_balance.py", "Saldo de Amazon"),
    ("sync_amazon_ads.py", "Publicidad de Amazon"),
    ("audit_postage.py", "Auditoría de envíos"),
    ("audit_resolve_orders.py", "Auditoría de órdenes"),
    ("sync_ads_to_ledger.py", "Publicidad al libro contable"),
    ("run_diagnostics.py", "Diagnóstico semanal de EHV"),
    ("competitor_tracker.py", "Seguimiento de competidores de EHV"),
    ("sync_mp_release_report.py", "Reporte de liberaciones de Mercado Pago"),
    ("sync_product_images.py", "Imágenes de productos"),
    ("sync_bom_odoo.py", "Listas de materiales de Odoo"),
    ("sync_amazon_shipping_labels.py", "Etiquetas de envío de Amazon"),
    ("heartbeat.py", "Latido de contabilidad"),
    ("refresh_costos.sh", "Costos de Orbit"),
    ("reputacion snapshot --fuente meli", "Reputación de MercadoLibre"),
    ("reputacion alertas", "Alertas de reputación"),
    ("precio --platform amazon_mx", "Corrida de precios de Amazon"),
    ("precio --platform meli", "Corrida de precios de MercadoLibre"),
    ("envio_muestras --platform amazon_mx", "Muestras de envío de Amazon México"),
    ("envio_muestras --platform amazon_us", "Muestras de envío de Amazon Estados Unidos"),
    ("envio_muestras --platform meli", "Muestras de envío de MercadoLibre"),
    ("app.meli.catalogo", "Catálogo de MercadoLibre"),
    ("bloqueo-reconcilia", "Reconciliación de bloqueos"),
    ("ingest structure", "Estructura de campañas"),
    ("avisos-campana", "Avisos de campañas"),
    ("impulso-vigia", "Vigía de impulso"),
    ("cycle --platform amazon_us", "Optimizador de publicidad de Amazon Estados Unidos"),
    ("cycle --platform amazon_mx", "Optimizador de publicidad de Amazon México"),
    ("jev-senales", "Señales de publicidad de JEV"),
    ("ads-salud", "Salud de la publicidad"),
    ("bridge_backup_offsite.sh", "Copia de Bridge a OneDrive"),
    ("bridge_backup.sh", "Respaldo de Bridge"),
    ("cleanup_old_records.py", "Limpieza semanal de Bridge"),
    ("bridge_wal_checkpoint.sh", "Mantenimiento de la base de Bridge"),
    ("bridge_restore_test.sh", "Prueba mensual de restauración de Bridge"),
    ("odoo_sos_en_cero.py", "Ventas de Odoo en cero"),
    ("meli_refresh_tokens.sh", "Renovación del acceso a MercadoLibre"),
    ("nextcloud_backup.sh", "Respaldo de Nextcloud"),
    ("odoo_backup.sh", "Respaldo de Odoo"),
    ("vaultwarden_backup.sh", "Respaldo de Vaultwarden"),
    ("ts-watchdog.sh", "Vigía de Tailscale"),
    ("vigila-respaldos", "Vigía de respaldos"),
)

DUPLICADAS: tuple[tuple[str, str, str, str], ...] = ()

TRAS = 3
CADAS = (1, 6, 24, 168)
CADA_MAXIMA = 720

RE_NUCLEO = re.compile(r"\s*(\S+)")
RE_ESPACIO = re.compile(r"\s+")
RE_REDIR = re.compile(r"(?:\s+(?:[0-9]*>>?\s*[^\s&;|]+|[0-9]*>&[0-9]+|&>>?\s*[^\s&;|]+))+\s*$")


class SinFrase(ValueError):
    pass


def _campo(texto: str, minimo: int, maximo: int) -> set[int]:
    valores: set[int] = set()
    for parte in texto.split(","):
        rango, barra, paso = parte.partition("/")
        salto = int(paso) if barra else 1
        if rango == "*":
            desde, hasta = minimo, maximo
        elif "-" in rango:
            desde, hasta = (int(x) for x in rango.split("-"))
        else:
            desde = int(rango)
            hasta = maximo if barra else desde
        if salto < 1 or desde < minimo or hasta > maximo or desde > hasta:
            raise ValueError(f"campo de horario fuera de rango: {texto}")
        valores.update(range(desde, hasta + 1, salto))
    return valores


def _huecos(minuto: str, hora: str, dia: str, mes: str, semana: str) -> tuple[float, float]:
    """Minutos entre corridas: (el hueco más largo, el más corto)."""
    if dia != "*" or mes != "*":
        dias = len(_campo(dia, 1, 31)) if dia != "*" else 31
        meses = len(_campo(mes, 1, 12)) if mes != "*" else 12
        largo = 31 * 12 / (dias * meses) * 1440
        return largo, largo
    del_dia = sorted(h * 60 + m for h in _campo(hora, 0, 23) for m in _campo(minuto, 0, 59))
    if semana == "*":
        ciclo, instantes = 1440, del_dia
    else:
        dias_semana = sorted({d % 7 for d in _campo(semana.replace("7", "0"), 0, 6)})
        ciclo = 7 * 1440
        instantes = [d * 1440 + t for d in dias_semana for t in del_dia]
    saltos = [b - a for a, b in zip(instantes, instantes[1:])] + [instantes[0] + ciclo - instantes[-1]]
    return max(saltos), min(saltos)


def _cada(largo_minutos: float) -> int:
    horas = largo_minutos / 60
    return next((c for c in CADAS if horas <= c), CADA_MAXIMA)


def _atajo(token: str) -> list[str] | None:
    return {
        "@hourly": ["0", "*", "*", "*", "*"],
        "@daily": ["0", "0", "*", "*", "*"],
        "@midnight": ["0", "0", "*", "*", "*"],
        "@weekly": ["0", "0", "*", "*", "0"],
        "@monthly": ["0", "0", "1", "*", "*"],
    }.get(token)


def _partir(linea: str, cron_d: bool) -> tuple[str, list[str], str] | None:
    """(prefijo hasta el comando, campos de horario, comando) o None si no es una tarea."""
    if not linea.strip() or linea.lstrip().startswith("#"):
        return None
    primero = RE_NUCLEO.match(linea)
    if not primero or not re.match(r"[0-9*@]", primero.group(1)):
        return None
    if primero.group(1).startswith("@"):
        campos, n = _atajo(primero.group(1)), 1
        if campos is None:
            return None
    else:
        campos, n = [], 5
    pos = 0
    tokens = []
    for _ in range(n + (1 if cron_d else 0)):
        m = RE_NUCLEO.match(linea, pos)
        if not m:
            return None
        tokens.append(m.group(1))
        pos = m.end()
    if not campos:
        campos = tokens[:5]
    espacio = RE_ESPACIO.match(linea, pos)
    if not espacio or espacio.end() >= len(linea.rstrip()):
        return None
    return linea[: espacio.end()], campos, linea[espacio.end() :].rstrip()


def _porcentaje(comando: str) -> tuple[str, str]:
    m = re.search(r"(?<!\\)%", comando)
    return (comando[: m.start()].rstrip(), comando[m.start() :]) if m else (comando, "")


def _redireccion(comando: str) -> tuple[str, str]:
    m = RE_REDIR.search(comando)
    if not m or ">" in comando[: m.start()]:
        return comando, ""
    return comando[: m.start()], m.group(0).strip()


def _frase(comando: str) -> str:
    for fragmento, frase in NOMBRES:
        if fragmento in comando:
            return frase
    raise SinFrase(f"sin frase en NOMBRES para: {comando}")


def _envuelve_linea(linea: str, cron_d: bool) -> str:
    partes = _partir(linea, cron_d)
    if partes is None:
        return linea
    prefijo, campos, comando = partes
    if comando.startswith(AVISA):
        return linea
    cuerpo, entrada = _porcentaje(comando)
    if any(fragmento in cuerpo for fragmento, _ in NO_ENVOLVER):
        return linea
    frase = _frase(cuerpo)
    largo, corto = _huecos(*campos)
    cuerpo, redireccion = _redireccion(cuerpo)
    cuerpo = re.sub(r"\bflock -n\b(?! -E)", "flock -n -E 75", cuerpo)
    citado = "'" + cuerpo.replace("'", "'\\''") + "'"
    tras = f" --tras {TRAS}" if corto <= 30 else ""
    salida = f'{prefijo}{AVISA} --nombre "{frase}" --cada {_cada(largo)}{tras} -- /bin/bash -c {citado}'
    return " ".join(p for p in (salida, redireccion, entrada) if p)


def _es_duplicada(linea: str, destino: str) -> str | None:
    cron_d = destino.startswith("cron.d:")
    partes = _partir(linea, cron_d)
    if partes is None:
        return None
    return next((c for d, f, c, _ in DUPLICADAS if d == destino and f in partes[2]), None)


def transforma(texto: str, destino: str) -> tuple[str, int, int]:
    """(texto nuevo, líneas envueltas, líneas quitadas por duplicadas)."""
    if destino.startswith("cron.d:") and "." in destino[len("cron.d:") :]:
        return texto, 0, 0
    cron_d = destino.startswith("cron.d:")
    salida: list[str] = []
    envueltas = quitadas = 0
    for cruda in texto.splitlines(keepends=True):
        fin = cruda[len(cruda.rstrip("\r\n")) :]
        linea = cruda[: len(cruda) - len(fin)]
        comentario = _es_duplicada(linea, destino)
        if comentario is not None:
            quitadas += 1
            if salida and salida[-1].lstrip().startswith("#") and comentario in salida[-1]:
                salida.pop()
            continue
        nueva = _envuelve_linea(linea, cron_d)
        envueltas += nueva != linea
        salida.append(nueva + fin)
    return "".join(salida), envueltas, quitadas


def envuelve(texto: str, destino: str) -> str:
    return transforma(texto, destino)[0]


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="cron-avisa-envuelve")
    p.add_argument("--destino", required=True)
    p.add_argument("--cuenta", action="store_true")
    a = p.parse_args(argv)
    if not re.fullmatch(r"usuario:[a-z_][a-z0-9_-]*|cron\.d:[^/\s]+", a.destino):
        p.error("--destino es usuario:<nombre> o cron.d:<archivo>")
    nuevo, envueltas, quitadas = transforma(sys.stdin.read(), a.destino)
    sys.stdout.write(nuevo)
    if a.cuenta:
        print(f"envueltas={envueltas} quitadas={quitadas}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
