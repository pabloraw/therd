# Notificaciones

Cuando Claude se queda esperando un permiso, una pregunta o un plan y no hay ninguna app
conectada, el daemon manda un aviso al móvil y therd lo muestra como notificación propia. La
app cierra el WebSocket al pasar a segundo plano, así que «sin app conectada» equivale a
tener el móvil bloqueado o estar en otra app. Con therd abierto no se avisa, porque el
pendiente ya sale en pantalla.

El transporte es [UnifiedPush](https://unifiedpush.org), un estándar abierto de push sin
Google. La app [ntfy](https://ntfy.sh) hace de *distribuidor*: mantiene una conexión con un
servidor ntfy propio y entrega los avisos a therd, sin mostrarlos ella. Si ningún móvil se ha
registrado por UnifiedPush, el daemon publica en el topic `therd` de ntfy como respaldo, y
esas notificaciones sí son de ntfy.

## Montarlo

En el PC, el servidor (Docker):

```sh
TS_IP=$(tailscale ip -4) docker compose -f deploy/ntfy/compose.yaml up -d
curl -s http://127.0.0.1:24602/v1/health   # {"healthy":true}
```

Docker guarda la IP resuelta al crear el contenedor; si la de Tailscale cambia, se repite el
comando. El contenedor se reinicia solo con el PC (`restart: unless-stopped`).

En `~/.config/therd/config.json`, la sección `ntfy` (sin ella no hay notificaciones):

```json
{
  "ntfy": {
    "url": "http://127.0.0.1:24602",
    "topic": "therd"
  }
}
```

`token` es opcional, para un servidor ntfy con usuarios. Tras editarla se reinicia
`therd serve`; `therd notify-test` manda un aviso de prueba y `therd doctor` comprueba que
el servidor responde.

En el móvil:

1. Instalar **ntfy** (Google Play o F-Droid). Es una app libre de notificaciones push y hace
   de distribuidor de UnifiedPush.
2. En sus ajustes, poner `http://<IP de Tailscale del PC>:24602` como **servidor
   predeterminado**. UnifiedPush usa ese servidor; si se queda en `ntfy.sh`, los avisos irían
   por el servidor público.
3. Quitar a ntfy la optimización de batería de Android, o el sistema cortará su conexión.
4. Abrir therd y aceptar el permiso de notificaciones. En el log del daemon sale
   `push: endpoint registrado`.

Para usar el topic de respaldo, hay que suscribirse a `therd` en ntfy con **entrega
instantánea**. Con UnifiedPush funcionando no hace falta, y daría avisos repetidos solo si
el registro se pierde.

Tailscale tiene que estar activo en el móvil, igual que para usar la app. Para probar el
enlace sin notificación:
`adb shell am start -a android.intent.action.VIEW -d "therd://session/<id>" com.pabloraw.therd`.

## Cómo funciona

1. **El PC no cambia.** Sin app conectada, el daemon no retiene el hook y el diálogo sale en
   el terminal de Claude Code como siempre, para contestarlo ahí si estás delante.
2. **El daemon vigila ese diálogo.** Lee la pantalla del pane por la API de herdr (hasta 8
   segundos) y, cuando confirma que el diálogo está a la vista, lo abre como pendiente igual
   que uno retenido. Si la última app se desconecta, o vence el plazo de un hook retenido,
   ese diálogo pasa al terminal y sigue el mismo camino con el mismo pendiente.
3. **Aviso.** Al abrirse un pendiente sin app conectada, el daemon hace un POST con un JSON
   (`PushPending` en `packages/protocol/lib/src/push.dart`) a cada endpoint registrado. La
   app lo recibe aunque esté cerrada y pinta la notificación: tipo («Permiso: Bash»,
   «Pregunta», «Plan para revisar»), sesión y resumen. Al tocarla se abre el chat de esa
   sesión. Los permisos traen los botones «Permitir» y «Denegar», y los planes «Aprobar» y
   «Rechazar» (ver «Botones» más abajo).
4. **Retirada.** Cuando el pendiente se cierra (contestado en la app o en el PC, liberado o
   cancelado), el daemon manda `PushResolved` y la app quita la notificación.
5. **Respuesta por teclas.** Al contestar desde la app, el daemon pulsa en el terminal las
   teclas que corresponden a esa respuesta. Las opciones se leen de la pantalla, porque su
   número cambia de un diálogo a otro. Si se contesta antes en el PC, el diálogo desaparece
   de la pantalla y el pendiente se cierra solo.

| Diálogo | Respuesta desde la app | Teclas |
|---|---|---|
| Permiso | Permitir | `1` |
| | Permitir siempre | la primera «Yes, and …» que no sea pasar a modo auto |
| | Denegar | el número de «No» |
| | Denegar con mensaje | bajar hasta «No», `Tab`, el texto y `Enter` |
| Plan | Aprobar | `2` («Yes, manually approve edits», no cambia el modo) |
| | Rechazar | `Escape` |
| | Rechazar con comentario | `3` («Tell Claude what to change»), el texto y `Enter` |
| Pregunta | Una opción | su número |
| | Texto libre | el número de «Type something», el texto y `Enter` |
| | multiSelect | el número de cada casilla y `Right` |
| | multiSelect con texto libre | las casillas, el número de «Type something», bajar hasta ella, el texto, `Down` y `Enter` |
| | Varias preguntas | lo anterior por pregunta y `1` (Submit) al final |

Nada pasa por terceros: ntfy corre en el PC y solo escucha en la IP de Tailscale y en
loopback. Todo va por `http`, pero dentro del túnel de Tailscale, que cifra de extremo a
extremo con WireGuard. Los avisos van sin cifrado propio de Web Push por la misma razón.

## Fin de turno

Cuando Claude termina un turno y nadie lo ha visto, llega un aviso sin botones: «Terminado:
nombre de la sesión» y un trozo del último texto de Claude. Al tocarlo se abre el chat de esa
sesión. Va por el mismo transporte que los pendientes (UnifiedPush y, si no, ntfy).

- **Disparo.** Herdr pasa la sesión a `done` o llega el hook `Stop` (sirve también para
  sesiones fuera de herdr). Las dos señales del mismo turno cuentan una vez.
- **Margen.** El daemon espera 5 segundos por si aún llega el final del transcript o alguien
  la ve. Pasado el margen no avisa si lo visto (`seenSeq`, compartido entre PC y móvil, ver
  «Leído y sin leer» en [arquitectura.md](arquitectura.md)) ya alcanza el último seq, si hay
  una app conectada o si la sesión tiene un pendiente abierto (ese ya avisa por su cuenta).
- **Retirada.** `PushTurnCleared` quita la notificación cuando la sesión se ve (en el PC o en
  el móvil) o cuando empieza un turno nuevo. Hay una por sesión: la nueva sustituye a la
  anterior. Con el respaldo de ntfy no hay retirada.
- **Compatibilidad.** Son dos payloads nuevos, `turn_done` y `turn_cleared`
  (`packages/protocol/lib/src/push.dart`). Una app antigua los ignora, porque
  `PushPayload.fromJson` devuelve null con los tipos que no conoce.

La lógica está en `TurnNotifier` (`daemon/lib/src/notifier.dart`). Al arrancar el daemon no
se avisa de las sesiones que ya estaban terminadas: solo de los fines de turno que ve ocurrir.

## Botones

Un botón no abre la app. Android arranca un isolate de Dart sin interfaz
(`onNotificationAction` en `app/lib/src/push/push_service.dart`), que lee la conexión
emparejada, abre un WebSocket suelto con el daemon, manda el mismo `permission` que la
tarjeta del chat y espera a que el pendiente se cierre (`sendQuickReply` en
`app/lib/src/push/quick_reply.dart`, hasta 10 segundos). El daemon lo contesta por teclas
como cualquier respuesta desde la app.

- «Denegar» y «Rechazar» van sin mensaje. Para explicar el motivo, o para «Permitir
  siempre», hay que tocar la notificación y contestar en el chat.
- Las preguntas no llevan botones, porque sus opciones cambian de una a otra.
- Si la respuesta no llega (sin Tailscale, daemon parado o ya contestado en el PC), la
  notificación se cambia por «No se pudo contestar» con el motivo, y al tocarla se abre el
  chat.
- Esa conexión suelta cuenta como app conectada mientras dura, pero no libera los diálogos
  que ya están en el terminal al cerrarse.

## Registro por UnifiedPush

1. Al abrirse en primer plano, la app pide permiso de notificaciones y se registra en el
   distribuidor instalado (`UnifiedPush.tryUseCurrentOrDefaultDistributor` y `register`).
2. ntfy crea en su **servidor predeterminado** un topic privado y aleatorio (`up…`) y
   devuelve su URL, el *endpoint*. Ese topic no aparece en la lista de ntfy.
3. La app guarda el endpoint y se lo manda al daemon con `push_register` en cada conexión,
   junto con el anterior si ha cambiado, para que lo olvide.
4. El daemon guarda los endpoints (hasta 5) en `~/.config/therd/push.json`.
5. Si ntfy retira el registro (por ejemplo, al desinstalarla), la app manda
   `push_unregister`.

Con la app cerrada, Android la arranca en segundo plano con `--unifiedpush-bg` solo para
recibir el aviso, sin interfaz (`app/lib/main.dart`).

El motor de Flutter sobrevive a la Activity (`MainActivity.kt`): salir con «atrás» no lo
destruye. `unifiedpush_android` 3.4.1 solo crea un motor para los avisos si el proceso nunca
tuvo uno, así que con el proceso vivo y el motor destruido los avisos llegaban y se perdían.

## Límites

- Avisa de lo que bloquea a Claude y del fin de turno sin ver. Los errores de la API no avisan.
- Los botones solo cubren permitir y denegar sin mensaje. Lo demás se contesta en el chat.
- `unifiedpush_android` está fijado en 3.4.1 (`dependency_overrides` en `app/pubspec.yaml`)
  porque la 3.5.0 exige el Android Gradle Plugin 9.
- Las respuestas por teclas dependen de los textos y atajos de los diálogos de Claude Code
  (probados con la 2.1.328, capturas en `daemon/test/fixtures/`), que pueden cambiar con una
  actualización. Si no se reconoce un diálogo, no se abre el pendiente y tampoco se avisa.
  La lógica está en `daemon/lib/src/terminal_dialogs.dart`.
- Si Claude Code no manda `PermissionRequest` para un plan, el daemon lo abre desde el `PreToolUse`
  de `ExitPlanMode`: espera 2 s a ese hook y, si no ha llegado, vigila el terminal como con
  cualquier pendiente de terminal. Así no hay plan sin aviso, pero el pendiente no trae las
  sugerencias de permiso del hook.
- Las sesiones fuera de herdr no tienen pane al que mirar ni en el que pulsar teclas.
