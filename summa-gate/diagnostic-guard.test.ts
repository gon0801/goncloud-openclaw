/**
 * diagnostic-guard — pure allowlisted core tests (Fase 5 / 5.3).
 *
 * Pins the frozen contract: three incidents only, real-failure gate,
 * 8192-char inspection bound, distinct-category counting, static guidance,
 * narrow task-level incapacity, single-revision predicate.
 *
 * Mutation pins (each must fail if the named guard is removed):
 * - isError gate        -> successful-result controls
 * - real signature      -> unknown-command / wrong-tool / echo controls
 * - dedup               -> repeated-category test
 * - 8192 bound          -> late-signature test
 * - privacy redaction   -> canary-absence tests
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  MAX_INSPECTED_CHARS,
  buildDiagnosticContract,
  classifyCompletedProbe,
  classifyIncident,
  isTaskLevelIncapacity,
  parseDiagnosticConfig,
  reduceDiagnosticState,
  shouldRequestRevision,
  type DiagnosticObservation,
  type DiagnosticState,
  type IncidentId,
} from "./diagnostic-guard.ts";

// ---------------------------------------------------------------------------
// Incident classification: positives
// ---------------------------------------------------------------------------

describe("classifyIncident positives", () => {
  it("classifies a gh PATH miss via exec", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: true,
      result: "bash: gh: command not found",
    };
    assert.equal(classifyIncident(obs), "path_miss:gh_cli");
  });

  it("classifies a gh PATH miss via bash with a Windows signature", () => {
    const obs: DiagnosticObservation = {
      toolName: "bash",
      args: { command: "gh auth status" },
      isError: true,
      result: "'gh' is not recognized as an internal or external command",
    };
    assert.equal(classifyIncident(obs), "path_miss:gh_cli");
  });

  it("classifies a gh ENOENT spawn failure", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { cmd: "gh --version" },
      isError: true,
      result: "spawn gh ENOENT",
    };
    assert.equal(classifyIncident(obs), "path_miss:gh_cli");
  });

  it("classifies a browser global-profile miss via exec (real incident shape)", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "openclaw browser --profile claw tabs --json" },
      isError: true,
      result:
        "gateway browser.request requires credentials before opening a websocket " +
        "Config: C:\\fakedir\\.openclaw-claw\\openclaw.json",
    };
    assert.equal(classifyIncident(obs), "wrong_profile:browser_claw");
  });

  it("does not mistake the valid browser-tool profile for the global-flag miss", () => {
    // Per browser-cli-claw-profile/SKILL.md:12, a tool-style profile=claw
    // means the BROWSER profile — the valid form, not the incident.
    const obs: DiagnosticObservation = {
      toolName: "browser",
      args: { action: "tabs", profile: "claw" },
      isError: true,
      result:
        "gateway browser.request requires credentials before opening a websocket " +
        "Config: C:\\fakedir\\.openclaw-claw\\openclaw.json",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("does not classify the correct --browser-profile flag as the incident", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "openclaw browser --browser-profile claw tabs --json" },
      isError: true,
      result: "gateway browser.request requires credentials before opening a websocket",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("classifies an unscoped sessions_search database failure", () => {
    const obs: DiagnosticObservation = {
      toolName: "sessions_search",
      args: { query: "census" },
      isError: true,
      result: { status: "error", tool: "sessions_search", error: "unable to open database file" },
    };
    assert.equal(classifyIncident(obs), "session_scope:sessions_search");
  });

  it("accepts an equivalent structured failure without isError", () => {
    const obs: DiagnosticObservation = {
      toolName: "sessions_search",
      args: { query: "census" },
      result: { status: "error", error: "ERR_SQLITE_ERROR: unable to open database file" },
    };
    assert.equal(classifyIncident(obs), "session_scope:sessions_search");
  });
});

// ---------------------------------------------------------------------------
// Incident classification: negative controls (isError + signature mutations)
// ---------------------------------------------------------------------------

describe("classifyIncident negative controls", () => {
  it("ignores the same phrase in a successful result (isError mutation pin)", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: false,
      result: "docs mention 'gh: command not found' as an example; command worked",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores result text alone with no failure marker", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "gh pr list" },
      result: "gh: command not found",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores the phrase under the wrong tool", () => {
    const obs: DiagnosticObservation = {
      toolName: "read",
      args: { path: "notes.md" },
      isError: true,
      result: "gh: command not found",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores an echo of the phrase (first token is echo, not gh)", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "echo 'gh: command not found'" },
      isError: true,
      result: "gh: command not found",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores an unknown command-not-found (signature mutation pin)", () => {
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "qqqzz --help" },
      isError: true,
      result: "bash: qqqzz: command not found",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores a legitimate reviewer negative without a recognized failure", () => {
    const obs: DiagnosticObservation = {
      toolName: "read",
      args: { path: "review.md" },
      result: "no hay herramienta de lint configurada; el CI corre solo pytest.",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores a browser success carrying reviewer prose", () => {
    const obs: DiagnosticObservation = {
      toolName: "browser",
      args: { action: "tabs" },
      result: "reviewer: the capability is unavailable in the report under review",
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores a scoped sessions_search failure as an incident (it is not unscoped)", () => {
    const obs: DiagnosticObservation = {
      toolName: "sessions_search",
      args: { agentId: "verifier", sessionKeys: ["agent:verifier:main"], query: "census" },
      isError: true,
      result: { status: "error", error: "unable to open database file" },
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores a partially scoped sessions_search failure as an incident", () => {
    const obs: DiagnosticObservation = {
      toolName: "sessions_search",
      args: { agentId: "verifier", query: "census" },
      result: { status: "error", error: "ERR_SQLITE_ERROR: unable to open database file" },
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("ignores a signature that only appears after the 8192-char bound (limit mutation pin)", () => {
    const pad = "x".repeat(8200);
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: true,
      result: `${pad} gh: command not found`,
    };
    assert.equal(classifyIncident(obs), undefined);
  });

  it("still classifies when the signature precedes padding", () => {
    const pad = "x".repeat(8200);
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: true,
      result: `gh: command not found ${pad}`,
    };
    assert.equal(classifyIncident(obs), "path_miss:gh_cli");
  });

  it("supports cyclic args/result without throwing (collector cycle pin)", () => {
    const cyclic: Record<string, unknown> = { command: "gh pr list" };
    cyclic.self = cyclic;
    const result: Record<string, unknown> = { out: "gh: command not found" };
    (result as Record<string, unknown>).self = result;
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: cyclic,
      isError: true,
      result,
    };
    assert.equal(classifyIncident(obs), "path_miss:gh_cli");
  });

  it("exposes the 8192 bound as a constant", () => {
    assert.equal(MAX_INSPECTED_CHARS, 8192);
  });
});

// ---------------------------------------------------------------------------
// Probe completion per incident
// ---------------------------------------------------------------------------

describe("classifyCompletedProbe path_miss:gh_cli", () => {
  const incident: IncidentId = "path_miss:gh_cli";
  it("labels executable discovery", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which gh" },
        result: "FOUND",
      }),
      "executable_discovery",
    );
  });
  it("counts a NOT_FOUND discovery as a completed probe", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "where gh" },
        result: "NOT_FOUND",
      }),
      "executable_discovery",
    );
  });
  it("labels a known-location check", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "Test-Path C:\\fakedir\\gh.exe" },
        result: "DENIED",
      }),
      "known_install_location",
    );
  });
  it("labels a read-only version probe as capability verification", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "C:\\fakedir\\gh.exe --version" },
        result: "AUTH_FAILED",
      }),
      "capability_verification",
    );
  });
  it("does not count an aborted call", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which gh" },
        result: undefined,
      }),
      undefined,
    );
  });
  it("does not count a cancelled call", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which gh" },
        result: { cancelled: true },
      }),
      undefined,
    );
  });
  it("does not count a probe about another subject", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which node" },
        result: "/usr/bin/node",
      }),
      undefined,
    );
  });
  it("does not let echo fake a version probe (spoof pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "echo gh --version" },
        result: "gh version 2.100.0",
      }),
      undefined,
    );
  });
  it("does not let echo fake executable discovery (spoof pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "echo which gh" },
        result: "FOUND",
      }),
      undefined,
    );
  });
  it("does not let a quoted documentary command count as a probe (spoof pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: '"gh --version"' },
        result: "gh version 2.100.0",
      }),
      undefined,
    );
  });
  it("does not let result text alone grant a probe without the command (spoof pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "cat notes.md" },
        result: "run gh --version: FOUND",
      }),
      undefined,
    );
  });
  it("does not let a text search fake executable discovery (rg pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "rg which gh docs" },
        result: "docs/notes.md: try which gh",
      }),
      undefined,
    );
  });
  it("does not let a text search fake a known-location check (grep pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "grep gh.exe notes.md" },
        result: "notes.md: install gh.exe from the tools dir",
      }),
      undefined,
    );
  });
  it("does not let a text search fake capability verification (rg pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "rg gh --version docs" },
        result: "docs/run.md: run gh --version",
      }),
      undefined,
    );
  });
  it("does not let a chained text search count (chain pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "echo checking && rg gh --version docs" },
        result: "docs/run.md: run gh --version",
      }),
      undefined,
    );
  });
  it("does not execute probes hidden inside quotes (quote pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: 'echo "a;which gh"' },
        result: "a;which gh",
      }),
      undefined,
    );
  });
  it("counts a real probe even when chained with a documentary step", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which gh && echo done" },
        result: "FOUND",
      }),
      "executable_discovery",
    );
  });
  it("counts a PowerShell call-operator invocation as the real executable", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: '& "C:\\fakedir\\gh.exe" --version' },
        result: "gh version 2.100.0",
      }),
      "capability_verification",
    );
  });
});

describe("classifyCompletedProbe wrong_profile:browser_claw", () => {
  const incident: IncidentId = "wrong_profile:browser_claw";
  it("labels resolved-config inspection", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "cat fake-openclaw.json" },
        result: "Config: C:\\fake\\.openclaw-claw\\openclaw.json",
      }),
      "resolved_config",
    );
  });
  it("labels a retry with the correct browser profile", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "openclaw browser --browser-profile claw tabs --json" },
        result: '{"tabs":[]}',
      }),
      "profile_retry",
    );
  });
  it("labels a browser-tool capability check", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "browser",
        args: { action: "tabs" },
        result: { tabs: [] },
      }),
      "browser_capability",
    );
  });
  it("does not grant a capability probe from result text alone (spoof pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "browser",
        args: { note: "hello" },
        result: "tabs list: 4 open tabs",
      }),
      undefined,
    );
  });
  it("does not let a text search fake a profile retry (rg pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "rg --browser-profile claw docs" },
        result: "docs/skill.md: use --browser-profile claw",
      }),
      undefined,
    );
  });
  it("does not let a text search fake resolved-config inspection (rg pin)", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "rg openclaw.json docs" },
        result: "docs/skill.md: Config: openclaw.json",
      }),
      undefined,
    );
  });
  it("does not count an unrelated gh probe for the browser incident", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "which gh" },
        result: "FOUND",
      }),
      undefined,
    );
  });
});

describe("classifyCompletedProbe session_scope:sessions_search", () => {
  const incident: IncidentId = "session_scope:sessions_search";
  it("labels an explicit agentId retry", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "sessions_search",
        args: { agentId: "verifier", query: "census" },
        result: { results: [] },
      }),
      "explicit_agent_scope",
    );
  });
  it("labels an explicit sessionKeys retry", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "sessions_search",
        args: { query: "census", sessionKeys: ["agent:verifier:main"] },
        result: { results: [] },
      }),
      "explicit_session_scope",
    );
  });
  it("labels a scoped retry that still hits a database fault", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "sessions_search",
        args: { agentId: "verifier", sessionKeys: ["agent:verifier:main"], query: "census" },
        result: { status: "error", error: "ERR_SQLITE_ERROR: unable to open database file" },
      }),
      "database_fault_check",
    );
  });
  it("does not count the original unscoped failing call as a probe", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "sessions_search",
        args: { query: "census" },
        isError: true,
        result: { status: "error", error: "unable to open database file" },
      }),
      undefined,
    );
  });
  it("labels a sqlite inspection command as a database fault check", () => {
    assert.equal(
      classifyCompletedProbe(incident, {
        toolName: "exec",
        args: { command: "sqlite3 sessions.db integrity_check" },
        result: "ok",
      }),
      "database_fault_check",
    );
  });
});

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

describe("reduceDiagnosticState", () => {
  it("creates state with the three gh categories", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    assert.deepEqual(s.requiredCategories, [
      "executable_discovery",
      "known_install_location",
      "capability_verification",
    ]);
    assert.deepEqual(s.completedCategories, []);
    assert.equal(s.revisionRequested, false);
    assert.equal(s.version, 1);
  });
  it("creates state with the three browser categories", () => {
    const s = reduceDiagnosticState(undefined, "wrong_profile:browser_claw");
    assert.deepEqual(s.requiredCategories, ["resolved_config", "profile_retry", "browser_capability"]);
  });
  it("creates state with the three session categories", () => {
    const s = reduceDiagnosticState(undefined, "session_scope:sessions_search");
    assert.deepEqual(s.requiredCategories, [
      "explicit_agent_scope",
      "explicit_session_scope",
      "database_fault_check",
    ]);
  });
  it("advances on a new relevant category", () => {
    let s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    s = reduceDiagnosticState(s, "path_miss:gh_cli", "executable_discovery");
    assert.deepEqual(s.completedCategories, ["executable_discovery"]);
  });
  it("does not advance on a repeated category (dedup mutation pin)", () => {
    let s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    s = reduceDiagnosticState(s, "path_miss:gh_cli", "executable_discovery");
    s = reduceDiagnosticState(s, "path_miss:gh_cli", "executable_discovery");
    assert.deepEqual(s.completedCategories, ["executable_discovery"]);
  });
  it("does not advance on a category from another incident", () => {
    let s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    s = reduceDiagnosticState(s, "path_miss:gh_cli", "profile_retry");
    assert.deepEqual(s.completedCategories, []);
  });
  it("keeps the first incident when a different one arrives", () => {
    let s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    s = reduceDiagnosticState(s, "wrong_profile:browser_claw", "resolved_config");
    assert.equal(s.incidentId, "path_miss:gh_cli");
    assert.deepEqual(s.completedCategories, []);
  });
  it("contains only the five DiagnosticState keys (privacy pin)", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli", "executable_discovery");
    assert.deepEqual(Object.keys(s).sort(), [
      "completedCategories",
      "incidentId",
      "requiredCategories",
      "revisionRequested",
      "version",
    ]);
  });
});

// ---------------------------------------------------------------------------
// Static contract
// ---------------------------------------------------------------------------

describe("buildDiagnosticContract", () => {
  it("wraps guidance in the diagnostic-contract tags with the incident id", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    const c = buildDiagnosticContract(s);
    assert.match(c, /<diagnostic-contract incident="path_miss:gh_cli">/);
    assert.match(c, /<\/diagnostic-contract>/);
  });
  it("states the failure proves only that path failed", () => {
    const s = reduceDiagnosticState(undefined, "wrong_profile:browser_claw");
    assert.match(buildDiagnosticContract(s), /proves only that (attempted )?path failed/i);
  });
  it("lists remaining symbolic categories and forbids repeats of side effects", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli", "executable_discovery");
    const c = buildDiagnosticContract(s);
    assert.ok(c.includes("known_install_location"));
    assert.ok(c.includes("capability_verification"));
    assert.ok(!c.includes("executable_discovery") || c.includes("completed"));
    assert.match(c, /do not repeat external/i);
  });
  it("never interpolates observed values (privacy mutation pin)", () => {
    const canary = "canary-token-9f27c1";
    const obs: DiagnosticObservation = {
      toolName: "exec",
      args: { command: `gh auth --with-token ${canary}` },
      isError: true,
      result: `token ${canary} rejected`,
    };
    const incident = classifyIncident(obs);
    assert.equal(incident, undefined); // sanity: token probe is not a path miss
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    const c = buildDiagnosticContract(s);
    assert.ok(!c.includes(canary), "contract leaked observed content");
  });
  it("prescribes the ordered five-step gh recovery with the fixed known path", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    const c = buildDiagnosticContract(s);
    const exe = "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe";
    assert.ok(c.includes(exe), "contract must name the fixed known gh.exe path");
    const steps = [
      /executable inventory/i,
      /known location/i,
      /--version/i,
      /auth\/capability|capability.*auth/i,
      /NOT_FOUND_AFTER_CHECKS/,
    ];
    let last = -1;
    for (const re of steps) {
      const at = c.search(re);
      assert.ok(at > last, `gh recovery step out of order or missing: ${re}`);
      last = at;
    }
    for (const label of ["NOT_FOUND_AFTER_CHECKS", "DENIED", "AUTH_FAILED", "WRONG_HOST"]) {
      assert.ok(c.includes(label), `contract must name terminal label ${label}`);
    }
  });
  it("does not reuse the observer broad incapacity regex", () => {
    const src = readFileSync(new URL("./diagnostic-guard.ts", import.meta.url), "utf8");
    assert.ok(!src.includes("INCAPACITY_RE"), "must not reuse observer.ts INCAPACITY_RE");
    assert.ok(!src.includes("./observer"), "must not import observer.ts");
  });
});

// ---------------------------------------------------------------------------
// Task-level incapacity + revision predicate
// ---------------------------------------------------------------------------

describe("isTaskLevelIncapacity", () => {
  it("matches a first-person run-scoped inability as the principal conclusion", () => {
    assert.equal(isTaskLevelIncapacity("I cannot access GitHub in this run."), true);
  });
  it("matches an unavailable-capability conclusion in the final paragraph", () => {
    assert.equal(
      isTaskLevelIncapacity(
        "I checked the PATH and the known install location.\n\nThe capability is unavailable in this run.",
      ),
      true,
    );
  });
  it("does not match a quoted error", () => {
    assert.equal(
      isTaskLevelIncapacity('The tool said "I cannot access GitHub in this run"; I will verify the binary path next.'),
      false,
    );
  });
  it("does not match historical discussion", () => {
    assert.equal(
      isTaskLevelIncapacity(
        "Earlier the agent wrote that the capability is unavailable in this run, but that was before the PATH fix. I will inspect another path now.",
      ),
      false,
    );
  });
  it("does not match a reviewer finding", () => {
    assert.equal(
      isTaskLevelIncapacity(
        "Reviewer notes the report claims the capability is unavailable; my own checks are still running.",
      ),
      false,
    );
  });
  it("does not match a first failure followed by a next step", () => {
    assert.equal(
      isTaskLevelIncapacity("The first method failed; I will inspect another path."),
      false,
    );
  });
  it("matches the originating Spanish denial: no access", () => {
    assert.equal(isTaskLevelIncapacity("No tengo acceso a GitHub en esta corrida."), true);
  });
  it("matches the originating Spanish denial: capability unavailable", () => {
    assert.equal(
      isTaskLevelIncapacity("La capacidad no está disponible en este run."),
      true,
    );
  });
  it("does not match a Spanish reviewer attribution", () => {
    assert.equal(
      isTaskLevelIncapacity(
        "El revisor señala que la capacidad no está disponible; mis verificaciones siguen en curso.",
      ),
      false,
    );
  });
});

describe("shouldRequestRevision", () => {
  const incapacity = "I cannot access GitHub in this run.";
  it("requests when fewer than three categories completed and no revision yet", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli", "executable_discovery");
    assert.equal(shouldRequestRevision(s, incapacity), true);
  });
  it("refuses after three distinct categories", () => {
    let s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    for (const c of ["executable_discovery", "known_install_location", "capability_verification"] as const) {
      s = reduceDiagnosticState(s, "path_miss:gh_cli", c);
    }
    assert.equal(shouldRequestRevision(s, incapacity), false);
  });
  it("refuses when a revision was already requested", () => {
    const s = { ...reduceDiagnosticState(undefined, "path_miss:gh_cli"), revisionRequested: true };
    assert.equal(shouldRequestRevision(s, incapacity), false);
  });
  it("refuses without a task-level incapacity conclusion", () => {
    const s = reduceDiagnosticState(undefined, "path_miss:gh_cli");
    assert.equal(shouldRequestRevision(s, "The first method failed; I will inspect another path."), false);
  });
  it("counts distinct categories only: triplicated one still revises (dup pin)", () => {
    const s = {
      version: 1 as const,
      incidentId: "path_miss:gh_cli" as const,
      requiredCategories: [
        "executable_discovery",
        "known_install_location",
        "capability_verification",
      ] as DiagnosticState["requiredCategories"],
      completedCategories: [
        "executable_discovery",
        "executable_discovery",
        "executable_discovery",
      ] as DiagnosticState["completedCategories"],
      revisionRequested: false,
    };
    assert.equal(shouldRequestRevision(s, incapacity), true);
  });
});

describe("parseDiagnosticConfig", () => {
  it("defaults to observe with 3 categories and 1 attempt", () => {
    assert.deepEqual(parseDiagnosticConfig(undefined), {
      mode: "observe",
      requiredProbeCategories: 3,
      maxRevisionAttempts: 1,
    });
  });
  it("honors explicit enforce and off", () => {
    assert.equal(parseDiagnosticConfig({ diagnosticGuard: { mode: "enforce" } }).mode, "enforce");
    assert.equal(parseDiagnosticConfig({ mode: "off" }).mode, "off");
  });
  it("falls back to observe on unknown modes and pins counts", () => {
    const c = parseDiagnosticConfig({ mode: "block", requiredProbeCategories: 9, maxRevisionAttempts: 5 });
    assert.deepEqual(c, { mode: "observe", requiredProbeCategories: 3, maxRevisionAttempts: 1 });
  });
});
