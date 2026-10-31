import Foundation
import Combine

/// Preferencias de las letras.
enum LyricsPrefs {
    /// NetEase Cloud Music (servicio no oficial, buena cobertura en música latina y asiática).
    /// Viene APAGADO por defecto; se enciende desde el menú de la cápsula.
    static let netease = "lyricsNetease"
    static var neteaseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: netease) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: netease) }
    }
}

/// Letras desde lrclib.net (gratis, sin llave ni cuenta) y, opcionalmente, otras fuentes.
///
/// La búsqueda se hace EN PARALELO (antes iba una consulta tras otra y con una red lenta
/// podía tardar más de un minuto):
///  1. lrclib `get` con todas las variantes de título / artista / álbum a la vez.
///  2. lrclib `search`, NetEase (si lo activaste) y lyrics.ovh a la vez.
///  3. Si solo hay letra sin tiempos (lrclib, Apple Music en tu biblioteca o lyrics.ovh),
///     se reparte por la duración de la canción y se marca como "aproximada".
/// Los resultados de búsqueda se validan (título y duración parecidos) para no mostrar la
/// letra de otra canción. Se guarda una caché en memoria y, si falla la red, se reintenta.
final class LyricsManager: ObservableObject {
    struct Line: Identifiable { let id: Int; let time: Double; let text: String }

    @Published var lines: [Line] = []
    /// true cuando la letra no vino sincronizada y los tiempos son un cálculo aproximado.
    @Published var approximate = false
    /// Mensaje cuando no hay letra todavía.
    @Published var status = "Buscando letra…"
    private var key = ""
    private var bag = Set<AnyCancellable>()
    private weak var music: MusicManager?
    private var cache: [String: ([Line], Bool)] = [:]

    init(music: MusicManager) {
        self.music = music
        music.$title.combineLatest(music.$artist)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self, weak music] title, artist in
                guard let self, let music else { return }
                self.load(title: title, artist: artist, album: music.album, duration: music.duration)
            }
            .store(in: &bag)
        // Si la duración llega después, se reintenta para afinar la coincidencia.
        music.$duration
            .removeDuplicates()
            .filter { $0 > 0 }
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self, weak music] _ in
                guard let self, let music, self.lines.isEmpty, !music.title.isEmpty else { return }
                self.key = ""   // permite volver a intentar
                self.load(title: music.title, artist: music.artist, album: music.album, duration: music.duration)
            }
            .store(in: &bag)
    }

    // MARK: - Carga

    private func load(title: String, artist: String, album: String, duration: Int, attempt: Int = 0) {
        let k = "\(title)|\(artist)"
        guard !title.isEmpty, k != key else { return }
        key = k
        lines = []
        approximate = false
        status = "Buscando letra…"

        if let hit = cache[k] {
            lines = hit.0
            approximate = hit.1
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.findLyrics(title: title, artist: artist, album: album, duration: duration)
            DispatchQueue.main.async {
                guard self.key == k else { return }
                if let (found, approx) = result, !found.isEmpty {
                    self.cache[k] = (found, approx)
                    self.lines = found
                    self.approximate = approx
                    print("[MiIsla] letra: \(found.count) líneas\(approx ? " (aproximada)" : " (sincronizada)")")
                } else {
                    print("[MiIsla] letra: no encontrada para \(title) — \(artist)")
                    if attempt < 2 {
                        // Puede ser un fallo de red: se reintenta en 20 s sin molestar.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                            guard let self, self.key == k, self.lines.isEmpty else { return }
                            self.key = ""
                            self.load(title: title, artist: artist, album: album,
                                      duration: self.music?.duration ?? duration, attempt: attempt + 1)
                        }
                    }
                    self.status = "No encontré letra\npara esta canción"
                }
            }
        }
    }

    private enum Job {
        case search(String)
        case netease(String, String)
        case ovh(String, String)
    }
    private enum Found {
        case hits([[String: Any]])
        case lrc(String)
        case plain(String)
    }

    private func findLyrics(title: String, artist: String, album: String, duration: Int) -> ([Line], Bool)? {
        let titles = unique([title, Self.cleanTitle(title)])
        let artists = unique([artist, Self.firstArtist(artist)])
        var plain: String?

        // 1) Coincidencias exactas de lrclib, todas a la vez.
        var gets: [[String: String]] = []
        for t in titles {
            for a in artists {
                for withAlbum in [true, false] {
                    gets.append(["track_name": t, "artist_name": a,
                                 "album_name": withAlbum ? album : "",
                                 "duration": duration > 0 ? String(duration) : ""])
                }
            }
        }
        let exact = Self.parallel(gets) { Self.getJSON("https://lrclib.net/api/get", $0) as? [String: Any] }.compactMap { $0 }
        for json in exact {
            if let s = json["syncedLyrics"] as? String, !s.isEmpty { return (Self.parse(s), false) }
        }
        for json in exact where plain == nil {
            if let p = json["plainLyrics"] as? String, !p.isEmpty { plain = p }
        }

        // 2) Búsqueda de lrclib + NetEase + lyrics.ovh, todo a la vez.
        let cleanT = titles.last ?? title
        let firstA = artists.last ?? artist
        var jobs: [Job] = unique(["\(firstA) \(cleanT)", "\(artist) \(title)", cleanT]).map { .search($0) }
        if LyricsPrefs.neteaseEnabled {
            for t in titles { for a in artists { jobs.append(.netease(t, a)) } }
        }
        jobs.append(.ovh(firstA, cleanT))

        let results = Self.parallel(jobs) { job -> Found? in
            switch job {
            case .search(let q):
                guard let arr = Self.getJSON("https://lrclib.net/api/search", ["q": q]) as? [[String: Any]] else { return nil }
                return .hits(arr)
            case .netease(let t, let a):
                return Self.neteaseSynced(title: t, artist: a).map { Found.lrc($0) }
            case .ovh(let a, let t):
                return Self.ovhPlain(artist: a, title: t).map { Found.plain($0) }
            }
        }

        // 2a) lrclib search: primero sincronizada, luego texto simple (solo resultados plausibles).
        var hits: [[String: Any]] = []
        for case .hits(let arr)? in results {
            hits += arr.filter { Self.plausible($0, titles: titles, artists: artists, duration: duration) }
        }
        let ranked = hits.sorted {
            abs(($0["duration"] as? Double ?? 0) - Double(duration)) < abs(($1["duration"] as? Double ?? 0) - Double(duration))
        }
        for item in ranked {
            if let s = item["syncedLyrics"] as? String, !s.isEmpty { return (Self.parse(s), false) }
        }
        // 2b) NetEase
        for case .lrc(let lrc)? in results where !lrc.isEmpty {
            let parsed = Self.parse(lrc)
            if !parsed.isEmpty { return (parsed, false) }
        }

        // 3) Texto simple: lrclib → Apple Music (biblioteca) → lyrics.ovh
        if plain == nil {
            for item in ranked { if let p = item["plainLyrics"] as? String, !p.isEmpty { plain = p; break } }
        }
        if plain == nil { plain = music?.currentLyricsTextSync() }
        if plain == nil {
            for case .plain(let p)? in results where !p.isEmpty { plain = p; break }
        }
        if let p = plain, !p.isEmpty {
            return (Self.spread(p, over: duration), true)
        }
        return nil
    }

    // MARK: - Utilidades

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for i in items where !i.isEmpty && seen.insert(i).inserted { out.append(i) }
        return out
    }

    /// Ejecuta varias consultas a la vez y devuelve los resultados en el mismo orden.
    private static func parallel<I, O>(_ inputs: [I], _ work: @escaping (I) -> O?) -> [O?] {
        guard !inputs.isEmpty else { return [] }
        var out = [O?](repeating: nil, count: inputs.count)
        let lock = NSLock()
        // concurrentPerform limita los hilos al número de núcleos; las consultas son de red
        // (esperan), así que se lanzan con un grupo para que corran todas juntas.
        let group = DispatchGroup()
        for (i, input) in inputs.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = work(input)
                lock.lock(); out[i] = r; lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return out
    }

    /// Minúsculas, sin acentos y solo letras y números.
    private static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// ¿Este resultado de búsqueda es de la misma canción? (título parecido y duración cercana)
    private static func plausible(_ item: [String: Any], titles: [String], artists: [String], duration: Int) -> Bool {
        let name = norm(item["trackName"] as? String ?? "")
        let who = norm(item["artistName"] as? String ?? "")
        guard !name.isEmpty else { return false }
        let titleOK = titles.map(norm).contains { !$0.isEmpty && ($0.contains(name) || name.contains($0)) }
        let artistOK = !who.isEmpty && artists.map(norm).contains { !$0.isEmpty && ($0.contains(who) || who.contains($0)) }
        let d = item["duration"] as? Double ?? 0
        let durOK = duration <= 0 || d == 0 || abs(d - Double(duration)) <= 6
        return titleOK && durOK && (artistOK || (duration > 0 && d > 0))
    }

    /// "Canción (feat. X) - Remastered 2011" → "Canción"
    static func cleanTitle(_ t: String) -> String {
        var s = t
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#, #"(?i)\s+(feat|ft|with)\.?\s+.*$"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "Ovi & Junior H" → "Ovi"
    static func firstArtist(_ a: String) -> String {
        let seps = [" & ", ", ", " feat. ", " ft. ", " x ", " X ", " y ", " con "]
        var s = a
        for sep in seps {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Busca la canción en el catálogo público de NetEase y trae su letra LRC (servicio no oficial).
    private static func neteaseSynced(title: String, artist: String) -> String? {
        let headers = ["Referer": "https://music.163.com"]
        guard let search = getJSON("https://music.163.com/api/search/get",
                                   ["s": "\(title) \(artist)", "type": "1", "limit": "6"], headers: headers) as? [String: Any],
              let songs = (search["result"] as? [String: Any])?["songs"] as? [[String: Any]], !songs.isEmpty
        else { return nil }
        let wanted = norm(firstArtist(artist))
        let wantedTitle = norm(title)
        let match = songs.first { song in
            let names = ((song["artists"] as? [[String: Any]]) ?? []).compactMap { ($0["name"] as? String).map(norm) }
            let songTitle = norm(song["name"] as? String ?? "")
            let artistOK = names.contains { !$0.isEmpty && ($0.contains(wanted) || wanted.contains($0)) }
            let titleOK = !songTitle.isEmpty && (songTitle.contains(wantedTitle) || wantedTitle.contains(songTitle))
            return artistOK && titleOK
        }
        guard let id = match?["id"] as? Int,
              let lyric = getJSON("https://music.163.com/api/song/lyric", ["id": String(id), "lv": "1"], headers: headers) as? [String: Any],
              let lrc = (lyric["lrc"] as? [String: Any])?["lyric"] as? String else { return nil }
        return lrc
    }

    /// Letra de texto simple desde lyrics.ovh (gratis, sin llave).
    private static func ovhPlain(artist: String, title: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let a = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let t = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)"),
              let json = getJSON(url: url) as? [String: Any],
              let text = json["lyrics"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func getJSON(_ base: String, _ params: [String: String], headers: [String: String] = [:]) -> Any? {
        var comps = URLComponents(string: base)!
        comps.queryItems = params.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        return getJSON(url: url, headers: headers)
    }

    /// Sesión propia: sin caché y con tiempos cortos, para que una red lenta no trabe la búsqueda.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 9
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static func getJSON(url: URL, headers: [String: String] = [:]) -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.assumesHTTP3Capable = false   // evita los cortes de QUIC que se veían en la consola
        request.setValue("MiIsla/1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var out: Any?
        session.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                out = try? JSONSerialization.jsonObject(with: data)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return out
    }

    /// LRC → líneas con tiempo.
    private static func parse(_ lrc: String) -> [Line] {
        var out: [Line] = []
        for raw in lrc.split(separator: "\n") {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { continue }
            let text = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
            out.append(Line(id: out.count, time: m * 60 + s, text: text))
        }
        return out
    }

    /// Letra sin tiempos: se reparte por la duración (desde el seg. 6 hasta 8 s antes del final).
    private static func spread(_ text: String, over duration: Int) -> [Line] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else { return [] }
        let total = Double(duration > 0 ? duration : 200)
        let start = 6.0, end = max(start + 10, total - 8)
        let step = (end - start) / Double(rows.count)
        return rows.enumerated().map { Line(id: $0.offset, time: start + Double($0.offset) * step, text: $0.element) }
    }
}
