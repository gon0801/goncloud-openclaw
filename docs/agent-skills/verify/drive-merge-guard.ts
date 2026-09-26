// Drive del merge-guard por el hook REGISTRADO, no llamando a la funcion.
// Mismo patron que role.test.ts: se registra el plugin real contra un host
// falso y se dispara el hook que quedo registrado.
//
// Historia: hasta a088618 (#159, 2026-09-24) existia un merge-guard con
// allowlist por rol; ese commit lo retiro y hoy ningun comando de merge, push o
// deploy se intercepta. Los diez casos de abajo esperan todos `false` (pasa):
// cubren los patrones que el guardia retirado bloqueaba, para que una regresion
// que lo reintroduzca quede en rojo.
import mod from "../../../summa-gate/index.ts";

type Reg = { event: string; handler: Function; opts?: { matcher?: string[] } };
const regs: Reg[] = [];
const noop = () => {};
const store = new Map<string, unknown>();

// Host falso con la forma de fakeBaseApi (summa-gate/role.test.ts:24-48): los
// campos que el plugin lee van AL TOPE del api (logger, on,
// registerAgentToolResultMiddleware, pluginConfig) y runContext anidado bajo
// `runContext`, NO bajo `runtime` — anidado bajo runtime el registro "funciona"
// y el hook que uno queria simplemente no queda en la lista.
const api = {
  logger: { info: noop, warn: noop, error: noop, debug: noop },
  on(event: string, handler: Function, opts?: { matcher?: string[] }) {
    regs.push({ event, handler, opts });
  },
  registerAgentToolResultMiddleware: noop,
  runContext: {
    setRunContext: ({ runId, namespace, value }: { runId: string; namespace: string; value: unknown }) => {
      store.set(`${runId}:${namespace}`, value);
      return true;
    },
    getRunContext: ({ runId, namespace }: { runId: string; namespace: string }) =>
      store.get(`${runId}:${namespace}`),
    clearRunContext: ({ runId, namespace }: { runId: string; namespace?: string }) => {
      if (namespace) store.delete(`${runId}:${namespace}`);
    },
  },
  pluginConfig: {},
};

mod.register(api as never);

const hooks = regs.filter(r => r.event === "before_tool_call" && (!r.opts?.matcher || r.opts.matcher.includes("exec")));

// [nombre, comando, debeBloquear, agentId] — agentId undefined = turno sin
// agentId; desde a088618 todo pasa, con o sin rol.
const casos: Array<[string, string, boolean, string | undefined]> = [
  ["subcomando de merge de la CLI", "gh pr merge 12 -R o/r --squash", false, "main"],
  ["misma orden encadenada", "echo hola && gh pr merge 12", false, "main"],
  ["push a rama protegida", "git push origin main", false, "main"],
  ["ruta de merge de la API", "gh api repos/o/r/pulls/1/merge -X PUT", false, "main"],
  ["push a rama de trabajo", "git push origin feature/x", false, "main"],
  ["lectura inofensiva", "gh pr view 12 --json state", false, "main"],
  ["guard no intercepta (implementer)", "gh api repos/o/r/pulls/1/merge -X PUT", false, "implementer"],
  ["guard no intercepta (ingenieria)", "gh api repos/o/r/pulls/1/merge -X PUT", false, "ingenieria"],
  ["guard no intercepta (verifier)", "gh api repos/o/r/pulls/1/merge -X PUT", false, "verifier"],
  ["guard no intercepta (sin agentId)", "gh api repos/o/r/pulls/1/merge -X PUT", false, undefined],
];

let fallas = 0;
for (const [nombre, comando, debeBloquear, agentId] of casos) {
  const ctx = agentId === undefined
    ? { sessionKey: "agent:main:verify" }
    : { agentId, sessionKey: "agent:main:verify" };
  const r = hooks.map(hook => hook.handler(
    { toolName: "exec", params: { command: comando } },
    ctx,
  ) as { block?: boolean; blockReason?: string } | undefined).find(result => result?.block);
  const bloqueo = r?.block === true;
  const ok = bloqueo === debeBloquear;
  if (!ok) fallas++;
  console.log(`${ok ? "OK " : "FALLA"}  ${debeBloquear ? "bloquea" : "pasa   "}  ${nombre}  (agentId: ${agentId ?? "ausente"})`);
  console.log(`        comando: ${comando}`);
  if (bloqueo) console.log(`        mensaje: ${r?.blockReason}`);
}

const bloqueados = casos.filter((c) => c[2]).length;
console.log(
  fallas === 0
    ? `\nDRIVE VERDE: ${casos.length} casos, ${bloqueados} bloqueados y ${casos.length - bloqueados} permitidos`
    : `\nDRIVE ROJO: ${fallas} caso(s) de ${casos.length}`,
);
process.exit(fallas === 0 ? 0 : 1);
