---
name: autopilot-runbook
description: Use when writing a plan, runbook, tablero or guía that an agent will execute in autopilot without a human answering questions, or when a reader (agent or person) came back with "dudas" or "¿lo leí bien?" about an existing runbook. Covers execution guides for Plans.md phases, multi-repo lanes, cross-review loops, and merge queues.
---

# Autopilot runbook

## Overview

An autopilot runbook is a contract the executing agent can follow with **zero questions back**. The test of the document is not "is it complete" but "could a careful reader still ask something". Every slot below is REQUIRED; a missing slot is where the question comes from.

Measured baseline (2026-09-15, Fase 6 de claw): a runbook written without this recipe came back with five questions from its first reader, all of the same shape: a fact the author knew and did not write (base branch of two lanes in one repo, whether a follow-up PR blocks a merge, which timezone, what "un turno a main" means concretely, whether budget must be prepared).

## The document, in order

1. **Título + para quién.** First paragraph addresses the executor in second person and names who is absent ("David no está y no se le pregunta nada").
2. **Quién.** Every role that appears later, one line each, including the human's only remaining action. The lead is written as a **role** ("el lead", launched by claw from a preference list of kit hosts), never as a model name: the lead can be any host the merge kit knows and can change mid-phase. Measured 2026-09-16: the Fase 7 runbook said "lead: Claude"; with claw or kimi as lead every merge in the queue would have failed closed with "sin estado del hook".
3. **Arranque.** The executor's first two steps. Where the authorization lives and what to do if the file is missing (answer: the table in this document is the authorization; never ask).
4. **Preaprobaciones.** Table: operación · alcance · decisión (Aprobado / Negado). Denied items are listed, not omitted.
5. **Prohibido.** One callout, exhaustive, including "preguntarle algo al humano".
6. **Reglas de trabajo.** Numbered, each with the exact command where a command exists.
7. **Loop de entrega.** One paragraph that references `docs/runbooks/loop-autopilot.md` in goncloud-openclaw by section number (the per-task loop, the review-round policy, the PR and CodeRabbit policy, the kit merge route, the safe window, resume, phase-close review) and states any deviation for this phase with the section named and the reason. The runbook does NOT restate the loop: a restated loop is where the two documents drift apart. Measured 2026-09-16: the Fase 6 and 7 runbooks restated it (40 and 36 KB) and the Fase 7 copy diverged in three points within a day.
8. **Carriles.** One block per lane with: repo · default branch · branch name; the tasks with their DoD; and a **files table** (puede tocar / no toca) covering every lane.
9. **Cola de merge.** Ordered items, each with its gate written as an observable check and its automatic fallback.
10. **Cuando algo se atora.** Table situación → acción. Every "if" that appears anywhere else in the document has a row here.
11. **Inventario y cierre.** Counts, cost, budget, what is out of scope, and how the executor reports.
12. **Progreso.** One rule in Reglas de trabajo: on every lane or queue state change, and at close, the lead writes `runbook-progress.v1` (spec: `docs/spec/runbook-progress.v1.md` in goncloud-openclaw) to `.saikit/progress/<fase>.json` and sends it with `openclaw gateway call runbook.progress.set --params @<file>`; a failed send never blocks and is retried at the next state change. Every write carries `atencion_requerida` (true only for the rows that reach the human) and `siguiente_paso` in plain language. The interface reads that JSON; nothing else counts as progress.

## Ambiguity pass (run before delivering)

Read the finished document as the executor and answer each question from the text alone. If the answer is "se deduce" or "obvio", it is not written: write it.

| Question the executor will ask | Slot that must answer it |
|---|---|
| From which commit does each branch start, and does lane X depend on lane Y having pushed? | Carriles: "rama base" paragraph, per repo, plus files table |
| If a follow-up PR appears, does it block a merge already queued? | Carriles or Cola: name the follow-up branch and where in the queue it goes |
| Which timezone, and how is the time read? | Any time window: name the IANA zone, the clock it comes from, and the command to read it |
| What does "un turno / un mensaje / un canary" mean mechanically? | Cola gates: exact command, expected duration, timeout, what it must not do |
| Is there anything to prepare (budget, quota, access) before launch? | Inventario: "Presupuesto" line plus a table row for quota exhaustion and for relaunch/resume |
| Who reviews when the author is not the usual one? | Loop step 2: exclusion by author, preference order |
| Which task IDs, branch names, file paths, labels, marker strings? | Everywhere: literal strings, never "una etiqueta" or "un comentario" |
| Where does state live if the session dies? | Atores table: "Reanudación" row |
| Does the source plan (Plans.md, spec) say something different from this runbook? | Arranque: one sentence naming which document wins, and the task that edits the other to match |
| Where on disk is every repo, and where on every target machine is its deployed copy? | Arranque: table repo · ruta local · default branch · ruta en el destino, one row per repo, `unknown` allowed |
| Which AI implements each lane, so the reviewer exclusion is right? | Quién: one sentence naming the implementer per lane or for all lanes |
| What is the state of the working tree at launch, and which uncommitted files belong to the phase? | The first task of the lane that commits the plan: source of the content and the list of files that do NOT enter |
| How does the closing edit (status markers, ledger) get into the repo after every lane merged? | Cola: a named closing PR with its own branch, files, loop and merge window |
| Does every verification path in a gate exist for every target it applies to? | Gate text: "usando la ruta de la tabla para cada uno de A, B y C", never a single path applied to three repos |

| Does an approval survive a mechanical step (rebase, squash) that changes the identifier it was given on? | Loop: a rule keyed to an observable check (empty diff → re-mark; non-empty → reopen) |
| What is the literal command for the action everyone else has a command for (merge, deploy, publish)? | Cola: the exact invocation, in order, with what each output means; if the tool was designed to stop and ask, say whose written yes replaces the ask |
| Does an emergency path (revert, rollback) have its own branch name, its own reduced loop, and its own merge command? | Cola gate: named like every other lane, never "por la misma ruta" |
| Does the tool the runbook relies on have preconditions the session must satisfy (a sentinel, a hook, a sealed state)? | Arranque or Cola: name the precondition and put it in the launch instruction |
| Does every phrase like "via X" / "through the gateway" / "remotely" name ONE mechanism with its command, allowed inputs, duration and timeout, wherever it appears (not only in the section that first defined it)? | One "qué es X" paragraph that lists every section that uses it, and a closed list of allowed commands |
| Does the emergency path itself have a failure row (the revert conflicts, the rollback tool refuses)? | Atores table: the deterministic second attempt, and the one case that is allowed to reach the human early |
| Every file the runbook tells the executor to open (an approvals record, a config, a manifest): do its literal fields (counters, scopes, expiry) agree with what the runbook promises, and which one wins when they differ? | Open the file yourself before delivering; write the precedence rule in Arranque and a row in Atores for the mismatch |
| Does the runbook assume a precondition it does not produce (a merged PR, an installed tool, an existing branch)? | Arranque step 0.0: the check command, and what to do when it fails, including "the phase stops" |
| When a test is "sent to an agent", is the agent the one whose behavior the test actually exercises (not one on an allowlist), is the command inert if the guard fails, and is the mechanism the same closed one defined elsewhere? | Cola gate: name the agent, why that one, the literal message, and why it is harmless |
| If the runbook introduces long-lived external processes (tmux sessions, headless runs), does the resume row say how to find their state after the lead dies? | Atores: a resume row that names the session names, the capture command and the marker lines to look for |
| Do the rules and the files table agree on every path the runbook mentions (scratch, logs, outputs)? | Grep every path in the document against the files table before delivering |
| Is every flag, mode or argument the executor must pass written INSIDE the command it runs, with a check that it took effect? | The command itself carries it (a `<placeholder>` defined in the same sentence), followed by the observable that proves it (a status bar word, a process argument). A table next to the command saying "add the flag from your row" is not the command. Measured 2026-09-17, Fase 7: the launch line ended in the bare binary, both lanes started without their no-ask flag, one sat 7 h on a permission prompt |
| Who is awake while long-lived external processes work, and does the wake-up actually fire for THESE tools? | Name the mechanism and prove it against each CLI of the phase before relying on it: an agent turn ends minutes after launching, so "the lead watches the screen" is not a mechanism. Measured 2026-09-17: the tmux watcher keyed on `#{window_activity}`, zcode and muse repaint every second, no event fired all night. Run the watcher `--once` with a stub sender against a live pane of each tool |
| Does the runbook name a specific model as the lead, or restate a rule that already lives in `loop-autopilot.md`? | Quién: the lead is a role. Loop paragraph: reference by section, deviations named. Run `scripts/tests/test-runbooks-no-contradicen-entorno.sh` and `scripts/tests/test-loop-autopilot.sh` before delivering |
| Every tool the runbook drives (a CLI, a flag, a script, a helper): does it exist on the executor's PATH, accept those exact values, and act on the machine the runbook assumes? | Run each one. Measured on Fase 7: the binary was not on the PATH at all; a flag value was outside the tool's closed set and the tool aborted on parameter validation; a config command written as the deploy step edited the local file and never reached the target host, with a read-back that returned a false green; and a launcher that attaches instead of detaching failed because the lead itself runs inside the multiplexer |
| Does a shell snippet in the runbook actually produce the value the runbook's own rule reads back? | Paste it and run it. Measured on Fase 7: `test -x "$b"; echo "$(basename $b)=$?"` always prints 0, because the command substitution expands before `$?` and reports `basename`'s status, so the rule keyed to a non-zero value could never fire |
| A fact you call "measured" about the repo: did you read it on the branch the phase will run on? | Read it with `git show origin/<default>:<path>`, never from whatever working tree is open. Measured on Fase 7: a reader called a justification false, the author "confirmed" it by reading the file in a clone parked on an old branch, and both were wrong about the live code |
| A gate that needs the network or another host: what happens when the executor cannot reach it? | Give it a non-network equivalent and say the datum stays `unknown` and the phase continues. Measured on Fase 7: three gates hung on one request to a private address, and in autopilot a blocked egress means stopping to ask a human, which is the one thing the runbook forbids |
| Every check that decides something: can it come out the other way? | Force the failing case and watch it fail. A check whose two sides come from the same source, or that holds by construction, is decoration the executor will read as a verdict. Measured on Fase 7: a precondition compared a file against itself, because the worktree it ran in was created from the very branch it was comparing to, so it answered "same" always and the executor would have skipped a merge the phase depends on; a second one read a SHA as the tip of a synced clone, but that clone commits its own snapshot before pulling, so the tip is almost never the merged SHA and the gate would have blocked the deploy for a cause that does not exist |

Readers on the Fase 6 runbook: 5, 6, 3, 2, 2, 1, then empty. On the Fase 7 runbook (inherits from Fase 6, adds external implementers in tmux and a live deploy): 6, 4, 7, 5, 3, 3, 2, 1, 6, 3, 4, 5, 3 without reaching empty in thirteen passes; readers kept finding one-line gaps, and two were contradictions introduced by earlier fixes. Every item was a fact the author had in context and never wrote, or a file the runbook pointed at and the author had not reopened. Budget four to six readers for a multi-repo runbook. After the sixth pass, re-read the whole document yourself once for contradictions between edited paragraphs, and stop when a pass returns only items you can classify as "one sentence, no new mechanism"; declare the last pass's items as residuals if you stop before an empty list.

## Rules for wording

- A command is written verbatim with its flags; a placeholder is `<en-angulos>` and is defined in the same sentence.
- A time is a zone + a source clock + a read command. A duration has a number and a cap.
- A decision is a table row (situación → acción), never a sentence starting with "si hace falta".
- Unknowns are written `unknown` with the command that would resolve them; the executor is told to keep them `unknown`.
- Every artifact the executor produces has a literal name: branch, file path, PR label, comment marker.
- The Markdown file is the source; a web page is a copy and says so in its footer.

## Verification (required before delivering)

Dispatch one fresh-context subagent as the executor with this SKILL.md and the runbook, and the instruction: "list every question you would still have to ask a human; if the answer is deducible but not written, list it". Fix the runbook for every item, then dispatch another fresh reader.

**One stopping rule, and it is the one above:** deliver when a pass returns either an empty list or only items you can classify as "one sentence, no new mechanism", and in that second case write those items into the runbook or the PR as declared residuals. Do not deliver on an unverified pass, and do not keep going past that point hoping for an empty list: every full rewrite manufactures new contradictions for the next reader, which is how the Fase 7 runbook reached thirteen passes without ever emptying. Two readers were needed on the first runbook that used this skill; the second found six items the first had not.

## Common mistakes

- Answering a reader's questions in chat instead of in the document. The next reader asks the same five.
- Writing "hora del Este" without the zone name and the clock it belongs to.
- A merge gate that says "verificar que funciona" instead of a command, an expected output, and the fallback.
- A files table that lists "puede tocar" but not "no toca": lanes collide on the file nobody claimed.
- Hardcoding the usual author (`-Excluir claude`) in the reviewer command.
