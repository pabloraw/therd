package com.pabloraw.therd

import android.content.Context
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * El motor de Flutter sobrevive a la Activity (salir con «atrás» no lo
 * destruye). unifiedpush_android 3.4.1 solo crea un motor para los avisos si
 * el proceso nunca tuvo uno: con el proceso vivo y el motor destruido, los
 * avisos llegaban y se perdían.
 */
class MainActivity : FlutterActivity() {
    private var reused = false

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let {
            reused = true
            return it
        }
        // La Activity arranca el punto de entrada (main) en este motor.
        return FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 12+: el splash del sistema («th_») se quita de golpe en vez
        // de con su fundido. Flutter pinta lo mismo en el mismo sitio
        // (lib/src/ui/splash.dart) y el fundido hacía que el logo se apagara
        // y volviera a aparecer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { it.remove() }
        }
        // Con el motor ya en marcha, main no vuelve a leer el toque que abrió
        // la app: se le pasa al plugin de notificaciones como un intent nuevo.
        if (reused && intent?.action == SELECT_NOTIFICATION) onNewIntent(intent)
    }

    private companion object {
        const val ENGINE_ID = "main"

        /** Acción de flutter_local_notifications al tocar una notificación. */
        const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
    }
}
