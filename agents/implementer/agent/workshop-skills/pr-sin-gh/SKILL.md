---
name: PR sin gh
description: Cuando la tarea exige abrir un PR en GitHub y gh no aparece en el PATH (en la Mac primero verifica /opt/homebrew/bin/gh; solo sin el vas por API). Crea el PR via API con la credencial de git ya almacenada, sin imprimir jamas el token.
---

# PR sin gh

## Pasos

1. Confirma que gh falta DE VERDAD: en el nodo Mac `which gh` falla por el PATH restringido aunque gh exista; proba primero `/opt/homebrew/bin/gh --version` (el PATH del nodo lo
   oculta aunque exista; medido funcionando en la Mac del operador, PRs #292/#2833 —
   tabla en mac-exec-detach-poll/ENV.md). Solo si falta en ambas vias segui con la API. No instales nada.
2. Lee la credencial almacenada de git SIN mostrarla, con
   `GIT_TERMINAL_PROMPT=0` para que falle en vez de colgarse a preguntar:

   `TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill | grep '^password=' | cut -d= -f2-)`

3. Crea el PR con curl: header `Authorization: token ***`,
   POST `https://api.github.com/repos/<owner>/<repo>/pulls` con cuerpo
   JSON `{title, head, base, body}`; guarda la respuesta con `-o` y
   reporta solo el codigo HTTP y el `html_url`.
   - 201 -> PR creado: reporta el link.
   - 401/403 -> la credencial no alcanza para crear PRs: declaralo y
     entrega la URL `https://github.com/<owner>/<repo>/pull/new/<branch>`
     que el propio `git push` ya imprimio. El token puede ROTAR a mitad
     de sesion (401 "Bad credentials" con `git push` siguiendo vivo,
     medido en 20.20): para vigilar el CI de un repo PUBLICO no hace
     falta token, el endpoint `commits/<sha>/check-runs` responde sin
     autenticacion.
   - 422 -> lee el `message` del cuerpo guardado con `-o`: si dice
     "A pull request already exists", la tarea ya esta cumplida, reporta
     el PR existente (GET `/repos/<owner>/<repo>/pulls?head=<owner>:<branch>`);
     si no, es fallo de validacion o permisos: declara y entrega la URL
     manual.
   - Cuerpo largo o con comillas: escribelo a archivo con heredoc y pasa
     `-d @<archivo>`; y respeta la estructura `TOKEN=$(printf ...)`: un
     parentesis huerfano en esa asignacion da syntax error antes de
     ejecutar nada (medido en summonaikit 20.20).
4. El token vive solo en la variable del proceso: nunca a stdout, logs ni
   chat. Si el paso 2 devuelve vacio, declara el bloqueo; no inventes
   otra fuente de credenciales.

## Criterio de cierre

HTTP 201 con `html_url` del PR, o bloqueo declarado con la URL manual de
creacion.
