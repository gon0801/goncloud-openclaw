// Confinamiento del agente `adversary`, probado por el hook REGISTRADO.
//
// Por que existe este archivo: hasta 2026-09-16 este guardia no tenia NINGUNA
// prueba. Ni la funcion ni el hook. Por eso sobrevivio el hueco que cierra este
// mismo cambio: la rama de `exec` saltaba todo destino relativo antes de
// validarlo, con el comentario "relativos: dentro del workspace", que es una
// suposicion y no un hecho. `../../outside` es relativo y sale de la zona.
//
// Un guardia de confinamiento sin prueba es una promesa, no un control.
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import mod from "./index.ts";

type FakeHook = (event: unknown, ctx: unknown) => unknown;
type Reg = { event: string; handler: FakeHook; opts?: { matcher?: string[] } };

// Misma forma que `fakeBaseApi` de role.test.ts: los campos que el plugin lee
// van en el nivel superior, no bajo `runtime`. Un falso sin `pluginConfig`
// registra igual y deja el hook que buscas fuera de la lista, sin decirlo.
function fakeBaseApi(regs: Reg[]) {
  const noop = () => {};
  const store = new Map<string, unknown>();
  return {
    logger: { info: noop, warn: noop, error: noop, debug: noop },
    on: (event: string, handler: FakeHook, opts?: { matcher?: string[] }) => {
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
}

const WS = "/tmp/ws-adversary";

// Dos trampas al manejar este evento, las dos costaron una vuelta al escribir
// esto:
//
// 1. `before_tool_call` tiene VARIOS hooks. Tomar el primero con `.find()`
//    prueba el merge-guard y todo sale sin bloquear, que parece un fallo del
//    confinamiento y no lo es.
// 2. El confinamiento se registra **sin matcher** y filtra por dentro con
//    `event.toolName`. Filtrar por `matcher: ["exec"]` lo deja fuera y solo
//    encuentra el merge-guard.
//
// Y hay una tercera, la contraria: correr TODOS los hooks del evento tampoco es
// simular al host. El guardia del canal entre agentes se registra con matcher
// `sessions_send`, y llamarlo con un `exec` lo hace bloquear por una razon que
// nada tiene que ver, lo que se lee como que el confinamiento toca a otros
// agentes. El host llama solo a los hooks cuyo matcher incluye la herramienta,
// mas los que no declaran matcher. Eso es lo que hace esto.
function execHook() {
  const regs: Reg[] = [];
  mod.register(fakeBaseApi(regs) as never);
  const hs = regs.filter(
    (r) =>
      r.event === "before_tool_call" &&
      (r.opts?.matcher === undefined || r.opts.matcher.includes("exec")),
  );
  assert.ok(hs.length >= 2, `esperaba al menos 2 hooks para exec, hay ${hs.length}`);
  return (command: string, agentId = "adversary") => {
    for (const h of hs) {
      const r = h.handler({ toolName: "exec", params: { command } }, { agentId, workspaceDir: WS }) as
        | { block?: boolean; blockReason?: string }
        | undefined;
      if (r?.block) return r;
    }
    return undefined;
  };
}

describe("confinamiento adversary: redirecciones por exec", () => {
  it("bloquea una redireccion relativa que sale del workspace", () => {
    // El caso que el guardia dejaba pasar. Es relativo, asi que la version
    // vieja hacia `continue` antes de mirarlo, y escribia fuera de la zona.
    const r = execHook()("printf x > ../../outside");
    assert.equal(r?.block, true, "una redireccion relativa que escapa debe bloquear");
    assert.match(r?.blockReason ?? "", /Confinamiento adversary/);
    assert.match(r?.blockReason ?? "", /\.\.\/\.\.\/outside/, "el mensaje nombra el destino");
  });

  it("bloquea tambien con mas saltos y con ./ de por medio", () => {
    for (const cmd of ["echo x > ./../../fuera", "cat a > ../../../etc/passwd"]) {
      assert.equal(execHook()(cmd)?.block, true, `deberia bloquear: ${cmd}`);
    }
  });

  it("deja pasar una redireccion relativa que se queda dentro", () => {
    // El otro lado: si solo bloqueara, el guardia seria inutil igual.
    for (const cmd of ["printf x > notas.txt", "echo y > sub/dir/out.log", "echo z > ./out"]) {
      assert.equal(execHook()(cmd)?.block, undefined, `no deberia bloquear: ${cmd}`);
    }
  });

  it("sigue bloqueando el absoluto fuera de zona", () => {
    const r = execHook()("printf x > /etc/passwd");
    assert.equal(r?.block, true);
  });

  it("deja pasar el absoluto dentro del workspace y la zona de hallazgos", () => {
    assert.equal(execHook()(`printf x > ${WS}/nota.txt`)?.block, undefined);
    assert.equal(execHook()("printf x > .saikit/findings/blast.json")?.block, undefined);
    assert.equal(execHook()("printf x > .saikit/scratch/tmp.txt")?.block, undefined);
  });

  it("deja pasar los destinos que no son archivos", () => {
    for (const cmd of ["ruido > /dev/null", "ruido > /dev/stderr", "ruido 2> /dev/stdout"]) {
      assert.equal(execHook()(cmd)?.block, undefined, `no deberia bloquear: ${cmd}`);
    }
  });

  it("bloquea el relativo cuando el comando cambia de directorio", () => {
    // El bypass que abrio el primer arreglo: el shell corre el `cd` antes de la
    // redireccion, asi que `outside` no es del workspace aunque lo parezca.
    for (const cmd of [
      "cd .. && printf x > outside",
      "pushd /tmp; echo x > fuera",
      "cd sub && printf x > notas.txt",
    ]) {
      const r = execHook()(cmd);
      assert.equal(r?.block, true, `deberia bloquear: ${cmd}`);
      assert.match(r?.blockReason ?? "", /cambia de directorio/);
    }
  });

  it("con cambio de directorio, el absoluto dentro de zona sigue pasando", () => {
    // El absoluto no depende del cwd, asi que el `cd` no lo vuelve ambiguo.
    assert.equal(execHook()(`cd /tmp && printf x > ${WS}/nota.txt`)?.block, undefined);
  });

  it("no toca a ningun otro agente", () => {
    // El guardia esta atado al id. Sin esta prueba, un cambio que lo desate
    // pasaria desapercibido porque todo lo demas seguiria en verde.
    for (const id of ["main", "implementer", "ingenieria"]) {
      assert.equal(
        execHook()("printf x > ../../outside", id)?.block,
        undefined,
        `no deberia tocar a ${id}`,
      );
    }
  });
});
