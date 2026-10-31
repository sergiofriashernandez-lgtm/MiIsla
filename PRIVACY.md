# Privacidad y permisos / Privacy and permissions

MiIsla no tiene servidores propios, no usa analíticas y no guarda nada fuera de tu Mac.
MiIsla has no servers of its own, no analytics, and stores nothing outside your Mac.

## Permisos de macOS / macOS permissions

| Permiso / Permission | Para qué / What for |
|---|---|
| Automatización → Música | Leer la canción, portada, favoritos y mandar controles a Apple Music. |
| Automatización → navegadores | Solo si usas YouTube Music en el navegador: lee título, portada y tiempo de la pestaña de `music.youtube.com` y manda controles. Se apaga desde el menú ("Detectar YouTube Music"). |
| Bluetooth | Detectar cuando se conectan tus AirPods / Beats y leer su batería. |
| Acceso total al disco (opcional) | Solo para detectar "No molestar" en la pantalla de bloqueo. |

MiIsla no graba pantalla, no lee archivos personales y no usa micrófono ni cámara.

## Conexiones a internet / Network requests

| Servicio | Qué se envía | Cuándo |
|---|---|---|
| `itunes.apple.com` (iTunes Search) | Título y artista | Si Música no entrega portada o duración |
| `lrclib.net` | Título, artista, álbum, duración | Para buscar letras |
| `api.lyrics.ovh` | Artista y título | Letra sin tiempos, si lrclib no la tiene |
| `music.163.com` (NetEase, no oficial) | Título y artista | **Solo si lo activas** en el menú. Apagado por defecto |
| `ipwho.is` + `api.open-meteo.com` | Tu IP (ubicación aproximada) y coordenadas aproximadas | Solo para el clima de la pantalla de bloqueo |
| Portadas de YouTube Music | URL de la imagen | Al mostrar una canción de YouTube Music |

Todo lo demás pasa localmente. / Everything else happens locally.

## Aviso / Notice

La pantalla de bloqueo usa funciones privadas de macOS (SkyLight) que Apple no documenta ni garantiza.
Por eso la app **no puede publicarse en la Mac App Store**. Puede dejar de funcionar con una actualización de macOS.
MiIsla es un proyecto independiente y no está afiliado, patrocinado ni aprobado por Apple Inc.
Apple, Apple Music, AirPods, Mac, macOS y Dynamic Island son marcas de Apple Inc.
