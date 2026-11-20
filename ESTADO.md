# Estado de therd

Última revisión: 20-11-2026. El plan original por fases está en la sección 8 de [INVESTIGACION.md](INVESTIGACION.md); aquí va dónde estamos y qué queda.

## Fases

| Fase | Estado | Notas |
|---|---|---|
| 0. Spike | Hecha | Los hooks HTTP y la API de herdr se probaron con sesiones reales. |
| 1. Espejo de solo lectura | Hecha | Sesiones por workspace, chat desde el transcript y estado en vivo de herdr. |
| 2. Entrada | Hecha | Prompt (`agent.prompt`), Stop (`Escape`), dictado por voz y respuestas rápidas. Lo enviado sale al momento como «Enviando» y se sustituye al volver del transcript. |
| 3. Control | Hecha | Permisos, preguntas y planes con hooks bloqueantes, solo si hay app conectada. Los planes funcionan desde el 19-11, al quitar los hooks de Moshi. Desde el 20-11, un plan sin `PermissionRequest` se abre igualmente desde su `PreToolUse`. |
| 4. Calidad | Hecha | Hay tarjetas por herramienta con diff, la marca de compactación y reconexión con cursor. Los subagentes (`Task`/`Agent`) tienen tarjeta propia con su actividad en vivo, leída de su transcript (ver «Subagentes» en docs/arquitectura.md): pendiente de probar en el Pixel. |
| 5. Extras | Hecha | Push hecho con UnifiedPush y ntfy propio (ver docs/notificaciones.md): notificación propia de therd para permisos, preguntas y planes sin app conectada, que se retira sola al contestarse; la app los contesta por teclas en el terminal. Probado de punta a punta en el Pixel el 19-11. Los permisos y planes traen botones en la notificación para contestar sin abrir la app (probados en el Pixel el 20-11). Lo leído se comparte entre el móvil y el PC (ver «Leído y sin leer» en docs/arquitectura.md): probado en los dos sentidos en el Pixel el 20-11. El fin de turno de una sesión sin ver también avisa (ver «Fin de turno» en docs/notificaciones.md), probado en el Pixel el 20-11. Las imágenes se adjuntan desde la galería o la cámara y se ven en el chat, también las capturas de las herramientas (ver «Imágenes» en docs/arquitectura.md). Probado en el Pixel el 20-11. Rewind e iOS se descartan el 20-11: no se van a usar. |

## Pendientes

- **Sesiones abiertas antes de quitar Moshi:** cargaron los hooks al arrancar, así que hay que reiniciarlas (`claude --resume`) para que manden sus planes y preguntas a therd.

## Riesgos abiertos

- El formato del transcript es interno de Claude Code y puede cambiar con una actualización.
- Si Claude Code no manda un `PermissionRequest` de un permiso, el pendiente no llega al móvil. Con los planes ya no pasa: se abren desde su `PreToolUse`. Pasó mientras Moshi tenía hooks en `ExitPlanMode`, y `therd doctor` avisa si vuelve a haber hooks de Moshi.
- Las sesiones fuera de herdr no pueden recibir texto desde el móvil.
- Las respuestas por teclas dependen de los textos de los diálogos de Claude Code (capturas en `daemon/test/fixtures/`). Tras actualizar Claude Code conviene mirar que siguen coincidiendo.
