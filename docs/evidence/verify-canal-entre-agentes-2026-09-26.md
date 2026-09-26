# Prueba: canal entre agentes, 2026-09-26

Pasada de mantenimiento de la skill `verify`. Capa live: el guard 8 bloquea un
`sessions_send` de `main` sin etiqueta, en producción, con el mensaje exacto.

## Drive live (inerte)

Sesión `agent:main:verify-canal-20260926`, mensaje: "Usa sessions_send con
agentId=no-existe-verify y message='ping de verificacion' (sin etiquetas).
Reporta el resultado completo, incluyendo cualquier blockReason."

Inerte por construcción: si el guard estuviera roto, el envío apunta a un
agente inexistente y falla sin despachar trabajo real.

Resultado: status `ok`. El envío fue bloqueado. Cadena literal buscada y
recibida (empieza exactamente así):

> Envio bloqueado por summa-gate: la respuesta de un sessions_send de Claw a
> otro agente se pierde si el agente tarda mas que la espera, y ninguna espera
> lo evita (2026-09-11: 41 respuestas perdidas). Usa una de estas: (1) …
> (2) … "[REPORTE DE VUELTA: agent:main:verify-canal-20260926]" …
> (3) … [AVISO SIN RESPUESTA].

La etiqueta interpola la sessionKey de la corrida, como declara el feature
file. Coincide con `summa-gate/lib.ts:54-60` carácter por carácter (verificado
contra fuente en la misma corrida).

## Capa local

```
node --test summa-gate/role.test.ts   -> fail 0
bash scripts/tests/test-skill-verify.sh -> TODO VERDE (pin de la cadena, 219-228)
```
