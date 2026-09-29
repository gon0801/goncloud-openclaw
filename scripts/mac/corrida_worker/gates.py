"""Compuertas de calidad por SHA (Fase 14, Task 6).

Decide puro sobre datos ya releidos por el wrapper: el recibo validado por
el contrato del kit instalado (o, con el kit apagado por declaracion en la
tabla de preaprobaciones, el veredicto del revisor leido de GitHub), el PR
autoritativo y la evidencia aportada.
Cada veredicto trae una proyeccion de solo lectura (fuente, repo, PR, SHA
revisado, resultado, disponibilidad) que jamas sustituye al recibo del kit.
La indisponibilidad declarada de un bot se registra y no es aprobacion.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Mapping

ACTIONS = (
    "cross-review",
    "push-pr",
    "ci",
    "coderabbit",
    "merge",
    "deploy",
    "canary",
    "rollback",
)

KIT_RECEIPT = "saikit-entrega.v1"
REVIEWER_RECEIPT = "ci-y-revisor"
RECEIPT_MODES = (KIT_RECEIPT, REVIEWER_RECEIPT)

DEEPSEEK_LOGINS = frozenset({"github-actions[bot]", "github-actions"})
CODERABBIT_LOGINS = frozenset({"coderabbitai[bot]", "coderabbitai"})
BLOCKING_SEVERITIES = frozenset({"critical", "high"})
FINDINGS_MARK = "<!-- ai-review:findings="


@dataclass(frozen=True)
class GateDecision:
    verdict: str
    code: str
    reason: str
    projection: Mapping[str, Any] = field(default_factory=dict)
    updates: Mapping[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {
            "verdict": self.verdict,
            "code": self.code,
            "reason": self.reason,
            "projection": dict(self.projection),
            "updates": {key: dict(value) if isinstance(value, dict) else value for key, value in self.updates.items()},
        }


def _deny(code: str, reason: str, projection: Mapping[str, Any]) -> GateDecision:
    return GateDecision("deny", code, reason, projection, {})


def _allow(code: str, projection: Mapping[str, Any], updates: Mapping[str, Any]) -> GateDecision:
    return GateDecision("allow", code, "", projection, updates)


def _projection(evidence: Mapping[str, Any], reviewed_sha: str, result: str, availability: str) -> dict:
    return {
        "source_url": evidence.get("source_url") or "",
        "repo": evidence.get("repo") or "",
        "pr": evidence.get("pr") or 0,
        "reviewed_sha": reviewed_sha,
        "result": result,
        "availability": availability,
    }


def _availability_of(evidence: Mapping[str, Any]) -> str:
    bot = evidence.get("coderabbit") or {}
    status = bot.get("status") if isinstance(bot, dict) else None
    if status == "clean":
        return "available"
    if status == "unavailable-declared":
        return "unavailable"
    return "unknown"


def _open_blockers(evidence: Mapping[str, Any]) -> list:
    blockers = evidence.get("blockers") or []
    return [b for b in blockers if isinstance(b, dict) and b.get("repro")]


def _receipt_error_code(error: str) -> str:
    if "identidad reutilizada" in error:
        return "revisor-es-autor"
    if "repo distinto" in error:
        return "recibo-otro-repo"
    if "pr distinto" in error:
        return "recibo-otro-pr"
    if "sha distinto" in error:
        return "recibo-otro-sha"
    if "bloqueante abierto" in error:
        return "bloqueante-abierto"
    return "sin-recibo"


def receipt_mode(record: Mapping[str, Any], table: Mapping[str, Any]) -> str:
    """Modo de recibo que declara la preaprobacion aprobada del registro.

    Apagar el kit exige una declaracion versionada; que falte la libreria del
    kit jamas lo apaga. Un valor fuera del conjunto en CUALQUIER entrada
    invalida la tabla entera (ValueError).
    """
    entries = table.get("preaprobaciones")
    if not isinstance(entries, list):
        raise ValueError("tabla sin lista de preaprobaciones")
    for entry in entries:
        if isinstance(entry, dict) and entry.get("modo_recibo", KIT_RECEIPT) not in RECEIPT_MODES:
            raise ValueError(f"modo_recibo fuera del conjunto: {entry.get('modo_recibo')}")
    ref = record.get("authorization_ref")
    for entry in entries:
        if (
            isinstance(ref, str)
            and ref
            and isinstance(entry, dict)
            and entry.get("id") == ref
            and entry.get("decision") == "Aprobado"
        ):
            return str(entry.get("modo_recibo", KIT_RECEIPT))
    return KIT_RECEIPT


@dataclass(frozen=True)
class ReviewerVerdict:
    source: str
    reason: str


def _bot(item: Mapping[str, Any], logins: frozenset) -> bool:
    user = item.get("user")
    return isinstance(user, dict) and user.get("type") == "Bot" and user.get("login") in logins


def _deepseek_blocking(body: str) -> str:
    """'' si el comentario completo no trae High/Critical abiertos; si no, el motivo."""
    lines = [line.strip() for line in body.splitlines() if line.strip().startswith(FINDINGS_MARK)]
    if len(lines) != 1 or not lines[0].endswith("-->"):
        return "el comentario de DeepSeek no trae hallazgos legibles"
    try:
        data = json.loads(lines[0][len(FINDINGS_MARK):-3].strip())
    except json.JSONDecodeError:
        return "el comentario de DeepSeek no trae hallazgos legibles"
    findings = data.get("findings") if isinstance(data, dict) else None
    if not isinstance(findings, list) or not all(isinstance(f, dict) for f in findings):
        return "el comentario de DeepSeek no trae hallazgos legibles"
    for finding in findings:
        if finding.get("state") == "open" and str(finding.get("severity") or "").lower() in BLOCKING_SEVERITIES:
            return f"DeepSeek tiene abierto un hallazgo {finding.get('severity')} en el head"
    return ""


def reviewer_verdict(sha: str, comments: list, reviews: list) -> ReviewerVerdict:
    """Veredicto de revisor independiente sobre ESTE head, leido de GitHub.

    Vale el comentario de DeepSeek completo para el head sin High/Critical
    abiertos (Medium/Low no bloquean, igual que al mergear a mano) o una
    review de CodeRabbit con commit_id del head. Un High abierto bloquea
    aunque CodeRabbit haya revisado.
    """
    completion = f"<!-- ai-review:completion={sha}:complete -->"
    deepseek_ok = False
    stale = False
    for comment in comments:
        if not isinstance(comment, dict) or not _bot(comment, DEEPSEEK_LOGINS):
            continue
        body = str(comment.get("body") or "")
        if completion not in [line.strip() for line in body.splitlines()]:
            if "<!-- ai-review:completion=" in body:
                stale = True
            continue
        blocking = _deepseek_blocking(body)
        if blocking:
            return ReviewerVerdict("", blocking)
        deepseek_ok = True
    if deepseek_ok:
        return ReviewerVerdict("deepseek", "")
    for review in reviews:
        if not isinstance(review, dict) or not _bot(review, CODERABBIT_LOGINS):
            continue
        if review.get("commit_id") != sha:
            stale = True
            continue
        if review.get("state") in ("CHANGES_REQUESTED", "DISMISSED"):
            continue
        return ReviewerVerdict("coderabbit", "")
    if stale:
        return ReviewerVerdict("", "el veredicto del revisor es de otro head")
    return ReviewerVerdict("", "sin veredicto de revisor independiente para el head")


def gate_decision(state: Mapping[str, Any], action: str, sha: str) -> GateDecision:
    """Decide una compuerta. state trae lane, evidence, receipt, pr frescos."""
    lane = state.get("lane") or {}
    evidence = state.get("evidence") or {}
    receipt = state.get("receipt")
    receipt_error = state.get("receipt_error") or ""
    pr = state.get("pr") or {}
    if action not in ACTIONS:
        return _deny("accion-desconocida", f"accion fuera del conjunto: {action}",
                      _projection(evidence, "", "unknown", "unknown"))
    if evidence.get("head") != sha:
        return _deny("evidencia-otro-sha",
                      "la evidencia aplica a otro head",
                      _projection(evidence, str(evidence.get("head") or ""), "stale", "unknown"))
    if action == "cross-review":
        return _decide_cross_review(evidence, sha)
    if action == "push-pr":
        return _decide_push_pr(evidence, sha)
    if action == "ci":
        return _decide_ci(evidence, sha)
    if action == "coderabbit":
        return _decide_coderabbit(evidence, sha)
    if action == "merge":
        if state.get("receipt_mode") == REVIEWER_RECEIPT:
            return _decide_merge_reviewer(evidence, state.get("reviewer"), pr, sha)
        return _decide_merge(evidence, receipt, receipt_error, pr, sha)
    if action == "deploy":
        return _decide_deploy(lane, evidence, pr, sha)
    if action == "canary":
        return _decide_canary(lane, evidence, sha)
    return _decide_rollback(evidence, sha)


def _review_ok(evidence: Mapping[str, Any], sha: str, rebase_old: str = "") -> Mapping[str, Any] | None:
    review = evidence.get("review")
    if not isinstance(review, dict):
        return None
    if review.get("verdict") != "approve":
        return None
    if review.get("sha") == sha:
        return review
    if rebase_old and review.get("sha") == rebase_old:
        return review
    return None


def _delta_violation(evidence: Mapping[str, Any], review: Mapping[str, Any]) -> str:
    previous = evidence.get("previous_reviewer")
    if previous and review.get("reviewer") == previous and not evidence.get("rebase"):
        return "mismo-revisor"
    return ""


def _decide_cross_review(evidence: Mapping[str, Any], sha: str) -> GateDecision:
    review = evidence.get("review")
    authors = list(evidence.get("authors") or [])
    projection = _projection(evidence, sha, "pending", _availability_of(evidence))
    if not isinstance(review, dict) or review.get("sha") != sha:
        return _deny("sin-cross-review", "sin revision del head actual", projection)
    reviewer = review.get("reviewer") or ""
    if reviewer in authors:
        return _deny("revisor-es-autor", "el autor actua como revisor independiente",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    if review.get("verdict") != "approve":
        return _deny("bloqueante-abierto", "la revision no aprueba", projection)
    return _allow("cross-review-ok", _projection(evidence, sha, "approved", _availability_of(evidence)),
                  {"review": dict(review)})


def _decide_push_pr(evidence: Mapping[str, Any], sha: str) -> GateDecision:
    projection = _projection(evidence, sha, "pending", _availability_of(evidence))
    review = _review_ok(evidence, sha)
    if review is None:
        return _deny("sin-cross-review", "el primer push exige cross-review aprobada del head", projection)
    violation = _delta_violation(evidence, review)
    if violation:
        return _deny(violation, "la correccion la revisa otro revisor", projection)
    open_blockers = _open_blockers(evidence)
    if open_blockers:
        return _deny("bloqueante-abierto", "hay bloqueantes abiertos", projection)
    return _allow("push-pr-ok", _projection(evidence, sha, "approved", _availability_of(evidence)),
                  {"push_pr": {"sha": sha, "review": dict(review)}})


def _decide_ci(evidence: Mapping[str, Any], sha: str) -> GateDecision:
    ci = evidence.get("ci")
    projection = _projection(evidence, sha, "pending", _availability_of(evidence))
    if ci is None:
        return _deny("ci-ausente", "sin CI para el head", projection)
    if not isinstance(ci, dict) or ci.get("sha") != sha:
        return _deny("ci-stale", "la CI es de otro sha", projection)
    if ci.get("conclusion") == "success":
        return _allow("ci-ok", _projection(evidence, sha, "approved", _availability_of(evidence)),
                      {"ci": dict(ci)})
    if ci.get("conclusion") == "failure":
        return _deny("ci-rojo", "CI en rojo", projection)
    return _deny("ci-pendiente", "CI sin concluir", projection)


def _decide_coderabbit(evidence: Mapping[str, Any], sha: str) -> GateDecision:
    bot = evidence.get("coderabbit")
    if not isinstance(bot, dict):
        return _deny("coderabbit-pendiente", "CodeRabbit sin estado",
                      _projection(evidence, sha, "pending", "unknown"))
    if bot.get("sha") != sha:
        return _deny("coderabbit-stale", "el estado del bot es de otro sha",
                      _projection(evidence, sha, "stale", "unknown"))
    if bot.get("status") == "clean":
        return _allow("coderabbit-ok", _projection(evidence, sha, "approved", "available"),
                      {"coderabbit": dict(bot)})
    if bot.get("status") == "blocked":
        return _deny("coderabbit-bloqueante", "CodeRabbit con bloqueantes",
                      _projection(evidence, sha, "blocked", "available"))
    if bot.get("status") == "unavailable-declared":
        return _allow("coderabbit-ok", _projection(evidence, sha, "unknown", "unavailable"),
                      {"coderabbit": dict(bot)})
    return _deny("coderabbit-pendiente", "CodeRabbit sin concluir",
                  _projection(evidence, sha, "pending", "unknown"))


def _decide_merge(
    evidence: Mapping[str, Any],
    receipt: Mapping[str, Any] | None,
    receipt_error: str,
    pr: Mapping[str, Any],
    sha: str,
) -> GateDecision:
    if receipt is None:
        code = _receipt_error_code(receipt_error)
        return _deny(code, "sin recibo aplicable del kit para el head",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    if receipt.get("repo") != evidence.get("repo"):
        return _deny("recibo-otro-repo", "el recibo es de otro repo",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    if str(receipt.get("pr")) != str(evidence.get("pr")):
        return _deny("recibo-otro-pr", "el recibo es de otro PR",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    if receipt.get("sha") != sha:
        return _deny("recibo-otro-sha", "el recibo es de otro sha",
                      _projection(evidence, sha, "stale", _availability_of(evidence)))
    reviewer = (receipt.get("reviewer") or {}).get("id") or ""
    implementer = (receipt.get("implementer") or {}).get("id") or ""
    return _merge_after_authority(evidence, pr, sha, reviewer, implementer, str(receipt.get("sha", sha)))


def _decide_merge_reviewer(
    evidence: Mapping[str, Any],
    reviewer_reads: Mapping[str, Any] | None,
    pr: Mapping[str, Any],
    sha: str,
) -> GateDecision:
    if not isinstance(reviewer_reads, dict):
        return _deny("revisor-ilegible", "no se pudo leer el veredicto del revisor en GitHub",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    verdict = reviewer_verdict(sha, reviewer_reads.get("comments") or [], reviewer_reads.get("reviews") or [])
    if not verdict.source:
        return _deny("sin-veredicto-revisor", verdict.reason,
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    return _merge_after_authority(evidence, pr, sha, verdict.source, "", sha)


def _merge_after_authority(
    evidence: Mapping[str, Any],
    pr: Mapping[str, Any],
    sha: str,
    reviewer: str,
    implementer: str,
    authority_sha: str,
) -> GateDecision:
    if pr.get("head") != sha:
        return _deny("pr-avanzado", "el head del PR ya no es el revisado",
                      _projection(evidence, sha, "stale", _availability_of(evidence)))
    # 14.4 r2 B2: los checks releidos de GitHub mandan. Deben ser del SHA
    # pedido y exitosos; cualquier check fallido en el rollup lo falla todo.
    checks = pr.get("checks") or {}
    if not isinstance(checks, dict) or not checks:
        return _deny("ci-ausente", "sin checks releidos de GitHub para el head",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    if checks.get("sha") != sha:
        return _deny("ci-stale", "los checks releidos son de otro sha",
                      _projection(evidence, sha, "stale", _availability_of(evidence)))
    if checks.get("conclusion") != "success":
        code = "ci-rojo" if checks.get("conclusion") == "failure" else "ci-pendiente"
        return _deny(code, "los checks releidos no dan success",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    ci = evidence.get("ci")
    if ci is None:
        return _deny("ci-ausente", "sin CI para el head",
                      _projection(evidence, sha, "missing", _availability_of(evidence)))
    if not isinstance(ci, dict) or ci.get("sha") != sha:
        return _deny("ci-stale", "la CI es de otro sha",
                      _projection(evidence, sha, "stale", _availability_of(evidence)))
    if ci.get("conclusion") != "success":
        code = "ci-rojo" if ci.get("conclusion") == "failure" else "ci-pendiente"
        return _deny(code, "CI sin verde vigente",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    authors = list(evidence.get("authors") or [])
    if implementer:
        authors.append(implementer)
    if reviewer in authors:
        return _deny("revisor-es-autor", "el autor actua como revisor independiente",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    open_blockers = _open_blockers(evidence)
    if any(int(b.get("rounds_seen") or 0) >= 2 for b in open_blockers):
        return _deny("bloqueante-repetido", "el mismo bloqueante volvio en dos rondas",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    if open_blockers:
        return _deny("bloqueante-abierto", "hay bloqueantes abiertos",
                      _projection(evidence, sha, "blocked", _availability_of(evidence)))
    bot = evidence.get("coderabbit") or {}
    bot_status = bot.get("status") if isinstance(bot, dict) else None
    if bot_status == "blocked":
        return _deny("coderabbit-bloqueante", "CodeRabbit con bloqueantes abiertos",
                      _projection(evidence, sha, "blocked", "available"))
    if bot_status not in ("clean", "unavailable-declared"):
        return _deny("coderabbit-pendiente", "CodeRabbit sin estado para el head",
                      _projection(evidence, sha, "pending", "unknown"))
    if isinstance(bot, dict) and bot.get("sha") != sha:
        return _deny("coderabbit-stale", "el estado del bot es de otro sha",
                      _projection(evidence, sha, "stale", _availability_of(evidence)))
    rebase = evidence.get("rebase") if isinstance(evidence.get("rebase"), dict) else None
    rebase_old = ""
    if rebase:
        if (
            rebase.get("new_sha") != sha
            or not rebase.get("content_diff_empty_verified")
            or not rebase.get("old_sha")
        ):
            return _deny("rebase-no-mecanico", "el rebase no trae diff vacio verificado",
                          _projection(evidence, sha, "stale", _availability_of(evidence)))
        rebase_old = str(rebase.get("old_sha"))
    review = _review_ok(evidence, sha, rebase_old)
    if review is not None:
        violation = _delta_violation(evidence, review)
        if violation:
            return _deny(violation, "la correccion la revisa otro revisor",
                          _projection(evidence, sha, "blocked", _availability_of(evidence)))
    reviewed = review.get("sha", sha) if review is not None else authority_sha
    availability = _availability_of(evidence)
    result = "approved" if availability == "available" else "conditional"
    updates: dict = {
        "receipt": {"sha": sha, "reviewer": reviewer, "verdict": "approve"},
        "ci": dict(ci),
        "coderabbit": dict(bot),
    }
    if review is not None:
        updates["review"] = dict(review)
    if rebase:
        updates["rebase"] = {"old_sha": rebase_old, "new_sha": sha}
    return _allow("merge-ok", _projection(evidence, str(reviewed), result, availability), updates)


def _decide_deploy(
    lane: Mapping[str, Any], evidence: Mapping[str, Any], pr: Mapping[str, Any], sha: str
) -> GateDecision:
    delivery = lane.get("delivery") or {}
    merge = delivery.get("merge") or {}
    reviewed = merge.get("reviewed_head") or ""
    commit = merge.get("merge_commit") or ""
    projection = _projection(evidence, reviewed or sha, "missing", "unknown")
    if not commit or pr.get("merged") is not True:
        return _deny("sin-merge", "deploy sin merge registrado", projection)
    updates = {"deploy": {"reviewed_head": reviewed, "merge_commit": commit}}
    return _allow("deploy-ok", _projection(evidence, reviewed, "approved", "available"), updates)


def _decide_canary(lane: Mapping[str, Any], evidence: Mapping[str, Any], sha: str) -> GateDecision:
    delivery = lane.get("delivery") or {}
    projection = _projection(evidence, sha, "missing", _availability_of(evidence))
    deploy = delivery.get("deploy") or {}
    if not deploy:
        return _deny("sin-deploy", "canary sin deploy registrado", projection)
    canary = evidence.get("canary")
    if not isinstance(canary, dict) or not canary.get("result"):
        return _deny("canary-sin-resultado", "canary sin resultado observable", projection)
    # 14.21 punto 2: el canary responde por el SHA desplegado y con resultado
    # de pase; un canary fallido o de otro SHA jamas permiten.
    if str(canary.get("sha") or "") != str(deploy.get("sha") or ""):
        return _deny("canary-otro-sha", "canary de un SHA distinto al desplegado", projection)
    if canary.get("result") != "pass":
        return _deny("canary-fallo", "canary con resultado fallido", projection)
    return _allow("canary-ok", _projection(evidence, sha, "approved", _availability_of(evidence)),
                  {"canary": dict(canary)})


def _decide_rollback(evidence: Mapping[str, Any], sha: str) -> GateDecision:
    rollback = evidence.get("rollback")
    projection = _projection(evidence, sha, "pending", _availability_of(evidence))
    if not isinstance(rollback, dict) or rollback.get("verified") is not True:
        return _deny("rollback-sin-verificar", "cierre sin rollback verificado", projection)
    return _allow("rollback-ok", _projection(evidence, sha, "approved", _availability_of(evidence)),
                  {"rollback": dict(rollback)})
