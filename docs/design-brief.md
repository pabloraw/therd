# therd: guía de estilo de diseño

Estilo de la propuesta C («Cayado»), cerrado el 19 de noviembre de 2026: interfaz monocroma y oscura por defecto, donde el único color en pantalla es el del estado de las sesiones.

## Principios

1. **El color es una señal, no decoración.** Solo llevan color los cuatro estados y los errores. Si ves rojo, algo te espera.
2. **Sin acento de marca.** Las acciones principales van en blanco roto sobre oscuro; la selección, en un gris algo más claro. El verde salvia desaparece de la interfaz.
3. **Poco ruido.** Lo secundario (marcadores de turno, ramas, rutas) se camufla con el fondo y se lee solo si lo buscas.
4. **Lo urgente, bajo el pulgar.** Los pendientes viven en una hoja inferior con los botones abajo y la acción principal a la derecha.
5. **Peso visual bajo, zona táctil completa.** Botones que se ven de 44 px, con un solo relleno por grupo.
6. **Nada de separadores «·»** en textos de interfaz: comas, dos puntos, paréntesis o una segunda línea.

## Color

Neutros cálidos para la estructura y los cuatro colores de herdr para el estado. Tema oscuro por defecto; el claro sigue al sistema.

### Neutros

| Token | Oscuro | Claro | Uso |
| --- | --- | --- | --- |
| `bg` | `#161513` | `#FBFAF7` | Fondo de pantalla |
| `surface` | `#1F1D1A` | `#FFFFFF` | Barras fijas, hoja de pendiente, grupos de herramientas |
| `cont` | `#2A2724` | `#F1EEE8` | Mensaje del usuario, fila pulsada, opción elegida |
| `cont2` | `#332F2B` | `#E8E4DC` | Botón desactivado, selección |
| `line` | `#34302C` | `#E3DED5` | Separadores, bordes de botones secundarios, línea de árbol |
| `text` | `#EDEAE4` | `#1C1B19` | Texto principal; también fondo de la acción principal |
| `muted` | `#A8A299` | `#5F5A52` | Texto secundario: ramas, rutas, descripciones |
| `faint` | `#5E5953` | `#B3ADA3` | Lo que se camufla: marcadores de turno |
| `code` | `#11100E` | `#F4F1EB` | Fondo de bloques de código y diffs |

### Estado (suavizados respecto a herdr)

| Estado | Punto | Forma | Texto sobre oscuro | Texto sobre claro | Color de herdr |
| --- | --- | --- | --- | --- | --- |
| Esperando respuesta | `#E0685C` | relleno | `#EFA59C` | `#A93A30` | `#EF4444` |
| Sin leer | `#6AA6D6` | relleno | `#A4C8E8` | `#2F6690` | `#38BDF8` |
| Trabajando | `#D4A24C` | relleno | `#E6C17E` | `#8A5A12` | `#F5A524` |
| Terminado y leído | `#6FB98A` | anillo de 2 px | `#8FCBA4` | `#2F7A4B` | `#22C55E` |
| Desconocido | `#77716A` | anillo de 2 px | No lleva texto | No lleva texto | gris del tema |

Mismos tonos que herdr, con menos saturación, para que la lista no parezca un parchís. Los puntos usan el color de la columna Punto; el texto de estado usa la variante aclarada (oscuro) u oscurecida (claro) para llegar a 4,5:1. Los fondos tenues de estado (franjas, registro pendiente, error) son el color del punto al 13–15 % de opacidad. Los diffs siguen la misma línea: verde `#A6D9B5` y rojo `#EFA59C` sobre fondos tenues.

### Acción

- **Principal** (Permitir, Aprobar, Enviar, Guardar): fondo `text`, texto `bg`.
- **Secundaria**: sin fondo, borde de 1 px en `line`.
- **Negativa** (Denegar, Rechazar): texto rojo de estado, borde rojo al 45 %. Al confirmar, añade el fondo rojo tenue; nunca rojo macizo.
- **Detener**: cuadrado relleno en rojo de estado con borde rojo al 60 %, para que no se confunda con Enviar.

## Tipografía

Dos familias de Google Fonts: **Geist** para todo el texto y **Geist Mono** solo para lo que es código o máquina (comandos, rutas, ramas, IPs, tokens, diffs).

| Uso | Familia | Tamaño | Peso |
| --- | --- | --- | --- |
| Título grande (estados vacíos, Conexión) | Geist | 22–28 px | 600, tracking −0,01 a −0,02 em |
| Título de pantalla | Geist | 18–20 px | 600–700 |
| Respuesta de Claude (Markdown) | Geist | 16 px, interlineado 1,6 | 400 |
| Mensaje del usuario | Geist | 16 px, interlineado 1,5 | 400 |
| Título de sesión en la lista | Geist | 15 px | 500 |
| Botones | Geist | 14 px | 500; 600 en la principal |
| Nombre de herramienta | Geist | 13 px | 600 |
| Cabecera de workspace | Geist | 13 px | 600, color `muted` |
| Marcador de turno | Geist | 12 px | 400, color `faint` |
| Rama, ruta, resumen de herramienta | Geist Mono | 12 px | 400, color `muted` |
| Código y diffs | Geist Mono | 12–13 px, interlineado 1,55 | 400 |

Sentence case siempre, también en títulos y botones. Todo texto que no quepa se corta con elipsis en una línea.

## Forma y espaciado

Radios contenidos y alturas de 44 px: la zona táctil mínima de Android sin que nada parezca de juguete.

| Elemento | Medida |
| --- | --- |
| Botón, campo de texto, icono pulsable | 44 px de alto, radio 10 px |
| Fila de sesión | mínimo 54 px, radio 10 px, margen lateral 8 px |
| Filtro de la barra inferior | 44 px, radio 10 px |
| Respuesta rápida | 36 px, radio 8 px |
| Grupo de herramientas, mensaje del usuario | radio 12 px |
| Hoja de pendiente | radio 16 px solo arriba, a sangre por los lados y abajo |
| Franjas de conexión | a sangre, sin radio |
| Punto de estado | 10–11 px; anillo de 2 px |
| Margen de pantalla | 16 px (listas y chat), 20–24 px (cabeceras y formularios) |
| Sangría de worktree | 30 px, con línea vertical de 1 px en `line` a 12 px de la fila |

Las sombras solo marcan lo que flota sobre la conversación: la hoja de pendiente, el botón «N mensajes nuevos» y los avisos efímeros.

## Componentes

### Lista de sesiones

- **Cabecera de workspace:** nombre del repo en 13 px, peso 600, color `muted`. No se toca y no lleva punto ni rama.
- **Fila de sesión:** punto de estado, título en una línea y, debajo, icono de rama + rama en Geist Mono 12 px. Sin etiquetas «Esperando» o «Sin leer»: el estado lo dice el punto.
- **Worktree:** sus tabs van sangradas 30 px con una línea vertical fina; el subtítulo es solo su rama. Todas las filas tienen el mismo tamaño.
- **Fuera de herdr:** última sección, con anillo gris para el estado desconocido.
- **Filtros:** barra inferior con «Todas», «Te esperan N» y «Sin leer N»; el activo lleva fondo `cont`. Filtrar mantiene las cabeceras y oculta los grupos vacíos.
- **Logo con punto resumen:** el logo «th_» lleva un punto con el estado más urgente (esperando > sin leer > trabajando > leído > desconocido).

### Chat

- **Cabecera:** volver, título y debajo el punto de estado y la rama en monoespaciada, sin texto de estado: el color se explica solo.
- **Trabajando:** al final del chat, una chispa ámbar que respira y gira junto a «Pensando» con un brillo que recorre el texto.
- **Scroll anclado:** lo que llega nunca mueve lo que se está leyendo. Un prompt nuevo (estando abajo o enviado desde el móvil) sube arriba con un scroll suave y la respuesta aparece debajo; si se sale de la pantalla, avisa la píldora de mensajes nuevos. Las filas nuevas entran en 220 ms, apareciendo y subiendo 8 px.
- **Mensaje del usuario:** bloque a ancho completo con fondo `cont`, radio 12 px y la etiqueta «Tú» en 12 px.
- **Respuesta de Claude:** Markdown sin contenedor, 16 px.
- **Herramientas:** las consecutivas se agrupan en una tarjeta con separadores. Cada fila: icono, nombre, resumen en monoespaciada, duración y check verde, spinner ámbar o «Error» en rojo con fondo rojo tenue. Al tocar se despliega el detalle (diff, salida, checklist). «Pensando» es la primera fila del grupo, plegada.
- **Marcadores de turno:** texto centrado en 12 px y color `faint`, casi camuflado. Los de error, en rojo.
- **Registro de pendiente:** fila con borde `line` y el desenlace a la derecha («Permitido» en verde; «Contestado en el PC» o «Sin respuesta, pasó al PC» en `muted`; «Pendiente» con fondo rojo tenue).

### Hoja de pendiente

Sustituye a la caja de texto mientras hay algo pendiente. Ocupa todo el ancho, con radio 16 px arriba, un tirador de 36 × 4 px y una sombra hacia arriba. Máximo media pantalla, con scroll interno. La conversación de detrás sigue visible y desplazable.

- **Cabecera:** punto rojo, título («Permiso para ejecutar un comando», «Claude te pregunta», «Claude propone un plan») y «1 de 2 pendientes».
- **Permiso:** descripción y el comando en bloque de código. Botones en una fila: Denegar, Permitir siempre y Permitir (el más ancho, a la derecha).
- **Pregunta:** encabezado corto en monoespaciada, la pregunta y las opciones como filas con radio o casilla; «Otra» abre un campo. «Enviar respuesta» se activa cuando todo está contestado.
- **Plan:** Markdown con scroll. Botones Rechazar y Aprobar.
- **Denegar o rechazar:** abre un campo opcional para el motivo y cambia los botones a Cancelar + confirmar.
- **Siempre al pie:** «Contestar en el PC» como botón de texto con icono de monitor.

### Caja de texto

Campo que crece con el contenido hasta unas 6 líneas y botón cuadrado de 44 px a la derecha.

- **Libre:** «Escribe a Claude»; Enviar en `text` cuando hay texto, desactivado si no.
- **Trabajando:** Detener en rojo, con un cuadrado relleno.
- **Sin conexión:** desactivada, con el texto de ayuda «Sin conexión».
- **Respuestas rápidas:** fila desplazable encima de la caja cuando Claude ha terminado («Sí», «Continúa»…).
- **Mensajes nuevos:** si el usuario subió y llegan mensajes, aparece la píldora «N mensajes nuevos» con flecha abajo, en `text` sobre `bg`.

### Conexión y avisos

- **Franjas de conexión:** a sangre bajo la cabecera, en 13 px. Reconectando, en ámbar tenue con spinner; token rechazado, en rojo tenue con candado y enlace a Conexión.
- **Avisos efímeros:** píldora flotante en `text` sobre `bg`, con icono de alerta y una frase.
- **Formulario de conexión:** dos pasos numerados (ejecuta `therd pair`, escanea el QR) y «Escribir los datos a mano» desplegable. Errores bajo cada campo, en rojo y con borde rojo. El resultado, en una línea con punto de color.

## Pantallas y estados cubiertos

El lienzo tiene 29 pantallas: 5 base con tweaks y 24 variantes que reutilizan las base con un estado fijado.

| Pantalla | Estados diseñados |
| --- | --- |
| Arranque | Logo y cuatro puntos de estado animados |
| Sesiones | Lista completa; filtros «Te esperan» y «Sin leer»; reconectando; token rechazado; sin sesiones; sin conexión y vacía |
| Chat: pendientes | Permiso; pregunta sin contestar; pregunta contestada con «Otra»; plan; denegar con motivo; rechazar plan |
| Chat: otros | Trabajando; libre con mensajes nuevos y respuestas rápidas; aviso de error; sin conexión; sin mensajes; cargando |
| Conexión | Ajustes; primera vez vacía; QR leído; probando; errores de validación; sin respuesta; token rechazado; QR que no es de therd |
| Escanear QR | Cámara activa; cámara sin permiso |

## Lo que no se hace y cambios respecto al brief

**No se hace:**

- Color de acento o de marca en la interfaz (botones, bordes, selección).
- Botones con relleno de color o rojo macizo; más de un botón relleno por grupo.
- Etiquetas de estado en las filas de la lista.
- Tira para cambiar de sesión dentro del chat: se vuelve a la lista.
- Separadores «·», Title Case, emoji, degradados o tarjetas con borde lateral de color.

**Cambios que contradicen el brief original y conviene trasladar a él:**

| Punto del brief | Decisión nueva |
| --- | --- |
| Colores de estado iguales a herdr | Mismos tonos, desaturados (ver Color). El PC y el móvil ya no coinciden al píxel. |
| Etiquetas «Esperando» y «Sin leer» en cada fila | Eliminadas; el estado lo da el punto y los filtros. |
| Worktrees como subcabeceras con ├ y └ | Tabs sangradas con línea vertical fina; subtítulo con la rama. |
| Rama junto a la cabecera de workspace | La rama va en cada fila, bajo el título. |
| Pendiente fijo encima de la caja de texto | Hoja inferior que sustituye a la caja de texto. |
| Marca verde salvia `#5E7A63` | Fuera; el logo es «th_» en GeistMono blanco sobre negro, también como icono de la app. |
