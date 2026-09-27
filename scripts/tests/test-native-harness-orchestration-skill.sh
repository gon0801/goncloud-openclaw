#!/bin/bash
# Task 9: contrato de la skill native-harness-orchestration de main.
# La skill es una tabla de decision ejecutable: rutea nativos, conserva la
# cadena legada con CORRIDA_NATIVE_ROUTING=off, y prohibe lo que la Fase 14
# prohibe (merge/despliegue por main, secretos en briefs, cambio de harness
# en silencio). Uso: bash scripts/tests/test-native-harness-orchestration-skill.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SKILL_DIR=agents/main/agent/workshop-skills/native-harness-orchestration
SKILL="$SKILL_DIR/SKILL.md"
DISPATCH=agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
INST=scripts/mac/instalar-mac.sh

[ -f "$SKILL" ] || fail "no existe la skill $SKILL (Task 9 Step 1)"

exige() { # $1 patron-fijo $2 descripcion
  grep -qF -- "$1" "$SKILL" || fail "la skill no $2"
}

# Reglas del Task 9 Step 1.
exige "EMPIEZA reconciliando" "ordena reconciliar antes de cada efecto"
exige "Explicación del selector" "registra la explicacion del selector"
exige "cuatro" "fija el tope de cuatro sesiones externas"
exige "cambia de harness en silencio" "declara que nunca cambia de harness en silencio"
exige "disponibilidad" "exige handoff de disponibilidad registrado (loop 9)"
exige "secretos" "prohibe secretos en los briefs"
exige "Main nunca mergea ni despliega" "prohibe que main mergear o desplegar"
exige "Revisión cruzada local antes del primer push" "exige revisión cruzada local antes del primer push"
exige "CodeRabbit" "maneja el loop de correccion en el mismo PR"
exige "canary" "exige canary vivo verificado"
exige "CORRIDA_NATIVE_ROUTING=off" "documenta el ruteo apagado hacia agent-dispatch"
exige "siguiente candidato compatible" "routea fallos al siguiente candidato no intentado"
exige "mediciones" "preserva las mediciones por host"
exige "pre-install" "conserva la ruta pre-install/manual de Fases 14 y 23"

# Tabla de decision: comandos exactos del ciclo.
for cmd in "corrida.sh abrir" "preflight" "select" "preparar-carril" \
           "adaptador" "inspect" "reconciliar" "evidence" "compuerta" "canary" \
           "corrida.sh cerrar"; do
  grep -qF -- "$cmd" "$SKILL" || fail "la skill no documenta el comando: $cmd"
done

# 14.13d: effort y model/reported_model con su distincion.
exige "effort" "muestra el effort del worker"
exige "reported_model" "distingue model (configurado) de reported_model (reportado)"

# DoD 14.6: sin rutas absolutas de binarios especificos de usuario.
if grep -qE "/Users/[a-z]+|/home/[a-z]+" "$SKILL"; then
  fail "la skill trae rutas absolutas de usuario"
fi

# Puntero unico: agent-dispatch apunta a la skill una sola vez y respeta el off.
grep -qF "native-harness-orchestration" "$DISPATCH" \
  || fail "agent-dispatch no apunta a la skill nativa"
n=$(grep -c "native-harness-orchestration" "$DISPATCH")
[ "$n" -eq 1 ] || fail "agent-dispatch nombra la skill $n veces (puntero unico = 1)"
grep -qF "CORRIDA_NATIVE_ROUTING=off" "$DISPATCH" \
  || fail "agent-dispatch no documenta el ruteo con off"

# Instalador atomico: el paquete y el registro viajan con el dispatcher.
for pieza in "corrida-worker.py" "corrida_worker" "workers.v1.json" "preaprobaciones.v1.json"; do
  grep -qF -- "$pieza" "$INST" || fail "el instalador no instala $pieza"
done
grep -qF "test-native-harness-orchestration-skill" "$INST" >/dev/null 2>&1 || true

echo "TODO VERDE: native-harness-orchestration-skill"
