// Drive del merge-guard por el hook REGISTRADO, no llamando a la funcion.
// Mismo patron que role.test.ts: se registra el plugin real contra un host
// falso y se dispara el hook que quedo registrado.
import mod from "../../../summa-gate/index.ts";

type Reg = { event: string; handler: Function; opts?: { matcher?: string[] } };
const regs: Reg[] = [];
const noop = () => {};
const store = new Map<string, unknown>();

const api = {
  logger: { info: noop, warn: noop, error: noop, debug: noop },
  on(event: string, handler: Function, opts?: { matcher?: string[] }) {
    regs.push({ event, handler, opts });
  },
  runtime: {
    middleware: { register: noop },
    runContext: {
      get: (runId: string, ns: string) => store.get(`${runId}:${ns}`),
      set: (runId: string, ns: string, v: unknown) => store.set(`${runId}:${ns}`, v),
    },
  },
};

mod.register(api as never);

const hook = regs.find(
  (r) => r.event === "before_tool_call" && r.opts?.matcher?.includes("exec"),
);
if (!hook) {
  console.log("ATORADO: el merge-guard no quedo registrado en before_tool_call/exec");
  process.exit(1);
}

const casos: Array<[string, string, boolean]> = [
  ["subcomando de merge de la CLI", "gh pr merge 12 -R o/r --squash", true],
  ["misma orden encadenada", "echo hola && gh pr merge 12", true],
  ["push a rama protegida", "git push origin main", true],
  ["ruta de merge de la API", "gh api repos/o/r/pulls/1/merge -X PUT", true],
  ["push a rama de trabajo", "git push origin feature/x", false],
  ["lectura inofensiva", "gh pr view 12 --json state", false],
];

let fallas = 0;
for (const [nombre, comando, debeBloquear] of casos) {
  const r = hook.handler(
    { toolName: "exec", params: { command: comando } },
    { agentId: "main", sessionKey: "agent:main:verify" },
  ) as { block?: boolean; blockReason?: string } | undefined;
  const bloqueo = r?.block === true;
  const ok = bloqueo === debeBloquear;
  if (!ok) fallas++;
  console.log(`${ok ? "OK " : "FALLA"}  ${debeBloquear ? "bloquea" : "pasa   "}  ${nombre}`);
  console.log(`        comando: ${comando}`);
  if (bloqueo) console.log(`        mensaje: ${r?.blockReason}`);
}

console.log(fallas === 0 ? "\nDRIVE VERDE: 6 casos, 4 bloqueados y 2 permitidos" : `\nDRIVE ROJO: ${fallas} casos`);
process.exit(fallas === 0 ? 0 : 1);
