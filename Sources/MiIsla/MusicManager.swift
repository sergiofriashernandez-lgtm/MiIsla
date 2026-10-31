import AppKit
import CoreImage
import Combine

/// Lee lo que suena en Apple Music y manda los controles.
///
/// - Estado de la canción: notificación distribuida "com.apple.Music.playerInfo"
///   (no necesita permisos).
/// - Carátula y controles: AppleScript (macOS pedirá permiso de Automatización
///   la primera vez).
final class MusicManager: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            if oldValue { exactPosition += min(4, Date().timeIntervalSince(exactStamp)) }
            exactStamp = Date()
        }
    }
    @Published var hasTrack = false
    @Published var artwork: NSImage? {
        didSet { processArtwork() }
    }
    @Published var palette: [NSColor] = []   // 4 colores vivos de la portada
    @Published var isFavorite = false
    @Published var tinyArtwork: NSImage?   // miniatura para el fondo desenfocado (barata de dibujar)
    @Published var position: Int = 0 {   // segundos transcurridos
        didSet {
            // Cambios externos (saltar, canción nueva, YouTube): la posición exacta los sigue.
            if !internalTick { exactPosition = Double(position); exactStamp = Date() }
        }
    }
    private var internalTick = false
    /// Posición con decimales tal como la dio Música, y el momento en que se leyó.
    private var exactPosition = 0.0
    private var exactStamp = Date()
    /// Posición con decimales (para sincronizar letras): lo leído de Música + el tiempo transcurrido.
    func preciseTime(at date: Date = Date()) -> Double {
        exactPosition + (isPlaying ? min(4, max(0, date.timeIntervalSince(exactStamp))) : 0)
    }
    @Published var duration: Int = 0    // duración total en segundos

    private var progressTimer: Timer?
    var lastTrackKey = ""
    let scriptQueue = DispatchQueue(label: "miisla.applescript")

    // MARK: Fuente de la música (Apple Music o YouTube Music en el navegador)
    enum Source { case appleMusic, youtubeMusic }
    @Published var source: Source = .appleMusic
    var ytTarget: YTTarget?
    var ytTimer: Timer?
    let ytQueue = DispatchQueue(label: "miisla.youtube")
    var ytWarned = false
    var ytNextPoll = Date.distantPast   // el sondeo de YouTube se frena solo cuando no hay nada
    var ytBusy = false

    init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        refreshFromMusic()
        startYouTubeWatcher()
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Calcula la miniatura y la paleta FUERA del hilo principal (antes se hacía al poner la
    /// portada y trababa la isla un instante en cada canción).
    private func processArtwork() {
        guard let art = artwork else {
            tinyArtwork = nil
            palette = []
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tiny = MusicManager.shrink(art, to: 64)
            let colors = tiny.map { MusicManager.palette(of: $0) } ?? []
            DispatchQueue.main.async {
                guard let self, self.artwork === art else { return }
                self.tinyArtwork = tiny
                self.palette = colors
            }
        }
    }

    /// Miniatura ya desenfocada (64 px + desenfoque gaussiano): al agrandarla a pantalla
    /// completa queda suave, sin bloques, y dibujarla casi no cuesta.
    private static func shrink(_ image: NSImage, to side: CGFloat) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let px = Int(side)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let small = ctx.makeImage() else { return nil }
        let fallback = NSImage(cgImage: small, size: NSSize(width: side, height: side))

        let ci = CIImage(cgImage: small)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return fallback }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(side / 9, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: ci.extent),
              let cg = ciContext.createCGImage(out, from: ci.extent) else { return fallback }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    /// Cuatro colores (uno por cuadrante) de la miniatura, avivados para las manchas de luz.
    private static func palette(of image: NSImage) -> [NSColor] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let rep = NSBitmapImageRep(cgImage: cg)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var out: [NSColor] = []
        for (qx, qy) in [(1, 1), (3, 1), (1, 3), (3, 3)] {
            if let c = rep.colorAt(x: w * qx / 4, y: h * qy / 4)?.usingColorSpace(.sRGB) {
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
                c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
                out.append(NSColor(hue: hue, saturation: min(1, sat * 1.25 + 0.05),
                                   brightness: max(0.65, bri), alpha: 1))
            }
        }
        return out
    }

    // MARK: - Notificación de Apple Music

    @objc private func playerInfoChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let state = info["Player State"] as? String ?? "Stopped"
        let name = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let total = (info["Total Time"] as? NSNumber)?.intValue ?? 0

        DispatchQueue.main.async {
            if state == "Playing" { self.source = .appleMusic }
            else if self.source == .youtubeMusic { return }   // suena YouTube Music: se ignora el aviso de pausa de Apple Music
            self.isPlaying = (state == "Playing")
            self.hasTrack = (state != "Stopped") && !name.isEmpty
            self.title = name
            self.artist = artist
            self.album = album
            if total > 0 { self.duration = total / 1000 }   // la notificación trae la duración en ms

            let key = "\(name)|\(artist)|\(album)"
            if key != self.lastTrackKey {
                self.lastTrackKey = key
                self.artwork = nil
                self.position = 0
                self.isFavorite = false
                if self.hasTrack { self.loadArtwork(); self.refreshFavorite() }
            }
        }
    }

    /// Consulta el estado actual al abrir la app (por si ya estaba sonando algo).
    func refreshFromMusic() {
        let source = """
        if application "Music" is running then
            tell application "Music"
                if player state is not stopped then
                    return {(player state as string), name of current track, artist of current track, album of current track}
                end if
            end tell
        end if
        return {}
        """
        scriptQueue.async {
            guard let desc = NSAppleScript(source: source)?.executeAndReturnError(nil),
                  desc.numberOfItems == 4 else { return }
            let state = desc.atIndex(1)?.stringValue ?? ""
            let name = desc.atIndex(2)?.stringValue ?? ""
            let artist = desc.atIndex(3)?.stringValue ?? ""
            let album = desc.atIndex(4)?.stringValue ?? ""
            DispatchQueue.main.async {
                self.isPlaying = (state == "playing")
                self.hasTrack = !name.isEmpty
                self.title = name
                self.artist = artist
                self.album = album
                self.lastTrackKey = "\(name)|\(artist)|\(album)"
                if self.hasTrack { self.loadArtwork(); self.refreshFavorite() }
            }
        }
    }

    // MARK: - Carátula

    private func loadArtwork() {
        let source = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        let key = lastTrackKey
        let title = self.title
        let artist = self.artist
        scriptQueue.async {
            // 1) Portada local (canciones de tu biblioteca)
            if let desc = NSAppleScript(source: source)?.executeAndReturnError(nil),
               let image = NSImage(data: desc.data) {
                DispatchQueue.main.async { if self.lastTrackKey == key { self.artwork = image } }
                return
            }
            // 2) Si no hay (streaming de Apple Music), se busca en línea
            self.fetchOnlineArtwork(title: title, artist: artist, key: key)
        }
    }

    /// Busca la portada en el buscador público de iTunes.
    private func fetchOnlineArtwork(title: String, artist: String, key: String) {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let small = first["artworkUrl100"] as? String,
                  let artURL = URL(string: small.replacingOccurrences(of: "100x100", with: "300x300"))
            else { return }

            URLSession.shared.dataTask(with: artURL) { [weak self] imgData, _, _ in
                guard let self, let imgData, let image = NSImage(data: imgData) else { return }
                DispatchQueue.main.async {
                    if self.lastTrackKey == key { self.artwork = image }
                }
            }.resume()
        }.resume()
    }

    // MARK: - Progreso de la canción (solo mientras se necesita, p. ej. en la pantalla de bloqueo)

    private var tick = 0
    private var progressSources = Set<String>()

    /// Arranca el reloj de progreso. `source` permite que la isla y la pantalla de bloqueo
    /// lo pidan a la vez sin pisarse (se detiene cuando ya nadie lo necesita).
    func startProgressUpdates(source: String = "lock") {
        progressSources.insert(source)
        refreshModes()
        if progressTimer != nil { updateProgress(); return }
        tick = 0
        updateProgress()
        // El reloj avanza solo cada segundo (no depende de AppleScript, que puede
        // fallar con la Mac bloqueada) y se re-sincroniza con Music cada 4 s.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            if self.isPlaying, self.duration == 0 || self.position < self.duration {
                self.internalTick = true
                self.position += 1
                self.internalTick = false
            }
            if self.tick % 2 == 0 { self.updateProgress() }   // se re-sincroniza con Música cada 2 s
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    func stopProgressUpdates(source: String = "lock") {
        progressSources.remove(source)
        guard progressSources.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Salta a un punto de la canción (segundos).
    func seek(to seconds: Int) {
        position = max(0, seconds)   // también fija la posición exacta
        if self.source == .youtubeMusic { ytSeek(seconds); return }
        let source = "tell application \"Music\" to set player position to \(max(0, seconds))"
        scriptQueue.async { _ = NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }

    /// Letra de texto que Apple Music tenga guardada para la canción actual (solo suele existir
    /// en canciones de tu biblioteca). Se llama desde un hilo de fondo.
    func currentLyricsTextSync() -> String? {
        guard self.source == .appleMusic else { return nil }
        let source = """
        if application "Music" is not running then return ""
        tell application "Music"
            try
                return lyrics of current track
            on error
                return ""
            end try
        end tell
        """
        let text = NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - Aleatorio y repetir

    @Published var shuffleOn = false
    @Published var repeatMode = 0      // 0 = no, 1 = todas, 2 = una

    func refreshModes() {
        guard self.source == .appleMusic else { return }
        let source = """
        if application "Music" is not running then return {false, "off"}
        tell application "Music"
            set sh to false
            set rp to "off"
            try
                set sh to shuffle enabled
            end try
            try
                set rp to (song repeat as string)
            end try
            return {sh, rp}
        end tell
        """
        scriptQueue.async {
            guard let desc = NSAppleScript(source: source)?.executeAndReturnError(nil),
                  desc.numberOfItems == 2 else { return }
            let sh = desc.atIndex(1)?.booleanValue ?? false
            let rp = desc.atIndex(2)?.stringValue ?? "off"
            DispatchQueue.main.async {
                self.shuffleOn = sh
                self.repeatMode = rp == "all" ? 1 : (rp == "one" ? 2 : 0)
            }
        }
    }

    func toggleShuffle() {
        guard self.source == .appleMusic else { return }
        shuffleOn.toggle()
        let source = "tell application \"Music\" to set shuffle enabled to \(shuffleOn)"
        scriptQueue.async { _ = NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }

    func toggleRepeat() {
        guard self.source == .appleMusic else { return }
        repeatMode = (repeatMode + 1) % 3
        let word = ["off", "all", "one"][repeatMode]
        let source = "tell application \"Music\" to set song repeat to \(word)"
        scriptQueue.async { _ = NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }

    private func updateProgress() {
        guard self.source == .appleMusic else { return }   // con YouTube Music el tiempo lo da el navegador
        let source = """
        if application "Music" is not running then return {-1, 0}
        tell application "Music"
            set p to -1
            set d to 0
            try
                set p to player position
            end try
            try
                set d to round (duration of current track)
            end try
            return {p, d}
        end tell
        """
        scriptQueue.async {
            guard let desc = NSAppleScript(source: source)?.executeAndReturnError(nil),
                  desc.numberOfItems == 2 else { return }
            // La posición llega con decimales (p. ej. "12.345"); el separador puede ser coma.
            let text = (desc.atIndex(1)?.stringValue ?? "-1").replacingOccurrences(of: ",", with: ".")
            let exact = Double(text) ?? -1
            let dur = Int(desc.atIndex(2)?.int32Value ?? 0)
            DispatchQueue.main.async {
                // -1 = Music no contestó: se conserva el contador local (antes se ponía en 0).
                if exact >= 0 {
                    let pos = Int(exact)
                    if abs(pos - self.position) > 1 || self.position == 0 { self.position = pos }
                    self.exactPosition = exact
                    self.exactStamp = Date()
                }
                if dur > 0 { self.duration = dur }   // si falla, se conserva la de la notificación
                else if self.duration == 0 { self.fetchOnlineDuration() }
            }
        }
    }

    private var durationKey = ""

    /// Si Music no entrega la duración (pasa con algunas canciones de streaming),
    /// se toma de la búsqueda pública de iTunes.
    private func fetchOnlineDuration() {
        let key = lastTrackKey
        guard key != durationKey, !title.isEmpty else { return }
        durationKey = key
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let ms = first["trackTimeMillis"] as? Int, ms > 0 else { return }
            DispatchQueue.main.async {
                if self.lastTrackKey == key, self.duration == 0 { self.duration = ms / 1000 }
            }
        }.resume()
    }

    // MARK: - Favoritos (la estrella de Apple Music)

    /// Pregunta a Music si la canción actual está en favoritos.
    func refreshFavorite() {
        let source = """
        tell application "Music"
            try
                return favorited of current track
            on error
                try
                    return loved of current track
                on error
                    return false
                end try
            end try
        end tell
        """
        let key = lastTrackKey
        scriptQueue.async {
            guard let desc = NSAppleScript(source: source)?.executeAndReturnError(nil) else { return }
            let value = desc.booleanValue
            DispatchQueue.main.async { if self.lastTrackKey == key { self.isFavorite = value } }
        }
    }

    /// Agrega o quita la canción de favoritos. La estrella cambia al instante y
    /// luego se confirma con lo que responde Music (si no puede, vuelve atrás).
    func toggleFavorite() {
        isFavorite.toggle()
        if self.source == .youtubeMusic { ytLike(); return }
        let source = """
        tell application "Music"
            try
                set favorited of current track to (not (favorited of current track))
                return favorited of current track
            on error
                try
                    set loved of current track to (not (loved of current track))
                    return loved of current track
                on error
                    return false
                end try
            end try
        end tell
        """
        let key = lastTrackKey
        scriptQueue.async {
            guard let desc = NSAppleScript(source: source)?.executeAndReturnError(nil) else { return }
            let value = desc.booleanValue
            DispatchQueue.main.async { if self.lastTrackKey == key { self.isFavorite = value } }
        }
    }

    // MARK: - Controles

    func playPause() {
        if self.source == .youtubeMusic { ytPlayPause(); isPlaying.toggle(); return }
        run("tell application \"Music\" to playpause")
    }
    func next() {
        if self.source == .youtubeMusic { ytNext(); return }
        run("tell application \"Music\" to next track")
    }
    func previous() {
        if self.source == .youtubeMusic { ytPrevious(); return }
        run("tell application \"Music\" to previous track")
    }

    private func run(_ source: String) {
        scriptQueue.async {
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }
}
