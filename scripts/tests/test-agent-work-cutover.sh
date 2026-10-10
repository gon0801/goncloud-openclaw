#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash -n scripts/agent-work/runtime/empaquetar-r.sh
node --check scripts/agent-work/runtime/pack-r.mjs
python3 -m unittest discover -s scripts/tests -p 'test_agent_work_cutover.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_agent_work_artifact.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_agent_work_cutover_live.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_agent_work_context_shadow.py' -v
