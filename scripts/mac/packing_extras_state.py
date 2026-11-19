#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

SOURCES = ("seller_central", "seller_flex", "mercado_libre")
DELIVERIES = ("correo", "telegram_gon", "telegram_isabel", "personalizadas")
ARTIFACTS = ("amazon", "meli")
DELIVERY_STATES = {"pendiente", "en_curso", "verificado", "fallido", "indeterminado", "no_prevista"}


def emit(payload, code=0):
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return code


def validate_content(content, label):
    if not isinstance(content, dict):
        raise ValueError(f"{label} debe ser un objeto")
    for order_id, fingerprint in content.items():
        if not isinstance(order_id, str) or not order_id.strip():
            raise ValueError(f"{label} contiene un pedido inválido")
        if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
            raise ValueError(f"{label}.{order_id} tiene una huella inválida")


def load_state(path):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"estado ilegible: {exc}") from exc
    if not isinstance(state, dict) or state.get("schema_version") != 2:
        raise ValueError("schema_version debe ser 2")
    if not isinstance(state.get("fuentes"), dict):
        raise ValueError("fuentes debe ser un objeto")
    for source in SOURCES:
        if not isinstance(state["fuentes"].get(source), str):
            raise ValueError(f"falta fuentes.{source}")
    if not isinstance(state.get("deduplicacion"), str):
        raise ValueError("deduplicacion debe ser texto")
    batch = state.get("lote")
    if batch is not None:
        if not isinstance(batch, dict):
            raise ValueError("lote debe ser null u objeto")
        for order_id, record in batch.items():
            if not isinstance(record, dict):
                raise ValueError(f"lote.{order_id} debe ser un objeto")
            validate_content({order_id: record.get("huella")}, "lote")
            if record.get("fuente") not in ARTIFACTS:
                raise ValueError(f"lote.{order_id}.fuente inválida")
            if not isinstance(record.get("personalizada"), bool):
                raise ValueError(f"lote.{order_id}.personalizada debe ser booleano")
    deliveries = state.get("entregas")
    if not isinstance(deliveries, dict):
        raise ValueError("entregas debe ser un objeto")
    for name in DELIVERIES:
        if name not in deliveries:
            raise ValueError(f"falta entregas.{name}")
    for name, delivery in deliveries.items():
        if not isinstance(delivery, dict) or not isinstance(delivery.get("prevista"), bool):
            raise ValueError(f"entregas.{name}.prevista debe ser booleano")
        if delivery.get("estado") not in DELIVERY_STATES:
            raise ValueError(f"entregas.{name}.estado inválido")
        receipts = delivery.get("recibos")
        if not isinstance(receipts, list):
            raise ValueError(f"entregas.{name}.recibos debe ser una lista")
        for receipt in receipts:
            if not isinstance(receipt, dict) or not str(receipt.get("recibo", "")).strip():
                raise ValueError(f"entregas.{name} contiene un recibo inválido")
            validate_content(receipt.get("pedidos"), f"entregas.{name}.recibos.pedidos")
        validate_content(delivery.get("intento"), f"entregas.{name}.intento")
        if delivery["estado"] == "verificado" and not receipts:
            raise ValueError(f"entregas.{name} verificado exige recibos")
    artifacts = state.get("artefactos")
    if not isinstance(artifacts, dict):
        raise ValueError("artefactos debe ser un objeto")
    for name in ARTIFACTS:
        if artifacts.get(name) not in {"pendiente", "escrito"}:
            raise ValueError(f"artefactos.{name} debe ser pendiente o escrito")
    return state


def source_failures(state):
    failures = [f"fuentes.{source}" for source in SOURCES if state["fuentes"][source] != "completa"]
    if state["deduplicacion"] != "completa":
        failures.append("deduplicacion")
    if state["lote"] is None:
        failures.append("lote")
    return failures


def expected_content(state, name):
    content = {}
    for order_id, record in (state["lote"] or {}).items():
        if name == "correo" and record["fuente"] != "amazon":
            continue
        if name == "personalizadas" and not record["personalizada"]:
            continue
        content[order_id] = record["huella"]
    return content


def delivered_content(delivery):
    content = {}
    for receipt in delivery["recibos"]:
        content.update(receipt["pedidos"])
    return content


def missing_content(state, name):
    expected = expected_content(state, name)
    delivered = delivered_content(state["entregas"][name])
    return {order_id: fingerprint for order_id, fingerprint in expected.items() if delivered.get(order_id) != fingerprint}


def pending_orders(state):
    pending = {}
    for name in state["entregas"]:
        missing = missing_content(state, name)
        if missing:
            pending[name] = sorted(missing)
    return pending


def plan(state):
    failures = source_failures(state)
    skipped = []
    pending_ids = pending_orders(state) if state["lote"] is not None else {}
    for name, delivery in state["entregas"].items():
        if delivery["estado"] in {"en_curso", "indeterminado"}:
            failures.append(f"entregas.{name}:reconciliar")
    if failures:
        return emit({"estado": "FALLO_EXPLICITO", "corte_completo": False, "faltantes": failures}, 1)
    for index, name in enumerate(("telegram_gon", "telegram_isabel"), start=1):
        delivery = state["entregas"][name]
        if delivery["prevista"] and delivery["estado"] == "verificado" and name not in pending_ids:
            skipped.append(index)
    telegram_pending = [
        index
        for index, name in enumerate(("telegram_gon", "telegram_isabel"), start=1)
        if name in pending_ids
    ]
    return emit(
        {
            "estado": "REINTENTO_PERMITIDO",
            "corte_completo": False,
            "entregas_pendientes": sorted(pending_ids),
            "pedidos_pendientes": pending_ids,
            "telegram_chats_pendientes": telegram_pending,
            "telegram_chats_omitidos": skipped,
        }
    )


def close(state):
    failures = source_failures(state)
    pending_ids = pending_orders(state) if state["lote"] is not None else {}
    for name, delivery in state["entregas"].items():
        if (delivery["prevista"] or name in pending_ids) and delivery["estado"] != "verificado":
            failures.append(f"entregas.{name}")
        if name in pending_ids:
            failures.append(f"entregas.{name}:pedidos")
    for name in ARTIFACTS:
        if state["artefactos"][name] != "escrito":
            failures.append(f"artefactos.{name}")
    if failures:
        payload = {"estado": "FALLO_EXPLICITO", "corte_completo": False, "faltantes": failures}
        if pending_ids:
            payload["pedidos_pendientes"] = pending_ids
        return emit(payload, 1)
    return emit({"estado": "CORTE_COMPLETO", "corte_completo": True, "faltantes": []})


def initial_state():
    return {
        "schema_version": 2,
        "fuentes": {source: "pendiente" for source in SOURCES},
        "deduplicacion": "pendiente",
        "lote": None,
        "entregas": {
            name: {"prevista": False, "estado": "no_prevista", "recibos": [], "intento": {}}
            for name in DELIVERIES
        },
        "artefactos": {name: "pendiente" for name in ARTIFACTS},
    }


def save_state(path, state):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary = Path(handle.name)
            json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def read_batch(amazon_path, meli_path):
    batch = {}
    for source, path in (("amazon", amazon_path), ("meli", meli_path)):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ValueError(f"borrador {source} ilegible: {exc}") from exc
        for block in re.split(r"\n\s*\n", text):
            if "<b>Pedido:</b>" not in block:
                continue
            matches = re.findall(r"<b>Pedido:</b>\s*([0-9]+(?:-[0-9]+)*)", block)
            if len(matches) != 1:
                raise ValueError(f"bloque de pedido inválido en {path}: {block[:120]!r}")
            order_id = matches[0]
            if order_id in batch:
                raise ValueError(f"pedido duplicado en el lote: {order_id}")
            normalized = block.strip()
            batch[order_id] = {
                "huella": hashlib.sha256(normalized.encode("utf-8")).hexdigest(),
                "fuente": source,
                "personalizada": source == "amazon" and "<b>PERSONALIZADA</b>" in normalized,
            }
    return batch


def register_batch(path, amazon_path, meli_path):
    state = load_state(path)
    batch = read_batch(amazon_path, meli_path)
    if state["lote"] != batch:
        state["artefactos"] = dict.fromkeys(ARTIFACTS, "pendiente")
    state["lote"] = batch
    save_state(path, state)
    return emit({"estado": "LOTE_REGISTRADO", "corte_completo": False, "pedidos": sorted(state["lote"])})


def mark(path, kind, name, status, receipt):
    state = load_state(path)
    if kind == "entrega":
        if name not in state["entregas"]:
            raise ValueError(f"entrega desconocida: {name}")
        if status not in DELIVERY_STATES:
            raise ValueError(f"estado de entrega inválido: {status}")
        delivery = state["entregas"][name]
        if status == "en_curso":
            if delivery["estado"] in {"en_curso", "indeterminado"}:
                raise ValueError(f"entrega {name} exige reconciliación antes de otro intento")
            attempt = missing_content(state, name)
            if name == "personalizadas":
                if not receipt or not receipt.strip():
                    raise ValueError("entrega personalizadas en_curso exige un pedido")
                if receipt not in attempt:
                    raise ValueError(f"pedido personalizado no pendiente en el lote: {receipt}")
                attempt = {receipt: attempt[receipt]}
            if not attempt:
                raise ValueError(f"entrega {name} no tiene pedidos pendientes en el lote")
            delivery["intento"] = attempt
        elif status == "verificado":
            if not receipt or not receipt.strip():
                raise ValueError("una entrega verificada exige recibo")
            if not delivery["intento"]:
                raise ValueError("marca en_curso para vincular el recibo con los pedidos enviados")
            if name == "personalizadas" and len(delivery["intento"]) != 1:
                raise ValueError("una entrega personalizada verificada exige un intento de un solo pedido")
            delivery["recibos"].append({"recibo": receipt, "pedidos": delivery["intento"]})
            delivery["intento"] = {}
        elif status in {"pendiente", "no_prevista"}:
            if delivery["estado"] in {"en_curso", "indeterminado"}:
                raise ValueError(f"entrega {name} exige reconciliación antes de cambiar su estado")
            delivery["intento"] = {}
        delivery["prevista"] = status != "no_prevista"
        delivery["estado"] = status
    elif kind == "fuente":
        if name not in SOURCES or status not in {"pendiente", "completa", "error"}:
            raise ValueError(f"fuente o estado inválido: {name} {status}")
        state["fuentes"][name] = status
    elif kind == "deduplicacion":
        if status not in {"pendiente", "completa", "error"}:
            raise ValueError(f"estado de deduplicación inválido: {status}")
        state["deduplicacion"] = status
    else:
        if name not in ARTIFACTS or status not in {"pendiente", "escrito"}:
            raise ValueError(f"artefacto o estado inválido: {name} {status}")
        state["artefactos"][name] = status
    save_state(path, state)
    return emit({"estado": "REGISTRADO", "objetivo": f"{kind}.{name}", "corte_completo": False})


def parser():
    result = argparse.ArgumentParser(description="Estado y compuerta del corte packing-extras-11h")
    subparsers = result.add_subparsers(dest="command", required=True)
    for command in ("plan", "cerrar", "inicializar"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("estado", type=Path)
    batch = subparsers.add_parser("registrar-lote")
    batch.add_argument("estado", type=Path)
    batch.add_argument("amazon_html", type=Path)
    batch.add_argument("meli_html", type=Path)
    marker = subparsers.add_parser("marcar")
    marker.add_argument("estado", type=Path)
    marker.add_argument("tipo", choices=("entrega", "fuente", "deduplicacion", "artefacto"))
    marker.add_argument("nombre")
    marker.add_argument("valor")
    marker.add_argument("recibo", nargs="?")
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command == "plan":
            return plan(load_state(args.estado))
        if args.command == "cerrar":
            return close(load_state(args.estado))
        if args.command == "inicializar":
            if args.estado.exists():
                raise ValueError("el estado ya existe; usa plan antes de reintentar")
            save_state(args.estado, initial_state())
            return emit({"estado": "INICIALIZADO", "corte_completo": False})
        if args.command == "registrar-lote":
            return register_batch(args.estado, args.amazon_html, args.meli_html)
        return mark(args.estado, args.tipo, args.nombre, args.valor, args.recibo)
    except ValueError as exc:
        return emit({"estado": "ERROR", "corte_completo": False, "error": str(exc)}, 2)


if __name__ == "__main__":
    sys.exit(main())
