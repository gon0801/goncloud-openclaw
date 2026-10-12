#!/bin/bash
# Parte a del simulacro de Fase 9. Los escenarios, cuales le tocan a cada parte y el
# candado de que la union los cubre a todos viven en
# scripts/tests/simulacro-fase9/escenarios.sh.
# Uso: bash scripts/tests/test-simulacro-fase9-a.sh
SIM9_PARTE=a exec bash "$(dirname "$0")/simulacro-fase9/escenarios.sh"
