# The one full battery

Read from `regression-triage` §3. The full suite runs **once** per task (CI covers it when CI already ran the same SHA); the checks in §2 are focused runs and do not spend it.

## Launch detached with an exit sentinel

`nohup <runner> > /tmp/run.log 2>&1 &`, appending `echo "EXIT=$?"` when the runner ends — the sentinel is the only proof the run finished rather than died.

## A dropped host is not a slow suite

If the exec host drops mid-run, do not relaunch blindly. A log that stops without its sentinel and has no live runner process (`ps aux | grep <runner>`) is a **dead run**, not a slow suite.

## No watchdog

macOS has no `timeout`; watch the log, not a watchdog. A dead run leaves the full battery unspent.

## Done when

The log ends in its sentinel with a live-or-finished runner behind it, or the run is declared dead and the battery is still unspent. A log without the sentinel is never reported as a verdict.
