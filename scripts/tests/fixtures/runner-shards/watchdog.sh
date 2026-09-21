#!/bin/sh
# Fixture del carril R (15.1): el "test-tmux-activity-watch.sh" de mentira (ver
# nucleo.sh para el porque del tally).
# Uso: solo via scripts/tests/test-runner-shards.sh (requiere TALLY_SHARDS).
printf 'watchdog\n' >> "$TALLY_SHARDS"
exit 0
