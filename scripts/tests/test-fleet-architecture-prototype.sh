#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
python3 -m unittest discover -s docs/prototypes/flota-poteto -v
