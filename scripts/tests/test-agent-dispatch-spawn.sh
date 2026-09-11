#!/bin/bash
# Prueba del canal entre agentes (2026-09-11): Claw despachaba con `sessions_send` sin esperar
# (timeoutSeconds 0) y esa respuesta regresa por un camino que muere en silencio cuando el turno que
# despacho ya cerro (E2 "agent tool caller authority is no longer active"; 41 respuestas perdidas el
# 09-11). El camino que si regresa es `sessions_spawn agentId=<agente>`: el announce corre en la sesion
# hija y le llega al que despacho como turno nuevo. Desde el 09-11 main tiene
# agents.entries.main.subagents.allowAgents para hacer spawn a los demas agentes.
# Verifica que la skill agent-dispatch de main (1) despache roles con sessions_spawn agentId, (2) ya no
# los despache con sessions_send, (3) ya no diga que el spawn por id solo vale para main y (4) advierta
# que sessions_send sin esperar pierde la respuesta.
# Uso: bash scripts/tests/test-agent-dispatch-spawn.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
F=agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
[ -f "$F" ] || fail "falta $F"
grep -qF 'sessions_spawn agentId=<role> mode=run' "$F" || fail "$F: no despacha roles con sessions_spawn agentId"
grep -qF 'Dispatch one role at a time with `sessions_send' "$F" && fail "$F: sigue despachando roles con sessions_send"
grep -qF 'Spawning is by id only for main' "$F" && fail "$F: sigue diciendo que el spawn por id solo vale para main"
grep -qF 'timeoutSeconds: 0' "$F" || fail "$F: falta la advertencia de sessions_send sin esperar"
echo "PASS test-agent-dispatch-spawn"
