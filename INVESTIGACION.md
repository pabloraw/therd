# therd: vista de chat para Claude Code en herdr

Investigación previa (17-11-2026) para una app Flutter que haga lo mismo que la *Chat View* de Moshi,
pero solo para **Claude Code** dentro de **herdr**, sin terminal y basada en **hooks**.

Entorno comprobado en esta máquina: Claude Code 2.1.326, herdr 0.9.5 (protocolo de API 22),
moshi-hook 0.4.58, Flutter 3.38.7 y Tailscale con el Pixel en la tailnet.

---

## 1. Resumen ejecutivo

- **Es viable y bastante más simple que Moshi.** Moshi es un terminal SSH/mosh completo con
  unos 20 agentes, 3 multiplexores, Watch, Siri, simuladores, dictado, E2EE… La Chat View es una
  capa *experimental* encima de todo eso. Nosotros solo necesitamos esa capa.
- **Tres fuentes de datos, cada una para lo suyo:**
  1. **Hooks de Claude Code** (tipo `http`) dan los eventos y, sobre todo, el **control**:
     aprobar permisos y responder a `AskUserQuestion` desde el móvil.
  2. **El transcript JSONL** da el **contenido** (texto intermedio, thinking, tool calls y sus
     resultados). Los hooks por sí solos no traen el texto que Claude escribe entre herramientas.
  3. **La API por socket de herdr** da el **inventario de sesiones**, el **estado**
     (working/idle/blocked) y la **entrada**: enviar prompts (`agent.prompt`) y teclas (`Esc`).
- **Arquitectura:** un daemon pequeño en el PC (`therd`) que junta las tres fuentes y expone un
  WebSocket por Tailscale; la app Flutter es solo un cliente de ese WebSocket.
- **"Basado en hooks", con matiz:** los hooks son el disparador y el canal de control; el
  transcript es inevitable para el contenido completo (Moshi hace lo mismo: el hook mapea
  pane→sesión y el gateway sirve el transcript). Se puede evaluar `MessageDisplay` para depender
  menos del JSONL (ver §3.5).

---

## 2. Qué hace Moshi (y qué copiamos)

Fuente: docs oficiales (getmoshi.app/docs/chat-view, /agent-hooks, /debug-chat-view, /herdr) y
lo instalado en esta máquina.

### 2.1 Chat View: qué muestra

- Cabecera con agente, sesión del multiplexor y modelo.
- Prompts y respuestas en Markdown (código, imágenes, bloques de *thinking*).
- **Tool cards**: shell, lecturas y ediciones de archivo, grupos de tareas, mini diffs,
  resultados y fallos; se expanden al tocar.
- Indicador *Working* con botón **Stop**.
- Pestañas de solo lectura para subagentes (desaparecen 30 s tras terminar).
- Marcador *Conversation compacted*.
- Visuales inline (gráficos, diagramas) mediante un skill `moshi-visuals` que inyecta.

### 2.2 Chat View: cómo responde el usuario

- **Barra de aprobación** Approve/Deny; al tocar se ve el comando y el motivo completos.
- **Planes** (ExitPlanMode) como tarjeta Markdown.
- **Preguntas estructuradas** (AskUserQuestion) con opciones y respuesta libre.
- El Stop sobre una pregunta la descarta e interrumpe el turno.
- Prompts enviados con una pregunta pendiente se retienen hasta contestarla.
- Composer con texto, dictado e imágenes.
- *Rewind* a un prompt anterior (solo Claude Code).

### 2.3 Cómo lo hace por dentro

- **`moshi-hook`**: daemon Go cerrado con socket Unix local, WebSocket a la nube de Moshi (para
  push y aprobaciones) y un **gateway HTTP/WS en `127.0.0.1:24543`** al que la app llega por un
  túnel SSH desde la sesión de terminal abierta.
- Chat View: el gateway inspecciona el pane de tmux/herdr, usa el **mapeo pane→sesión que escribe
  el hook** (no adivina por "el transcript más reciente") y abre `/v1/transcripts` con un
  `backlog` inicial y luego mensajes `append`. Los transcripts van host→app directamente.
- Requisito: el agente debe estar dentro de tmux o herdr. En shell plano no hay chat.
- Límites que reconocen: tool cards a veces incompletas ("la salida del terminal es la
  autoridad") y aprobaciones que no se ofrecen cuando no pueden entregarse con seguridad.

### 2.4 Hooks que Moshi tenía instalados aquí (`~/.claude/settings.json`)

> **Histórico.** Moshi se desinstaló el 19-11-2026 y sus hooks ya no están. Esta tabla describe
> lo que había el 17-11. Sus hooks en `PreToolUse ExitPlanMode` impedían que llegara el
> `PermissionRequest` de los planes; `therd doctor` avisa si vuelven a aparecer.

Todos llamaban a `moshi-hook claude-hook`:

| Evento | Matcher | Modo |
|---|---|---|
| `SessionStart` | (todos) | async |
| `UserPromptSubmit` | | async |
| `PreToolUse` | `AskUserQuestion`, `ExitPlanMode` | async |
| `PostToolUse` | `AskUserQuestion`, `ExitPlanMode` | async |
| `PermissionRequest` | (todos) | **síncrono** (bloquea hasta decidir) |
| `Notification` | `permission_prompt` | async |
| `Stop` | | async |
| `SessionEnd` | | async |

Conclusiones: Moshi **no** engancha `PostToolUse` general (el contenido lo saca del transcript),
y la única pieza síncrona es `PermissionRequest`. Las preguntas las detecta por hook pero las
responde inyectando teclas en el terminal.

Además herdr tiene su propio hook (`~/.claude/hooks/herdr-agent-state.sh`, en `SessionStart`)
que llama a `pane.report_agent_session` con `session_id` y `transcript_path`. **Ese mapeo
pane↔sesión ya existe y lo podemos leer con `herdr agent list`.**

### 2.5 Qué recortamos

Fuera: SSH/mosh/ET, terminal, tmux/zellij, otros agentes, Watch, Siri, Live Activity, simuladores,
browser preview, escaneo de puertos, dictado multimotor, nube intermedia, E2EE, uso/cuotas,
skill de visuales. Dentro: lista de sesiones, chat, composer, Stop, aprobaciones, preguntas y
planes. Más adelante: diffs, imágenes, subagentes, rewind, push.

---

## 3. Claude Code: lo que nos dan los hooks

Fuente: https://code.claude.com/docs/en/hooks.md (consultada hoy).

### 3.1 Eventos útiles para nosotros

Campos comunes en todos: `session_id`, `transcript_path`, `cwd`, `permission_mode`,
`hook_event_name`, `prompt_id` (tras el primer prompt), y `agent_id`/`agent_type` dentro de
subagentes.

| Evento | Para qué lo usamos | Campos clave |
|---|---|---|
| `SessionStart` | alta de sesión | `source` (startup/resume/clear/compact/fork), `model`, `session_title` |
| `UserPromptSubmit` | burbuja del usuario al instante | `prompt` |
| `PreToolUse` | tarjeta "ejecutando…"; **responder AskUserQuestion** | `tool_name`, `tool_input`, `tool_use_id` |
| `PermissionRequest` | **aprobar/denegar desde el móvil** | `tool_name`, `tool_input`, `permission_suggestions` (sin `tool_use_id`) |
| `PostToolUse` | cerrar tarjeta con resultado | `tool_response`, `tool_use_id`, `duration_ms` |
| `PostToolUseFailure` | tarjeta en rojo | `error`, `is_interrupt` |
| `Notification` | aviso de bloqueo o inactividad | `message`, `notification_type` (`permission_prompt`, `idle_prompt`) |
| `MessageDisplay` | posible streaming de texto (por verificar) | `turn_id`, `message_id`, `index`, `final`, `delta` |
| `Stop` | fin de turno y texto final fiable | `last_assistant_message`, `background_tasks` |
| `StopFailure` | error de API | `error`, `last_assistant_message` |
| `SubagentStart`/`SubagentStop` | pestañas de subagentes | `agent_id`, `agent_type`, `agent_transcript_path` |
| `PreCompact`/`PostCompact` | marcador de compactación | `trigger`, `compact_summary` |
| `SessionEnd` | baja de sesión | `reason` |

### 3.2 Tipo de hook: `http` mejor que `command`

```json
{
  "type": "http",
  "url": "http://127.0.0.1:24600/hook",
  "timeout": 5,
  "headers": { "X-Herdr-Pane": "$HERDR_PANE_ID", "Authorization": "Bearer $THERD_TOKEN" },
  "allowedEnvVars": ["HERDR_PANE_ID", "THERD_TOKEN"]
}
```

- El cuerpo POST es el mismo JSON que llegaría por stdin. Sin procesos ni scripts por evento.
- La cabecera `X-Herdr-Pane` nos da el pane directamente (las variables de entorno de herdr
  existen dentro de la sesión de Claude), sin depender de `herdr agent list`.
- Respuesta: 2xx vacío = sin efecto; 2xx con JSON = decisión; error/timeout = no bloqueante
  (salvo `onFailure: "block"`, desde v2.1.295).
- `http` **no admite `async`**. Para los eventos de solo-espejo ponemos `timeout` corto y el
  daemon responde 204 al momento; si el daemon está caído, la conexión falla rápido y Claude
  sigue.

### 3.3 Aprobar permisos desde el móvil

El hook `PermissionRequest` puede **bloquear** hasta tener respuesta (timeout por defecto 600 s):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

- `deny` admite `message` (se le explica a Claude) e `interrupt`.
- `allow` admite `updatedInput` y `updatedPermissions` (p. ej. "permitir siempre" →
  `addRules` con `destination: "localSettings"`, reutilizando `permission_suggestions`).
- **Problema de diseño importante:** mientras el hook bloquea, el diálogo del terminal **no**
  aparece (solo sale si el hook vuelve sin decisión). Si bloqueamos siempre, en el PC no se
  puede aprobar. Solución propuesta:
  - Si **no hay ningún móvil conectado** al daemon, responder 204 al instante → diálogo normal
    en el terminal.
  - Si hay móvil, esperar hasta N segundos (configurable, p. ej. 120) y, si no contesta,
    devolver vacío → diálogo normal en el terminal.
  - Opcional: un botón en la app "contestar en el PC" que libera el hook.
- No usar `onFailure: "block"` aquí: si el daemon cae, preferimos el diálogo del terminal.

### 3.4 Responder AskUserQuestion

`PreToolUse` con matcher `AskUserQuestion`, devolviendo las preguntas originales más `answers`
(indexado por el texto de la pregunta):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": {
      "questions": [ { "question": "¿Qué framework?", "header": "Framework",
                       "options": [ { "label": "React", "description": "…" } ],
                       "multiSelect": false } ],
      "answers": { "¿Qué framework?": "React" }
    }
  }
}
```

Mismo patrón de espera que en §3.3: solo bloquear si hay móvil conectado, con timeout; si no,
vacío y la pregunta sale en el terminal. Esto es **mejor que Moshi**, que contesta inyectando
teclas.

`ExitPlanMode` llega como `PermissionRequest` (el plan va en `tool_input.plan`): se pinta como
tarjeta de plan con Aprobar/Rechazar (rechazar con `message` = feedback para Claude).

### 3.5 El hueco: texto intermedio

- `Stop.last_assistant_message` trae solo el **texto final** del turno (y la doc recomienda usar
  este campo, no el transcript, porque en el momento del Stop el JSONL puede no tener aún la
  última línea).
- El texto que Claude escribe **entre** herramientas y el *thinking* solo están en el transcript.
- `MessageDisplay` (con `delta`, `final`, `message_id`) pinta a streaming de texto, pero su
  semántica no está verificada. **Tarea de la fase 0: engancharlo y ver qué llega.** Si sirve,
  el transcript quedaría solo para el histórico (backlog) y los hooks cubrirían el directo.

### 3.6 Configuración

- `~/.claude/settings.json` (global) o un **plugin** con `hooks/hooks.json` (más limpio de
  instalar y desinstalar; recomendado).
- Matchers: nombre exacto, lista `A|B`, o regex sin anclar. `UserPromptSubmit` y `Stop` no
  admiten matcher.
- Timeouts por defecto: 600 s en general, 30 s en `UserPromptSubmit`, 10 s en `MessageDisplay`,
  1,5 s de presupuesto total en `SessionEnd`.
- **Coexistencia con Moshi (resuelto):** con los dos `PermissionRequest` síncronos, los hooks
  competían. Se resolvió desinstalando Moshi el 19-11-2026; therd es el único que retiene.

---

## 4. Claude Code: el transcript JSONL

Ruta: `~/.claude/projects/<cwd con no-alfanuméricos → '-'>/<session_id>.jsonl`; subagentes en
`<session_id>/subagents/agent-<id>.jsonl`. Nos llega exacto en `transcript_path` de cada hook.

**Formato interno y cambiante** (la doc lo advierte). Lo observado en un transcript real de hoy:

| `type` de línea | Qué es | Uso |
|---|---|---|
| `user` con `message.content` string | prompt del usuario (`promptId`, `promptSource`) | burbuja usuario |
| `user` con `content[].type == "tool_result"` | resultado de herramienta; trae `toolUseResult` estructurado y `permissionDecision` | cerrar tool card |
| `assistant` | **una línea por bloque de contenido** (`text`, `thinking`, `tool_use`) compartiendo `message.id` | agrupar por `message.id` |
| `system` | subtipos `compact_boundary`, `turn_duration`, `away_summary`, `local_command`, `stop_hook_summary`… | marcadores |
| `ai-title`, `last-prompt` | título de la sesión y último prompt | lista de sesiones |
| `permission-mode`, `mode` | modo actual (auto, plan…) | cabecera |
| `api-request*`, `file-history-*`, `attachment`, `cost-state`, `tools-used`, `session-owner`, `queue-operation`, `atis-latch` | metadatos internos | ignorar |

Reglas del parser: ser tolerante (ignorar tipos desconocidos), emparejar `tool_use.id` con
`tool_result.tool_use_id`, descartar `isSidechain: true` del hilo principal y leer por
*offset* (tail incremental, no releer el archivo entero).

---

## 5. herdr: inventario, estado y entrada

herdr expone una API JSON-RPC por socket Unix (`$HERDR_SOCKET_PATH`,
`~/.config/herdr/herdr.sock`), una petición JSON por línea. Esquema completo con
`herdr api schema --json`.

### 5.1 Inventario de sesiones

`agent.list` (o `herdr agent list`) devuelve por cada agente:

```json
{
  "agent": "claude",
  "agent_session": { "kind": "id", "source": "herdr:claude", "value": "<session_id>" },
  "agent_status": "idle",
  "pane_id": "w3A:p1", "tab_id": "w3A:t1", "workspace_id": "w3A",
  "cwd": "/home/user/dev/lab/therd",
  "foreground_cwd": "…/worktrees/…",
  "terminal_title_stripped": "Vista Moshi para Claude Code",
  "focused": true
}
```

Esto **ya** une pane ↔ `session_id` (gracias al hook de herdr) y da el título que Claude pone
en la pestaña. Con `workspace.list`/`tab.list` se agrupa por workspace como en herdr.

### 5.2 Estado en vivo

`events.subscribe` con suscripciones a `pane.agent_status_changed` (por pane) devuelve
eventos `{event, data}` con `agent_status` ∈ `idle | working | blocked | done | unknown`.
También hay `pane.created`, `pane.closed`, `workspace.*`, `tab.*` para refrescar el inventario.
`blocked` = esperando permiso o pregunta en el terminal: sirve de red de seguridad si un hook
falla.

### 5.3 Entrada (enviar mensajes y parar)

- **`agent.prompt { target, text, wait? }`**: escribe y envía un prompt. Rechaza con
  `agent_blocked` si el agente está bloqueado (útil: no mezclamos texto con un diálogo). Con
  `wait` espera a ver `working`.
- **`agent.send_keys { target, keys: [...] }`**: para **Stop** (`Escape`) y como plan B para
  contestar diálogos del terminal.
- `pane.read` / `agent.read`: leer la pantalla del terminal (fallback de depuración).

Esto resuelve la parte que Claude Code no documenta (inyectar en una sesión interactiva ya
abierta) sin `tmux send-keys` ni `--channels`.

### 5.4 Alternativas descartadas para la entrada

| Opción | Por qué no |
|---|---|
| Channels (`--channels`, MCP) | research preview; obliga a lanzar Claude con flags especiales |
| `claude -p --resume` | proceso paralelo sobre la misma sesión; puede perder mensajes |
| Remote Control | cliente oficial cerrado, no API |
| Agent SDK | habría que lanzar las sesiones desde el daemon, no desde herdr |

---

## 6. Arquitectura propuesta

```
 Claude Code (en un pane de herdr)
   │  hooks http (POST JSON + X-Herdr-Pane)        ▲ respuesta (decisión permiso/pregunta)
   ▼                                               │
 ┌──────────────────────── therd daemon (PC) ──────────────────────────┐
 │ HookServer :24600 (127.0.0.1)                                       │
 │ TranscriptTailer (lee transcript_path por offset)                   │
 │ HerdrClient (socket: agent.list, events.subscribe, agent.prompt,    │
 │              agent.send_keys)                                       │
 │ SessionStore (estado por session_id: items, status, pendientes)     │
 │ AppServer WebSocket :24601 (IP de Tailscale, token)                 │
 └─────────────────────────────────────────────────────────────────────┘
   ▲ WebSocket por Tailscale
   ▼
 App Flutter (Android primero): sesiones → chat → composer
```

### 6.1 Lenguaje del daemon

Recomendado: **Dart** (`dart compile exe`). Un solo lenguaje, y los modelos del protocolo se
comparten con la app en un paquete común. Alternativa: Go (binario más pequeño, como
moshi-hook), a costa de duplicar modelos.

### 6.2 Estructura del repo

```
therd/
  packages/protocol/   # modelos JSON compartidos (sealed classes + json_serializable)
  daemon/              # bin/therd.dart: serve, install, uninstall, doctor, pair
  app/                 # Flutter
  plugin/              # plugin de Claude Code con hooks/hooks.json
```

### 6.3 Protocolo app ↔ daemon (borrador)

Servidor → app:

| Mensaje | Contenido |
|---|---|
| `hello` | versión, lista de sesiones |
| `sessions` | `[{sessionId, paneId, workspace, title, cwd, branch, status, model, mode}]` |
| `backlog` | `{sessionId, items[], cursor}` (paginado hacia atrás) |
| `item.append` / `item.update` | un item del chat (ver §6.4) |
| `status` | `{sessionId, status}` |
| `pending` | permiso, pregunta o plan pendiente con `requestId` |
| `pending.resolved` | se contestó (desde el móvil o desde el terminal) |

App → servidor:

| Mensaje | Efecto |
|---|---|
| `subscribe {sessionId}` | recibir backlog y directo de esa sesión |
| `prompt {sessionId, text}` | `agent.prompt` en herdr |
| `interrupt {sessionId}` | `agent.send_keys ["Escape"]` |
| `permission {requestId, allow, always?, message?}` | respuesta al hook bloqueado |
| `answer {requestId, answers}` | respuesta a AskUserQuestion |
| `release {requestId}` | "contestar en el PC": el hook vuelve vacío |

### 6.4 Modelo de items del chat

`UserPrompt`, `AssistantText` (Markdown), `Thinking` (plegado), `ToolCall` (nombre, input
resumido, estado running/ok/error, resultado expandible; render específico para `Bash`, `Edit`
con mini diff, `Read`, `Write`, `Grep`/`Glob`, `Task`/subagente, `TodoWrite`), `Permission`,
`Question`, `Plan`, `Marker` (compactación, fin de turno con duración, error de API).

Clave de deduplicación: `uuid` de línea del transcript y `tool_use_id`; los items creados desde
hooks se reconcilian cuando llega la línea equivalente del transcript.

### 6.5 Seguridad

- El HookServer escucha solo en `127.0.0.1`.
- El AppServer escucha en la IP de Tailscale (100.x), nunca en `0.0.0.0`, con token emparejado
  por QR (`therd pair` muestra un QR con host, puerto y token).
- Nada pasa por terceros: sin nube intermedia (a diferencia de Moshi).

### 6.6 Notificaciones al móvil

- v1: notificación local cuando la app está abierta o en segundo plano reciente.
- v2: push real sin backend propio con **ntfy** (autoalojable) o FCM; el daemon publica
  "permiso pendiente en X" o "turno terminado en X".

---

## 7. App Flutter

- **Pantallas:** lista de sesiones agrupadas por workspace (título, estado con color, cwd y
  rama) → chat → composer. Ajustes: host, token y escaneo de QR.
- **Paquetes candidatos:** `web_socket_channel`, `flutter_riverpod`, `gpt_markdown` o
  `markdown_widget` (el `flutter_markdown` oficial está discontinuado), `flutter_highlight` o
  `re_highlight` para código, `mobile_scanner` para el QR, `flutter_local_notifications`.
- **UX a copiar de Moshi:** barra fija de aprobación encima del composer; Stop en lugar de
  Enviar mientras `working`; tool cards compactas que se expanden; prompts retenidos si hay
  pregunta pendiente.
- **Textos de interfaz:** sin separadores «·» (coma, dos puntos, paréntesis o segunda línea).

---

## 8. Plan por fases

| Fase | Entrega | Verificación |
|---|---|---|
| 0. Spike | daemon mínimo que registra a disco todos los hooks (incl. `MessageDisplay`) y eventos de herdr | ver qué llega realmente y con qué latencia |
| 1. Espejo de solo lectura | sesiones + chat desde transcript + estado de herdr | abrir el móvil y seguir un turno real |
| 2. Entrada | composer (`agent.prompt`) y Stop (`Escape`) | mandar un prompt desde el móvil |
| 3. Control | permisos, AskUserQuestion y planes vía hooks bloqueantes con la regla "solo si hay móvil" | aprobar un `git push` desde el móvil |
| 4. Calidad | render por herramienta, diffs, subagentes, compactación, reconexión con cursor | |
| 5. Extras | push (ntfy), imágenes en el composer, rewind, iOS | |

---

## 9. Riesgos y preguntas abiertas

- **Formato del transcript** interno: puede romperse con una actualización de Claude Code.
  Mitigación: parser tolerante y `MessageDisplay` si resulta útil.
- **Hooks bloqueantes y terminal:** la regla "solo bloquear si hay móvil conectado" hay que
  probarla bien; un hook colgado deja el terminal sin diálogo hasta el timeout.
- **Convivencia con Moshi (resuelto):** therd lo sustituye; Moshi se desinstaló el 19-11-2026.
- **`agent.prompt` con texto multilínea o muy largo:** comprobar cómo lo escribe herdr en el
  TUI (pegado entre corchetes o no).
- **Sesiones fuera de herdr:** fuera de alcance (no hay forma de enviarles texto); se podrían
  mostrar en solo lectura gracias a los hooks.
- **Subagentes y teammates:** los hooks traen `agent_id`; decidir si se ven como pestañas o
  como una tool card plegable.
- **Varias máquinas:** herdr ya tiene `--machine`; el daemon podría ser uno por máquina y la
  app guardar varios hosts.

---

## 10. Fuentes

- Moshi: https://getmoshi.app/docs/chat-view, https://getmoshi.app/docs/agent-hooks,
  https://getmoshi.app/docs/debug-chat-view, https://getmoshi.app/docs/hook-settings,
  https://getmoshi.app/docs/herdr, https://getmoshi.app/pricing,
  https://github.com/rjyo/homebrew-moshi
- Claude Code: https://code.claude.com/docs/en/hooks.md,
  https://code.claude.com/docs/en/sessions.md, https://code.claude.com/docs/en/headless.md,
  https://code.claude.com/docs/en/channels-reference.md,
  https://code.claude.com/docs/en/remote-control.md
- herdr: `herdr --help`, `herdr api schema --json`, `herdr --skill`, https://herdr.dev/llms.txt
- Local: `~/.claude/settings.json` (hooks de Moshi y herdr), `~/.claude/hooks/herdr-agent-state.sh`,
  `moshi-hook --help`, un transcript real en `~/.claude/projects/`.
