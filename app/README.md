# therd (app)

App móvil (Flutter, Android) de therd: vista de chat para Claude Code dentro de
herdr. Se conecta al daemon de therd (ver `../daemon`) por WebSocket, normalmente
a través de Tailscale. Visión general del proyecto en el [README raíz](../README.md).

## Compilar

```sh
flutter pub get
flutter build apk --release
```

El APK queda en `build/app/outputs/flutter-apk/app-release.apk`.

## Firma release

Si existe `android/key.properties` (ignorado por git, igual que `*.jks`), el build
release firma con ese keystore; si no, cae a la clave debug.

```properties
storeFile=../therd-release.jks
storePassword=...
keyAlias=therd
keyPassword=...
```

`storeFile` es relativo a `android/`. Para generar el keystore:

```sh
keytool -genkeypair -v -keystore android/therd-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias therd
```

## Tests

```sh
flutter analyze
flutter test
```
