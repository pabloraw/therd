# Arquitectura

Cómo funciona therd por dentro. Para instalarlo y usarlo, ver el [README](../README.md). La
especificación original está en [INVESTIGACION.md](../INVESTIGACION.md).

## Piezas

```
Claude Code ──hooks HTTP──▶ therd serve ◀──API por socket── herdr
     │                       │    ▲
     └── transcript JSONL ───┘    │ WebSocket (Tailscale, token)
                                  ▼
                              app Android ◀── UnifiedPush (ntfy) ── avisos
```

- **Hooks** (`daemon/lib/src/hook_server.dart`, `hook_router.dart`): Claude Code los manda a
  `127.0.0.1:24600`. Los de permisos, preguntas y planes se retienen mientras hay una app
  conectada, para contestarlos desde el móvil.
- **Transcript** (`transcript_tailer.dart`, `transcript_parser.dart`): el daemon sigue el JSONL
  de cada sesión en `~/.claude/projects` y lo convierte en items de chat.
- **herdr** (`herdr_client.dart`): da el estado de cada agente, el pane donde vive y permite
  escribirle (`agent.prompt`) y leer o pulsar teclas en su pantalla.
- **App** (`app_server.dart`): WebSocket en la IP de Tailscale con el token de emparejado. El
  protocolo está en `packages/protocol/`.

## Imágenes

Cada imagen que manda la app viaja en base64 dentro del mensaje `prompt` (hasta 4 por mensaje).
El daemon la guarda en `~/.cache/therd/uploads` (`THERD_UPLOADS_DIR` para cambiarlo) y pone su
ruta al final del prompt. Claude Code reconoce la ruta y la adjunta como imagen (`[Image #N]`).

**En el chat.** El daemon guarda en `~/.cache/therd/images` (`THERD_IMAGES_DIR` para cambiarlo)
cada imagen que aparece en los transcripts, por su hash: adjuntos del usuario, capturas de
pantalla y Read de imágenes. Los items solo llevan el id (`images` en `user_prompt` y
`tool_call`). La app las pide por HTTP al mismo puerto del WebSocket, con el token en
`Authorization: Bearer`:

- `GET /images/<id>` da una miniatura JPEG de 1024 px como mucho. Se calcula una vez, fuera del
  isolate principal, y se guarda junto al original. Una captura PNG de 500 KB queda en unos 55 KB.
- `GET /images/<id>?full=1` da el original, que solo se pide al abrir la imagen a pantalla completa.

Al arrancar, el daemon borra las subidas de más de 7 días y las imágenes de más de 30 (solo los
archivos con nombres que genera él). Estas últimas se regeneran al releer el transcript.

## Subagentes

Una llamada a `Task` (o `Agent`, en Claude Code reciente) sale como tarjeta propia: icono de
subagente, su `subagent_type` («Subagente» si no viene), la descripción, el estado (Trabajando,
Hecho o Error) y la duración. Sin desplegar enseña la última herramienta que ejecuta o «N
herramientas». Desplegada trae el prompt (recortado), las herramientas que usa en filas compactas
y su respuesta en Markdown.

- **De dónde sale.** Claude Code escribe cada subagente aparte, en
  `<sessionId>/subagents/agent-<agentId>.jsonl`, con un `agent-<agentId>.meta.json` al lado que
  trae el `toolUseId` de la llamada que lo lanzó y `finished` al terminar. El transcript principal
  no lleva sus líneas (siguen descartándose las `isSidechain`). Los subagentes de workflows
  (`subagents/workflows/...`) no traen `toolUseId` y no se enlazan.
- **Quién lo lee.** `SubagentWatcher` (`daemon/lib/src/subagent.dart`) cuelga del `TranscriptHub`.
  Cada sondeo mira las últimas 12 llamadas `Task`/`Agent`, empareja su `meta.json` por `toolUseId`
  y lee el transcript del subagente por offset. Los hooks con `agent_id` solo adelantan ese sondeo;
  la fuente es el transcript, que es lo único con el hilo completo y no se pierde si el daemon
  estaba parado.
- **Protocolo.** `ToolCallItem.subagent` (`SubagentInfo`, campo opcional) lleva `agentId`, las
  últimas 30 herramientas (`SubagentStep`: nombre, `input` reducido a 200 caracteres por campo y
  estado), `toolCount`, `finished`, `durationMs` y `finalText` (hasta 4000 caracteres). No hay
  items nuevos: lo de un subagente se actualiza dentro de la tarjeta del `Task` con `item.update`,
  que no sube el seq, así que no cuenta como sin leer ni dispara avisos de fin de turno. Una app
  antigua ignora el campo y ve la tarjeta de `Task` de siempre.
- **Segundo plano.** Un subagente en segundo plano cierra su `Task` al lanzarlo; el estado lo da
  `finished` del subagente (su `meta.json`, o 15 minutos sin escribir).
- **Permisos.** Siguen como antes: `_surfaceFromHook` corre para los eventos de subagente.

## Leído y sin leer

Una sesión que termina se pinta en azul («sin leer») hasta que se mira, y se mira en
cualquiera de los dos sitios:

- **En el PC.** herdr distingue `done` (terminada sin ver) de `idle` (vista) y avisa al
  enfocar un pane. Cuando herdr da una sesión por vista, o se enfoca su pane, el daemon
  la apunta como vista hasta su último item y lo reparte a las apps (`seenSeq` en la
  sesión y mensaje `seen`). Lo que llega a la sesión que se tiene delante en el PC también
  queda visto.
- **En el móvil.** Con el chat abierto, la app guarda lo visto en el teléfono y se lo dice
  al daemon (`mark_seen`). Si herdr tiene la sesión en `done` y la app ya ha visto todo,
  el daemon enfoca ese pane en el PC y vuelve al que había (`pane.current` y
  `pane.focus`): herdr solo marca algo como visto al enfocarlo. Se ve un parpadeo de una
  fracción de segundo, y solo cuando la sesión estaba sin ver en el PC. Si se está
  tecleando en el PC justo en ese momento, alguna tecla puede ir al otro pane.

La lógica está en `daemon/lib/src/seen_sync.dart` y en la parte «visto» de
`daemon/lib/src/session_store.dart`. Lo visto vive en memoria del daemon; si se reinicia,
la app tira de lo que guarda en el teléfono.
