---
name: PR sin gh
description: Cuando la tarea exige abrir un PR en GitHub y el nodo no tiene gh. Crea el PR via API con la credencial de git ya almacenada, sin imprimir jamas el token.
---

# PR sin gh

## Pasos

1. Confirma que gh falta: `which gh` termina en exit 1. No instales nada.
2. Lee la credencial almacenada de git SIN mostrarla, con
   `GIT_TERMINAL_PROMPT=0` para que falle en vez de colgarse a preguntar:

   `TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill | grep '^password=' | cut -d= -f2-)`

3. Crea el PR con curl: header `Authorization: token ***`,
   POST `https://api.github.com/repos/<owner>/<repo>/pulls` con cuerpo
   JSON `{title, head, base, body}`; guarda la respuesta con `-o` y
   reporta solo el codigo HTTP y el `html_url`.
   - 201 -> PR creado: reporta el link.
   - 401/403/422 -> la credencial no alcanza para crear PRs: declaralo y
     entrega la URL `https://github.com/<owner>/<repo>/pull/new/<branch>`
     que el propio `git push` ya imprimio.
4. El token vive solo en la variable del proceso: nunca a stdout, logs ni
   chat. Si el paso 2 devuelve vacio, declara el bloqueo; no inventes
   otra fuente de credenciales.

## Criterio de cierre

HTTP 201 con `html_url` del PR, o bloqueo declarado con la URL manual de
creacion.
