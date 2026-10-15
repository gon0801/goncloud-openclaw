# poteto en un encargo por CLI

Este encargo trae poteto: la skill `poteto-mode` con sus playbooks y references, y las `principle-*`. Están en la carpeta `skills` que está junto a este archivo, dentro de la carpeta de la corrida. Antes de usar otra herramienta, carga `poteto-mode` con la herramienta `skill` y sigue su playbook. Un playbook o una reference se abren con `read` en su ruta dentro de esa carpeta.

Lo que poteto nombra, aquí:

- La lista de pasos del playbook es `todowrite`. Su primer elemento es el primer paso del playbook, con sus palabras.
- Delegar es `task`, con los agentes que esta corrida deja. Todos corren el modelo de este encargo: la diversidad de modelos de un panel se reduce a uno.
- Correr pruebas y comandos es `bash`. Editar es `edit` o `write`, solo si tu perfil escribe fuente.
- Una skill que no está en esa carpeta no está disponible en este encargo. Si poteto pide una, dilo en el resultado y sigue sin ella.
- Las reglas de modelos y de agentes de `~/.config/opencode/AGENTS.md` no valen en un encargo: el modelo lo eligió el host. No pidas otro.
