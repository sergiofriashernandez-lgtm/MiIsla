# Changelog

## 1.3.0
- Música del bloqueo sincronizada: la posición se lee con decimales y se re-sincroniza cada 2 s.
- Sin borde de color en la isla. El widget de bloqueo se apaga solo a los 10 min (ajustable).

## 1.2.0
- Brillo: destello de luz y borde con el color de la portada que respira mientras suena; rebote al aparecer avisos; sacudida al desconectar AirPods.
- Letra completa con scroll en la pantalla de bloqueo; portada y isla un poco más arriba.

## 1.1.0
- Rendimiento: portada y paleta se procesan en segundo plano; el vigilante de Mission Control / pantalla completa corre fuera del hilo principal; el sondeo de YouTube Music se frena solo cuando no hay nada y ya no se solapa.
- La isla siempre vive en la pantalla principal (antes seguía a `NSScreen.main` y podía saltar a otra pantalla o esquina).
- Letras: búsqueda en paralelo con tiempos cortos, validación de resultados, caché, reintento automático, lyrics.ovh como fuente extra y NetEase opcional (apagado por defecto).
- Un clic en la isla, o el botón con el icono de la app, abre Música (o el navegador en la pestaña de YouTube Music) con una animación.
- Preparado para publicar: licencia MIT, política de privacidad, icono, scripts de release y flujo de GitHub Actions. Ya no se incluye ninguna imagen de productos de Apple.

## 1.0.0
- Primera versión: isla flotante, Apple Music, YouTube Music, AirPods, carga, volumen, widget de pantalla de bloqueo.
