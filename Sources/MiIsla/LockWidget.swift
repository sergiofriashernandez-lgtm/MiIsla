import SwiftUI
import AppKit
import Combine

/// Widget de música para la pantalla de bloqueo: portada grande y, debajo, un
/// reproductor de cristal con título, progreso, controles, estrella y salida de audio.
///
/// Se muestra al bloquear la Mac (si hay una canción) y se oculta al desbloquear.
/// Depende de `SkyLight` (EXPERIMENTAL), igual que la isla sobre la pantalla de bloqueo.
enum LockWidget {
    static let artworkSize: CGFloat = 300
    static let playerHeight: CGFloat = 118
    static let spacing: CGFloat = 16
    /// Margen transparente alrededor (para que quepa la sombra).
    static let margin: CGFloat = 30

    /// Tarjeta compacta (la que se ve junto al aviso de contraseña).
    static let compactSize = CGSize(width: 290, height: 150)
    static let compactPanel = CGSize(width: 290 + 60, height: 150 + 60)

    static var panelSize: CGSize {
        CGSize(width: artworkSize + margin * 2,
               height: artworkSize + spacing + playerHeight + margin * 2)
    }
}

final class LockWidgetModel: ObservableObject {
    @Published var visible = false
    /// false = tarjeta compacta; true = pantalla completa con portada grande.
    @Published var expanded = false
}

// MARK: - Controlador (la ventana)

final class LockWidgetController {
    private let panel: NSPanel        // tarjeta compacta
    private let fullPanel: NSPanel    // pantalla completa (al tocar la portada)
    private let widget = LockWidgetModel()
    private let status = LockStatus()
    private let lyrics: LyricsManager
    private let awake = KeepAwake()
    private let output: AudioOutputManager
    private let music: MusicManager
    private var delegatedWith: LockTechnique?
    private var hideWork: DispatchWorkItem?
    private var autoOffWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(music: MusicManager, output: AudioOutputManager) {
        self.music = music
        self.output = output
        self.lyrics = LyricsManager(music: music)
        panel = Self.makePanel(
            LockWidgetView(widget: widget, music: music, output: output, status: status, lyrics: lyrics, fullScreen: false))
        fullPanel = Self.makePanel(
            LockWidgetView(widget: widget, music: music, output: output, status: status, lyrics: lyrics, fullScreen: true))
        // Al tocar la portada aparece la ventana de pantalla completa (con desvanecido)
        // y, al volver a tocar, se desvanece y se oculta. Así nunca se redimensiona una ventana.
        widget.$expanded
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.fullPanel.setFrame(IslandScreen.screen.frame, display: true)
                    self.fullPanel.orderFrontRegardless()
                    SkyLight.delegate(self.fullPanel, technique: LockTechnique.current, quiet: true)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self, !self.widget.expanded else { return }
                        self.fullPanel.orderOut(nil)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private static func makePanel<V: View>(_ view: V) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []          // el tamaño lo manda place(), no SwiftUI
        panel.contentView = hosting
        return panel
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "lockScreenEnabled2") as? Bool ?? true
    }

    func show() {
        print("[MiIsla] widget de bloqueo: activado=\(enabled), hay canción=\(music.hasTrack)")
        guard enabled else { print("[MiIsla] widget de bloqueo desactivado en el menú."); return }
        guard music.hasTrack else {
            print("[MiIsla] No se muestra: Music no tiene una canción cargada (¿está reproduciendo?).")
            return
        }
        hideWork?.cancel()
        widget.expanded = false
        place()
        panel.orderFrontRegardless()
        print("[MiIsla] widget de bloqueo: ventana mostrada, número=\(panel.windowNumber), marco=\(panel.frame)")
        let technique = LockTechnique.current
        if delegatedWith != technique, SkyLight.delegate(panel, technique: technique) {
            delegatedWith = technique
        }
        music.startProgressUpdates()
        status.refresh(output: output)
        status.startPolling(output: output)
        awake.start()
        widget.visible = true

        // El widget se apaga solo pasado el tiempo elegido (10 min por defecto).
        autoOffWork?.cancel()
        let minutes = UserDefaults.standard.object(forKey: LockPrefs.awakeMinutes) as? Double ?? 10
        let off = DispatchWorkItem { [weak self] in
            print("[MiIsla] widget de bloqueo apagado tras \(Int(minutes)) min")
            self?.hide()
        }
        autoOffWork = off
        DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60, execute: off)

        // La pantalla de bloqueo de macOS puede crearse un instante después del aviso
        // y quedar encima: se vuelve a traer la ventana al frente varias veces.
        for delay in [0.3, 0.8, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.widget.visible else { return }
                self.panel.orderFrontRegardless()
                SkyLight.delegate(self.panel, technique: LockTechnique.current, quiet: true)
                if self.widget.expanded {
                    self.fullPanel.orderFrontRegardless()
                    SkyLight.delegate(self.fullPanel, technique: LockTechnique.current, quiet: true)
                }
            }
        }
    }

    /// Para volver a aplicar la técnica después de cambiarla en el menú.
    func resetDelegation() { delegatedWith = nil }

    func hide() {
        autoOffWork?.cancel()
        widget.visible = false
        widget.expanded = false
        awake.stop()
        status.stopPolling()
        music.stopProgressUpdates()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.fullPanel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Tarjeta compacta: centrada, a ~60 % de la altura (arriba del aviso de contraseña).
    /// Expandida: cubre toda la pantalla.
    private func place() {
        let screen = IslandScreen.screen
        let size = LockWidget.compactPanel
        let top = screen.frame.height * 0.69
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - top - size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// MARK: - Vista

struct LockWidgetView: View {
    @ObservedObject var widget: LockWidgetModel
    @ObservedObject var music: MusicManager
    @ObservedObject var output: AudioOutputManager
    @ObservedObject var status: LockStatus
    @ObservedObject var lyrics: LyricsManager
    @AppStorage(LockPrefs.glassStyle) private var glassStyle = "clear"
    @AppStorage(LockPrefs.fullArt) private var fullArt = true
    @AppStorage(LockPrefs.lyrics) private var showLyrics = true
    @AppStorage(LockPrefs.syncMs) private var syncMs = 0.0
    @AppStorage(LockPrefs.glassArt) private var glassArt = false
    private var isClear: Bool { glassStyle == "clear" }
    /// false = la tarjeta compacta; true = la vista de pantalla completa.
    let fullScreen: Bool

    var body: some View {
        Group {
            if fullScreen {
                expandedLayout
                    .opacity(widget.expanded && widget.visible ? 1 : 0)
            } else {
                compactCard
                    .opacity(widget.visible ? 1 : 0)
                    .scaleEffect(widget.visible ? 1 : 0.94)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.35), value: widget.expanded)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: widget.visible)
    }

    // MARK: Tarjeta compacta

    private var compactCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                Button { if fullArt { widget.expanded = true } } label: {
                    smallArtwork
                }
                .buttonStyle(PressableStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 12)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerBars(active: music.isPlaying).scaleEffect(0.7)
            }
            HStack(spacing: 8) {
                Text(Self.format(music.position))
                progressBar
                Text("-" + Self.format(max(0, music.duration - music.position)))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .opacity(0.75)
            controls
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: LockWidget.compactSize.width, height: LockWidget.compactSize.height)
        .modifier(LockGlass(radius: 32))
        .environment(\.colorScheme, .dark)
    }

    private var smallArtwork: some View {
        Group {
            if let image = music.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .flipOnNewArtwork(music.artwork)
    }

    // MARK: Pantalla completa (al tocar la portada)

    private var expandedLayout: some View {
        GeometryReader { geo in
            let hasLyrics = showLyrics
            ZStack {
                backgroundArt
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { widget.expanded = false }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 2) {
                        Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                            .locale(Locale(identifier: "en"))))
                            .font(.system(size: 22, weight: .semibold, design: .serif))
                        Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
                            .locale(Locale(identifier: "en_GB"))))
                            .font(.system(size: 110, weight: .bold, design: .serif))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.25), radius: 8)
                }
                .allowsHitTesting(false)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.14)

                statusRow
                    .allowsHitTesting(false)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.14 + 90)

                // Reproductor al estilo del mini reproductor de Apple Music:
                // portada y controles a la izquierda, letra grande a la derecha.
                HStack(alignment: .center, spacing: 64) {
                    playerColumn
                    if hasLyrics {
                        lyricsColumn
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height * 0.60)

                LockVolumeSlider()
                    .position(x: geo.size.width - 150, y: 52)

                // Botón de letra (como el de Apple Music): toca para mostrar u ocultar la letra.
                Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showLyrics.toggle() } } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .modifier(LockGlass(radius: 22, always: true))
                        .environment(\.colorScheme, .dark)
                }
                .buttonStyle(PressableStyle())
                .position(x: geo.size.width - 90, y: geo.size.height - 80)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: Columna del reproductor

    private var playerColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { widget.expanded = false } label: { artwork }
                .buttonStyle(PressableStyle())

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 15, weight: .medium)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { music.toggleFavorite() } label: {
                    Image(systemName: music.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(music.isFavorite ? Color(red: 1.0, green: 0.27, blue: 0.40) : .white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.16)))
                }
                .buttonStyle(PressableStyle())
            }

            VStack(spacing: 5) {
                seekBar
                HStack {
                    Text(Self.format(music.position))
                    Spacer()
                    Text("-" + Self.format(max(0, music.duration - music.position)))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .opacity(0.7)
            }

            HStack {
                modeButton("shuffle", on: music.shuffleOn) { music.toggleShuffle() }
                Spacer()
                button("backward.fill", size: 26) { music.previous() }
                Spacer()
                button(music.isPlaying ? "pause.fill" : "play.fill", size: 38) { music.playPause() }
                Spacer()
                button("forward.fill", size: 26) { music.next() }
                Spacer()
                modeButton(music.repeatMode == 2 ? "repeat.1" : "repeat", on: music.repeatMode != 0) { music.toggleRepeat() }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 6)
        .frame(width: LockWidget.artworkSize)
    }

    private func modeButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 1 : 0.5))
                .frame(width: 36, height: 30)
                .background(Capsule().fill(.white.opacity(on ? 0.2 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// Barra de progreso gruesa; toca o arrastra para saltar a ese punto.
    private var seekBar: some View {
        GeometryReader { geo in
            let fraction = music.duration > 0 ? min(1, max(0, Double(music.position) / Double(music.duration))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(.white.opacity(0.92))
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(.linear(duration: 1.0), value: music.position)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                guard music.duration > 0 else { return }
                music.seek(to: Int(Double(music.duration) * min(1, max(0, g.location.x / geo.size.width))))
            })
        }
        .frame(height: 6)
    }

    // MARK: Letra (a la derecha)

    private var lyricsColumn: some View {
        Group {
            if lyrics.lines.isEmpty {
                Text(lyrics.status)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 420, height: LockWidget.artworkSize + 150, alignment: .trailing)
            } else {
                syncedLyrics
                    .overlay(alignment: .bottomTrailing) {
                        if lyrics.approximate {
                            Text("Letra sin sincronizar (aproximada)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
            }
        }
    }

    /// Letra COMPLETA: se puede ver toda y la línea actual se centra sola.
    private var syncedLyrics: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let t = music.preciseTime(at: ctx.date) + syncMs / 1000
            let idx = lyrics.lines.lastIndex(where: { $0.time <= t }) ?? -1
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .trailing, spacing: 22) {
                        Color.clear.frame(height: 110)
                        ForEach(lyrics.lines) { line in
                            let d = abs(line.id - idx)
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: d == 0 ? 30 : 24, weight: .bold))
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundStyle(.white.opacity(d == 0 ? 1 : max(0.22, 0.62 - Double(d) * 0.1)))
                                .blur(radius: d == 0 ? 0 : min(Double(d), 4) * 1.4)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 150)
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: idx)
                }
                .onChange(of: idx) { _, new in
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                        proxy.scrollTo(max(0, new), anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(max(0, idx), anchor: .center) }
            }
            .frame(width: 420, height: LockWidget.artworkSize + 150, alignment: .center)
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                 startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.2), radius: 6)
        }
    }

    /// Fondo: la portada muy desenfocada, como en el reproductor de Apple.
    private var backgroundArt: some View {
        ZStack {
            WaterBackground(tiny: music.tinyArtwork, palette: music.palette)
            // Velo suave: colores de la canción, algo más tranquilos.
            Color.black.opacity(0.14)
        }
        .clipped()
    }

    /// Fila bajo el reloj: No molestar, clima, batería de la Mac y de los AirPods.
    private var statusRow: some View {
        HStack(spacing: 22) {
            if status.dnd { item("moon.fill", "DND") }
            if let t = status.temp { item(status.weatherSymbol, "\(t)°") }
            item(status.batterySymbol, "\(status.battery)%")
            if let a = status.airpods { item("airpodspro", "\(a)%") }
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .modifier(LockGlass(radius: 22, always: true))
        .environment(\.colorScheme, .dark)
    }

    private func item(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? .white.opacity(0.95))
            Text(text).font(.system(size: 19, weight: .semibold, design: .rounded))
        }
    }

    private var controls: some View {
        HStack {
            button(music.isFavorite ? "star.fill" : "star", size: 15,
                   tint: music.isFavorite ? Color(red: 1.0, green: 0.27, blue: 0.40) : .white) {
                music.toggleFavorite()
            }
            Spacer()
            button("backward.fill") { music.previous() }
            Spacer()
            button(music.isPlaying ? "pause.fill" : "play.fill", size: 24) { music.playPause() }
            Spacer()
            button("forward.fill") { music.next() }
            Spacer()
            Image(systemName: output.symbol)
                .font(.system(size: output.kind == .airpods ? 20 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
        }
    }

    // MARK: Portada

    private var artwork: some View {
        Group {
            if let image = music.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: LockWidget.artworkSize, height: LockWidget.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .flipOnNewArtwork(music.artwork)
        .padding(glassArt ? 10 : 0)
        .modifier(GlassArtFrame(enabled: glassArt, clear: isClear))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }

    // MARK: Reproductor de cristal

    private var player: some View {
        VStack(spacing: 8) {
            ZStack {
                VStack(spacing: 1) {
                    Text(music.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 12))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                .padding(.horizontal, 28)

                HStack {
                    Spacer()
                    EqualizerBars(active: music.isPlaying)
                        .scaleEffect(0.75)
                }
            }

            HStack(spacing: 8) {
                Text(Self.format(music.position))
                progressBar
                Text("-" + Self.format(max(0, music.duration - music.position)))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .opacity(0.8)

            controls
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: LockWidget.artworkSize, height: LockWidget.playerHeight)
        .modifier(LockGlass(radius: 28))
        .environment(\.colorScheme, .dark)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = music.duration > 0
                ? min(1, max(0, Double(music.position) / Double(music.duration)))
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 1.0), value: music.position)
            }
        }
        .frame(height: 4)
    }

    private func button(_ symbol: String, size: CGFloat = 17, tint: Color = .white,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


/// "Liquid Glass" de macOS 26 (Tahoe). En versiones anteriores, o si Xcode es más viejo
/// que el 26, cae a un cristal esmerilado normal.
struct LiquidGlass: ViewModifier {
    let radius: CGFloat
    /// true = vidrio transparente (el de la tarjeta compacta); false = vidrio normal.
    var clear = false

    /// El Liquid Glass real puede no dibujarse sobre la pantalla de bloqueo; se activa desde el menú.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockGlass") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockGlass") }
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if LiquidGlass.enabled, #available(macOS 26.0, *) {
            content.glassEffect(clear ? .clear : .regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                if clear {
                    // Cristal claro: material en modo claro (esmerilado luminoso, sin teñirse de oscuro).
                    shape.fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .light)
                        .opacity(0.55)
                    shape.fill(Color.white.opacity(0.08))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(0.18))
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08), .white.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: clear ? 1 : 0.6)
            )
    }
}


/// Tarjeta del reproductor: cristal (según el estilo elegido) o fondo oscuro liso.
struct LockGlass: ViewModifier {
    let radius: CGFloat
    /// true = siempre cristal (botones, fila de estado); false = obedece "Tarjeta de cristal".
    var always = false
    @AppStorage(LockPrefs.glassStyle) private var style = "clear"
    @AppStorage(LockPrefs.glassCard) private var card = true

    func body(content: Content) -> some View {
        if card || always {
            content.modifier(LiquidGlass(radius: radius, clear: style == "clear"))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
        }
    }
}

/// Marco de cristal alrededor de la portada ("Portada de cristal").
struct GlassArtFrame: ViewModifier {
    let enabled: Bool
    let clear: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(LiquidGlass(radius: 38, clear: clear)) } else { content }
    }
}

/// Deslizador de volumen del sistema, arriba a la derecha (como en el mini reproductor de Apple Music).
struct LockVolumeSlider: View {
    @State private var level = 0.5
    @State private var dragging = false
    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).opacity(0.8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white.opacity(0.95)).frame(width: max(4, geo.size.width * level))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        level = min(1, max(0, g.location.x / geo.size.width))
                        SystemVolume.set(level)
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 5)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 220, height: 40)
        .modifier(LockGlass(radius: 20, always: true))
        .environment(\.colorScheme, .dark)
        .onAppear { if let v = SystemVolume.get() { level = v } }
        .onReceive(tick) { _ in
            if !dragging, let v = SystemVolume.get() { level = v }
        }
    }
}
