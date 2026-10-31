import AppKit

/// Dónde está abierta la pestaña de YouTube Music (navegador, ventana y pestaña).
struct YTTarget {
    var browser: String      // nombre para AppleScript, p. ej. "Google Chrome"
    var bundleID: String
    var safari: Bool
    var window: Int
    var tab: Int
}

/// Soporte para YouTube Music (music.youtube.com) abierto en un navegador.
///
/// macOS no deja leer "lo que suena" de otras apps, así que se le pregunta a la pestaña por
/// AppleScript: título, artista, portada, tiempo y estado salen de la propia página
/// (`navigator.mediaSession` y el `<video>`), y los controles se mandan igual.
///
/// REQUISITO (una sola vez, en tu navegador):
///   · Chrome / Brave / Edge / Arc:  menú Ver → Desarrollador → "Permitir JavaScript desde Eventos de Apple"
///   · Safari: Ajustes → Avanzado → "Mostrar funciones para desarrolladores web", luego
///     menú Desarrollo → "Permitir JavaScript desde Eventos de Apple"
/// macOS también preguntará si MiIsla puede controlar el navegador: acepta.
extension MusicManager {
    private static let browsers: [(bundle: String, name: String, safari: Bool)] = [
        ("com.google.Chrome", "Google Chrome", false),
        ("com.brave.Browser", "Brave Browser", false),
        ("com.microsoft.edgemac", "Microsoft Edge", false),
        ("company.thebrowser.Browser", "Arc", false),
        ("com.vivaldi.Vivaldi", "Vivaldi", false),
        ("org.chromium.Chromium", "Chromium", false),
        ("com.apple.Safari", "Safari", true)
    ]

    static var youTubeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ytMusicEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ytMusicEnabled") }
    }

    // MARK: - Vigilante

    func startYouTubeWatcher() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollYouTube() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        ytTimer = timer
    }

    private static let infoJS = """
    (function(){var v=document.querySelector('video');if(!v){return '';}\
    var m=(navigator.mediaSession&&navigator.mediaSession.metadata)||null;var a='';\
    if(m&&m.artwork&&m.artwork.length){a=m.artwork[m.artwork.length-1].src;}\
    return JSON.stringify({t:m?m.title:'',a:m?m.artist:'',al:m?m.album:'',i:a,p:!v.paused,\
    c:v.currentTime,d:isFinite(v.duration)?v.duration:0});})()
    """

    private func pollYouTube() {
        guard Self.youTubeEnabled, !ytBusy, Date() >= ytNextPoll else { return }
        // Si Apple Music está sonando, tiene prioridad.
        if source == .appleMusic && isPlaying { return }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let candidates = Self.browsers.filter { running.contains($0.bundle) }
        guard !candidates.isEmpty else {
            youTubeGone()
            ytNextPoll = Date().addingTimeInterval(6)   // sin navegador abierto: casi no gasta nada
            return
        }

        ytBusy = true
        ytQueue.async { [weak self] in
            guard let self else { return }
            var found: [(YTTarget, [String: Any])] = []
            for b in candidates {
                guard let out = self.runScript(self.scanScript(browser: b.name, safari: b.safari)) else { continue }
                for entry in out.components(separatedBy: "~~~") where !entry.isEmpty {
                    let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2,
                          let ids = Optional(parts[0].split(separator: ",").compactMap { Int($0) }), ids.count == 2,
                          let data = parts[1].data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    found.append((YTTarget(browser: b.name, bundleID: b.bundle, safari: b.safari,
                                           window: ids[0], tab: ids[1]), json))
                }
            }
            DispatchQueue.main.async {
                self.ytBusy = false
                // Con música de YouTube se consulta cada 2 s; si no hay pestañas, cada 8 s.
                self.ytNextPoll = Date().addingTimeInterval(found.isEmpty ? 8 : 2)
                self.applyYouTube(found)
            }
        }
    }

    private func applyYouTube(_ found: [(YTTarget, [String: Any])]) {
        guard !found.isEmpty else { youTubeGone(); return }
        let playing = found.first { ($0.1["p"] as? Bool) == true }
        guard let (target, info) = playing ?? found.first else { return }
        ytTarget = target

        let isPlayingNow = (info["p"] as? Bool) == true
        if !isPlayingNow {
            // Pausada: si ya era la fuente actual, solo se refleja la pausa.
            if source == .youtubeMusic { self.isPlaying = false }
            return
        }
        if source == .appleMusic && isPlaying { return }

        let title = info["t"] as? String ?? ""
        let artist = info["a"] as? String ?? ""
        let album = info["al"] as? String ?? ""
        let art = info["i"] as? String ?? ""
        let current = Int((info["c"] as? Double ?? 0).rounded())
        let total = Int((info["d"] as? Double ?? 0).rounded())

        source = .youtubeMusic
        isPlaying = true
        hasTrack = !title.isEmpty
        self.title = title
        self.artist = artist
        self.album = album
        if total > 0 { duration = total }
        if abs(current - position) > 1 { position = current }

        let key = "yt|\(title)|\(artist)|\(album)"
        if key != lastTrackKey {
            lastTrackKey = key
            artwork = nil
            position = current
            isFavorite = false
            loadYouTubeArtwork(art, key: key)
        }
    }

    private func youTubeGone() {
        if source == .youtubeMusic, isPlaying { isPlaying = false }
    }

    private func loadYouTubeArtwork(_ urlString: String, key: String) {
        // Pide la versión grande (las portadas de YouTube terminan en =w60-h60, etc.).
        let big = urlString.replacingOccurrences(of: #"=w\d+-h\d+.*$"#, with: "=w544-h544-l90-rj", options: .regularExpression)
        guard let url = URL(string: big.isEmpty ? urlString : big) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { if self.lastTrackKey == key { self.artwork = image } }
        }.resume()
    }

    // MARK: - Controles

    func ytPlayPause() { ytRun("(function(){var v=document.querySelector('video');if(v){if(v.paused){v.play();}else{v.pause();}}})()") }
    func ytNext() { ytRun("(function(){var b=document.querySelector('.next-button');if(b){b.click();}})()") }
    func ytPrevious() { ytRun("(function(){var b=document.querySelector('.previous-button');if(b){b.click();}})()") }
    func ytSeek(_ seconds: Int) {
        ytRun("(function(){var v=document.querySelector('video');if(v){v.currentTime=\(seconds);}})()")
    }
    func ytLike() {
        ytRun("(function(){var b=document.querySelector('ytmusic-like-button-renderer #button-shape-like button')||document.querySelector('ytmusic-like-button-renderer .like');if(b){b.click();}})()")
    }

    private func ytRun(_ js: String) {
        guard let t = ytTarget else { return }
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if t.safari {
            script = "tell application \"Safari\" to do JavaScript \"\(escaped)\" in (tab \(t.tab) of window \(t.window))"
        } else {
            script = "tell application \"\(t.browser)\" to execute (tab \(t.tab) of window \(t.window)) javascript \"\(escaped)\""
        }
        ytQueue.async { [weak self] in _ = self?.runScript(script) }
    }

    /// Nombre corto y icono real de la app donde suena (Música o el navegador).
    var sourceAppName: String {
        switch source {
        case .appleMusic: return "Música"
        case .youtubeMusic: return ytTarget?.browser ?? "YouTube Music"
        }
    }

    var sourceAppIcon: NSImage? {
        let bundle: String
        switch source {
        case .appleMusic: bundle = "com.apple.Music"
        case .youtubeMusic: bundle = ytTarget?.bundleID ?? "com.apple.Safari"
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Abre la app donde suena la canción: Música, o el navegador en la pestaña de YouTube Music.
    func openSource() {
        switch source {
        case .appleMusic:
            // `reopen` hace que Música abra su ventana aunque la app ya estuviera abierta sin ventanas.
            scriptQueue.async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Music\"\nactivate\nreopen\nend tell")?.executeAndReturnError(&error)
                if error != nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        case .youtubeMusic:
            guard let t = ytTarget else { return }
            let script: String
            if t.safari {
                script = """
                tell application "Safari"
                    activate
                    set current tab of window \(t.window) to tab \(t.tab) of window \(t.window)
                end tell
                """
            } else {
                script = """
                tell application "\(t.browser)"
                    activate
                    set active tab index of window \(t.window) to \(t.tab)
                    set index of window \(t.window) to 1
                end tell
                """
            }
            ytQueue.async { [weak self] in _ = self?.runScript(script) }
        }
    }

    // MARK: - AppleScript

    private func scanScript(browser: String, safari: Bool) -> String {
        let js = Self.infoJS.replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let call = safari ? "do JavaScript \"\(js)\" in (tab ti of w)" : "execute (tab ti of w) javascript \"\(js)\""
        // Se piden TODAS las URLs de una ventana en una sola llamada (mucho más rápido que
        // preguntar pestaña por pestaña) y solo se ejecuta JavaScript en las de YouTube Music.
        return """
        set acc to ""
        tell application "\(browser)"
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set urls to {}
                try
                    set urls to URL of every tab of w
                end try
                set ti to 0
                repeat with u in urls
                    set ti to ti + 1
                    try
                        if (u as text) contains "music.youtube.com" then
                            set r to \(call)
                            if r is not "" and r is not missing value then set acc to acc & wi & "," & ti & "|" & r & "~~~"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return acc
        """
    }

    /// Ejecuta AppleScript (en un hilo de fondo) y devuelve el texto, o nil si falló.
    private func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, !ytWarned {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            if message.localizedCaseInsensitiveContains("javascript") {
                ytWarned = true
                print("[MiIsla] YouTube Music: activa «Permitir JavaScript desde Eventos de Apple» en el menú Ver → Desarrollador del navegador (Safari: menú Desarrollo).")
            }
        }
        return result?.stringValue
    }
}
