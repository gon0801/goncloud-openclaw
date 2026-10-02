#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -m unittest discover -s scripts/tests -p 'test_agent_work_cutover.py' -v
