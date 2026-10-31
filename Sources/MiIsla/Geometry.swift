import AppKit

/// Estados de la isla, como en el iPhone.
enum IslandMode: Equatable {
    case idle        // píldora pequeña, sin música
    case playing     // píldora un poco más ancha: carátula + barras
    case peek        // asomo de 3 s al cambiar de canción
    case lock        // candado al bloquear / desbloquear la Mac
    case airpods     // aviso de AirPods conectados, con batería
    case charging    // animación al conectar el cargador
    case volume      // barra de volumen al subir/bajar el sonido
    case expanded       // controles de música
    case expandedShelf  // controles + bandeja con archivos
}

/// Tamaños y posición de la isla. Cambia estos números para ajustarla.
enum IslandSize {
    /// Alto de la píldora cerrada.
    static let pillH: CGFloat = 28
    /// Distancia desde el borde superior de la pantalla. Más chico = más arriba.
    static let topGap: CGFloat = 2

    /// Margen extra de la ventana alrededor de la isla (para que los rebotes y el brillo
    /// no se recorten). La parte transparente no se dibuja.
    static let margin = CGSize(width: 32, height: 14)

    static func mode(expanded: Bool, peeking: Bool, playing: Bool, airpods: Bool,
                     lock: Bool, shelf: Bool, charging: Bool, volume: Bool = false) -> IslandMode {
        if expanded { return shelf ? .expandedShelf : .expanded }
        if lock { return .lock }
        if airpods { return .airpods }
        if volume { return .volume }
        if charging { return .charging }
        if peeking && playing { return .peek }
        return playing ? .playing : .idle
    }

    static func size(for mode: IslandMode) -> CGSize {
        switch mode {
        case .idle:     return CGSize(width: 110, height: pillH)
        case .playing:  return CGSize(width: 180, height: pillH)
        case .lock:     return CGSize(width: 96, height: pillH)
        case .peek:     return CGSize(width: 330, height: 62)
        case .airpods:  return CGSize(width: 310, height: 58)
        case .charging: return CGSize(width: 220, height: 42)
        case .volume:   return CGSize(width: 250, height: 40)
        case .expanded: return CGSize(width: 380, height: 154)
        case .expandedShelf: return CGSize(width: 380, height: 188)
        }
    }

    static func cornerRadius(for mode: IslandMode) -> CGFloat {
        switch mode {
        case .idle, .playing, .lock: return pillH / 2
        case .peek:           return 30
        case .airpods:        return 29   // cápsula completa
        case .charging:       return 21   // cápsula completa
        case .volume:         return 20   // cápsula completa
        case .expanded, .expandedShelf: return 38
        }
    }
}

enum IslandScreen {
    /// Pantalla donde vive la isla: SIEMPRE la principal (la que tiene la barra de menús).
    /// Antes se usaba `NSScreen.main`, que cambia según qué ventana tengas enfocada y
    /// mandaba la isla a otro monitor o a una esquina.
    static var screen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }
}
