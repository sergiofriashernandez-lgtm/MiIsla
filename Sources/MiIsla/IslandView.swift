import SwiftUI
import UniformTypeIdentifiers

/// Estado compartido entre la vista y el panel de la ventana.
final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var peeking = false
    @Published var shelf: [URL] = []   // archivos soltados en la isla
    @Published var launching = false   // pulso breve cuando se abre la app de música
    @Published var flashID = 0         // sube cada vez que hay que lanzar el destello de brillo
    @Published var pop = false         // rebote corto al aparecer un aviso
    @Published var shakeCount = 0      // sacudida (p. ej. al desconectar los AirPods)

    /// Destello de luz por el borde + pequeño rebote.
    func flash() {
        flashID += 1
        pop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in self?.pop = false }
    }

    func shake() { shakeCount += 1 }

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?

    /// Se abre tras una pausa corta (evita aperturas por accidente al pasar
    /// el mouse) y se cierra con retraso (evita el parpadeo en los bordes).
    func setHover(_ inside: Bool) {
        if inside {
            closeWork?.cancel()
            guard !expanded else { return }
            openWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.openNow() }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            openWork?.cancel()
            guard expanded else { return }
            closeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.expanded = false }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Pulso de la isla (como si "saliera" la app) y cierre de la vista expandida.
    func launchPulse() {
        launching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            self?.launching = false
            self?.expanded = false
        }
    }

    func openNow() {
        closeWork?.cancel()
        peekWork?.cancel()
        peeking = false
        expanded = true
    }

    /// Asoma la isla 3 segundos (al cambiar de canción).
    func peek() {
        guard !expanded else { return }
        peekWork?.cancel()
        peeking = true
        let work = DispatchWorkItem { [weak self] in self?.peeking = false }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: MusicManager
    @ObservedObject var airpods: AirPodsManager
    @ObservedObject var lock: LockManager
    @ObservedObject var output: AudioOutputManager
    @ObservedObject var power: PowerManager
    @ObservedObject var volume: VolumeManager

    @Namespace private var ns
    @State private var dropTargeted = false

    private let pillH = IslandSize.pillH

    /// Resorte con rebote, parecido al de la Dynamic Island de Apple.
    private static let bounce = Animation.spring(response: 0.45, dampingFraction: 0.68)

    private var mode: IslandMode {
        IslandSize.mode(expanded: model.expanded, peeking: model.peeking,
                        playing: music.isPlaying, airpods: airpods.showing,
                        lock: lock.showing, shelf: !model.shelf.isEmpty,
                        charging: power.showing, volume: volume.showing)
    }
    private var size: CGSize { IslandSize.size(for: mode) }
    /// Colores del brillo: los de la portada, o azul y violeta si no hay.
    private var glowColors: [Color] {
        let c = music.palette.map { Color(nsColor: $0) }
        return c.isEmpty ? [Color(red: 0.4, green: 0.78, blue: 1), Color(red: 0.7, green: 0.5, blue: 1)] : c
    }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: IslandSize.cornerRadius(for: mode), style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(.black)
                content
                IslandGlow(radius: IslandSize.cornerRadius(for: mode),
                           colors: glowColors, playing: music.isPlaying, flash: model.flashID)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .scaleEffect(model.launching ? 1.1 : (model.pop ? 1.05 : 1), anchor: .top)
            .opacity(model.launching ? 0.85 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: model.launching)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.pop)
            .modifier(ShakeEffect(animatableData: CGFloat(model.shakeCount)))
            .animation(.easeInOut(duration: 0.5), value: model.shakeCount)
            .onChange(of: music.title) { _, new in if !new.isEmpty && music.isPlaying { model.flash() } }
            .onChange(of: music.isPlaying) { _, playing in if playing { model.flash() } }
            .onChange(of: airpods.showing) { _, on in if on { model.flash() } }
            .onChange(of: power.showing) { _, on in if on { model.flash() } }
            .onChange(of: output.kind) { old, new in if old == .airpods && new != .airpods { model.shake() } }
            .animation(Self.bounce, value: mode)
            .contentShape(Rectangle())
            .onHover { inside in model.setHover(inside) }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
            .onChange(of: dropTargeted) { _, targeted in
                if targeted { model.openNow() }   // al arrastrar un archivo hacia la isla, se abre
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .idle:
            // Sin música: un clic abre la app de música.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { openSourceApp() }
        case .playing:
            compactContent.transition(.islandContent)
        case .peek:
            peekContent.transition(.islandContent)
        case .lock:
            lockContent.transition(.islandContent)
        case .airpods:
            airpodsContent.transition(.islandContent)
        case .charging:
            chargingContent.transition(.islandContent)
        case .volume:
            volumeContent.transition(.islandContent)
        case .expanded, .expandedShelf:
            expandedContent.transition(.islandContent)
        }
    }

    // MARK: - Píldora con música: carátula a la izquierda, barras a la derecha

    private var compactContent: some View {
        HStack {
            ArtworkView(image: music.artwork, size: pillH - 10)
                .matchedGeometryEffect(id: "art", in: ns)
                .padding(.leading, 6)
            Spacer()
            EqualizerBars(active: music.isPlaying)
                .padding(.trailing, 14)
        }
        .frame(height: pillH)
        .contentShape(Rectangle())
        .onTapGesture { openSourceApp() }
    }

    private func openSourceApp() {
        model.launchPulse()
        music.openSource()
    }

    // MARK: - Volumen (AirPods, bocinas...)

    /// Con AirPods se usa la imagen realista; con otras salidas, el icono del sistema.
    @ViewBuilder private var volumeIcon: some View {
        if output.kind == .airpods,
           let art = AirPodsArt.image(for: output.symbol) ?? AirPodsArt.image(for: "airpodspro") {
            Image(nsImage: art)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 30)
                .shadow(color: Color(red: 0.4, green: 0.78, blue: 1.0).opacity(0.35), radius: 6)
        } else {
            Image(systemName: output.symbol)
                .font(.system(size: 16))
                .foregroundStyle(output.kind == .airpods ? Color(red: 0.40, green: 0.78, blue: 1.0) : .white)
                .frame(width: 26)
        }
    }

    private var volumeContent: some View {
        HStack(spacing: 10) {
            volumeIcon
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(width: max(6, geo.size.width * (volume.muted ? 0 : volume.level)))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: volume.level)
                }
            }
            .frame(height: 6)
            Image(systemName: volume.muted || volume.level < 0.01 ? "speaker.slash.fill"
                  : volume.level < 0.34 ? "speaker.wave.1.fill"
                  : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    // MARK: - Cargador conectado

    private var chargingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.40))
                .symbolEffect(.pulse)
            Spacer()
            ChargingBattery(percent: power.percent)
            Text("\(power.percent)%")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
    }

    // MARK: - Candado al bloquear / desbloquear

    private var lockContent: some View {
        Image(systemName: lock.locked ? "lock.fill" : "lock.open.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: lock.locked)
            .frame(height: pillH)
    }

    // MARK: - Asomo al cambiar de canción

    private var peekContent: some View {
        HStack(spacing: 10) {
            ArtworkView(image: music.artwork, size: 44)
                .matchedGeometryEffect(id: "art", in: ns)
            VStack(alignment: .leading, spacing: 2) {
                Text(music.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(music.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            EqualizerBars(active: music.isPlaying)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .contentShape(Rectangle())
        .onTapGesture { openSourceApp() }
    }

    // MARK: - AirPods conectados

    private var airpodsContent: some View {
        HStack(spacing: 12) {
            AirPodsIcon(symbol: airpods.symbolName)
            Text(airpods.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            batteryIndicator
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(height: 58)
    }

    /// Dos audífonos (AirPods, AirPods Pro): un anillo con la batería más baja.
    /// Un solo dispositivo (AirPods Max, Beats): barra con el número.
    @ViewBuilder
    private var batteryIndicator: some View {
        if let m = airpods.mainLevel {
            BatteryBar(level: m)
        } else if let l = airpods.left, let r = airpods.right {
            BatteryRing(level: min(l, r))
        } else if let one = airpods.left ?? airpods.right {
            BatteryRing(level: one)
        }
    }

    // MARK: - Expandida: música + bandeja de archivos

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if music.hasTrack {
                HStack(spacing: 12) {
                    ArtworkView(image: music.artwork, size: 56)
                        .matchedGeometryEffect(id: "art", in: ns)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(music.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer()
                    EqualizerBars(active: music.isPlaying)
                    openAppButton
                }
                .contentShape(Rectangle())
                .onTapGesture { openSourceApp() }   // clic en portada / título: abre la app donde suena
                HStack(spacing: 8) {
                    Text(Self.clock(music.position))
                    islandProgress
                    Text("-" + Self.clock(max(0, music.duration - music.position)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 0) {
                    favoriteButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 30) {
                        controlButton("backward.fill") { music.previous() }
                        controlButton(music.isPlaying ? "pause.fill" : "play.fill", size: 22) { music.playPause() }
                        controlButton("forward.fill") { music.next() }
                    }
                    outputChip
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Nada sonando")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                    Button { openSourceApp() } label: {
                        Label("Abrir Música", systemImage: "music.note")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }

            // La bandeja solo aparece cuando hay archivos (se sigue pudiendo
            // arrastrar archivos a la isla en cualquier momento).
            if !model.shelf.isEmpty {
                shelfView
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .onAppear { music.startProgressUpdates(source: "island") }
        .onDisappear { music.stopProgressUpdates(source: "island") }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Barra de progreso de la isla (toca para saltar a ese punto).
    private var islandProgress: some View {
        GeometryReader { geo in
            let fraction = music.duration > 0 ? min(1, max(0, Double(music.position) / Double(music.duration))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 1.0), value: music.position)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                guard music.duration > 0 else { return }
                music.seek(to: Int(Double(music.duration) * min(1, max(0, g.location.x / geo.size.width))))
            })
        }
        .frame(height: 4)
    }

    /// Botón con el icono real de la app donde suena (Música, Chrome, Safari…): la abre.
    @ViewBuilder private var openAppButton: some View {
        if let icon = music.sourceAppIcon {
            Button { openSourceApp() } label: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            .buttonStyle(PressableStyle())
            .help("Abrir \(music.sourceAppName)")
        }
    }

    /// La estrella de favoritos de Apple Music.
    private var favoriteButton: some View {
        Button { music.toggleFavorite() } label: {
            Image(systemName: music.isFavorite ? "star.fill" : "star")
                .font(.system(size: 15))
                .foregroundStyle(music.isFavorite
                                 ? Color(red: 1.0, green: 0.27, blue: 0.40)
                                 : Color.white.opacity(0.8))
                .symbolEffect(.bounce, value: music.isFavorite)
                .frame(width: 34, height: 28, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Agregar a favoritos")
    }

    /// Por dónde sale el sonido: Mac Speakers, AirPods, etc.
    private var outputChip: some View {
        Image(systemName: output.symbol)
            .font(.system(size: output.kind == .airpods ? 19 : 16, weight: output.kind == .airpods ? .semibold : .regular))
            .frame(width: 34, height: 28, alignment: .trailing)
            .foregroundStyle(output.kind == .airpods ? Color.white : Color.white.opacity(0.65))
            .help(output.deviceName)
    }

    private func controlButton(_ symbol: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Bandeja de archivos

    private var shelfView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.shelf, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: 90)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                    .onDrag { NSItemProvider(object: url as NSURL) }   // se puede arrastrar de vuelta
                    .contextMenu {
                        Button("Quitar") { model.shelf.removeAll { $0 == url } }
                    }
                }
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let model = self.model
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url {
                    DispatchQueue.main.async {
                        if !model.shelf.contains(url) { model.shelf.append(url) }
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - Transición del contenido (difuminado + escala, como Apple)

struct BlurScale: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// Entra con un pequeño retraso (deja que la forma crezca primero),
    /// sale rápido. Ambos con difuminado.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: AnyTransition
                .modifier(active: BlurScale(blur: 14, scale: 0.6),
                          identity: BlurScale(blur: 0, scale: 1))
                .combined(with: .opacity)
                .animation(.spring(response: 0.4, dampingFraction: 0.78).delay(0.06)),
            removal: AnyTransition
                .modifier(active: BlurScale(blur: 14, scale: 0.8),
                          identity: BlurScale(blur: 0, scale: 1))
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.15))
        )
    }
}

/// Los botones se encogen un poco al presionarlos.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Piezas pequeñas

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .flipOnNewArtwork(image)
    }
}

/// Da una vuelta 3D con rebote cada vez que llega la portada de una canción nueva.
struct FlipOnNewArtwork: ViewModifier {
    let image: NSImage?
    @State private var angle = 0.0

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .onChange(of: image.map { ObjectIdentifier($0) }) { _, new in
                guard new != nil else { return }
                withAnimation(.spring(response: 0.9, dampingFraction: 0.68)) { angle += 360 }
            }
    }
}

extension View {
    func flipOnNewArtwork(_ image: NSImage?) -> some View { modifier(FlipOnNewArtwork(image: image)) }
}

/// Icono de los AirPods que gira en 3D al aparecer, como en el iPhone.
///
/// Usa tu propia imagen si existe en
/// `~/Library/Application Support/MiIsla/` con el nombre `airpodspro.png`,
/// `airpods.png` o `airpodsmax.png` (PNG con fondo transparente).
/// Si no, usa el icono del sistema (SF Symbols).
struct AirPodsIcon: View {
    let symbol: String
    private let custom: NSImage?
    @State private var start = Date()

    init(symbol: String) {
        self.symbol = symbol
        self.custom = AirPodsArt.image(for: symbol)
    }

    /// Curva con rebote al final (se pasa un poco y regresa).
    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    var body: some View {
        // 3D continuo: entra girando una vuelta completa con rebote y luego se queda
        // flotando, meciéndose en 3D (giro suave, inclinación y subida/bajada).
        TimelineView(.animation) { context in
            let t = max(0, context.date.timeIntervalSince(start) - 0.12)
            let spinDur = 1.25
            let p = min(1, t / spinDur)
            let spin = 360 * Self.easeOutBack(p)
            let settle = min(1, max(0, (t - spinDur * 0.8) / 0.7))
            let sway = 16 * sin((t - spinDur * 0.8) * 2.0) * settle
            let tilt = 7 * sin(t * 1.6) * settle
            let bob = 1.6 * sin(t * 2.4) * settle
            let pop = 0.55 + 0.45 * min(1, Self.easeOutBack(min(1, t / 0.5)))

            icon
                .frame(width: 52, height: 44)
                .scaleEffect(pop)
                .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(spin + sway), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .offset(y: bob)
                .shadow(color: Color(red: 0.4, green: 0.78, blue: 1.0).opacity(0.35 * settle), radius: 8)
        }
        .frame(width: 52, height: 44)
        .onAppear { start = Date() }
    }

    @ViewBuilder private var icon: some View {
        if let custom {
            Image(nsImage: custom).resizable().scaledToFit()
        } else {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(white: 0.62)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
    }
}

/// Imágenes opcionales de los AirPods. Si pones un PNG con fondo transparente en
/// ~/Library/Application Support/MiIsla/ con alguno de estos nombres, se usa en
/// lugar del icono del sistema:  airpods.png · airpodspro.png · airpodsmax.png
enum AirPodsArt {
    static var folder: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiIsla", isDirectory: true)
    }

    static func image(for name: String) -> NSImage? {
        // Tu propia imagen en la carpeta de Application Support. Si no hay, se usa el
        // icono del sistema (SF Symbols). El proyecto NO incluye imágenes de productos de Apple.
        NSImage(contentsOf: folder.appendingPathComponent("\(name).png"))
    }
}

/// Batería que se llena al aparecer (verde; roja si queda poca).
struct ChargingBattery: View {
    let percent: Int
    @State private var shown = false

    private let width: CGFloat = 32
    private var color: Color {
        percent <= 20 ? Color(red: 0.88, green: 0.30, blue: 0.27) : Color(red: 0.35, green: 0.85, blue: 0.40)
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(color)
                    .frame(width: max(6, (shown ? CGFloat(percent) / 100 : 0) * (width - 4)), height: 11)
                    .padding(.leading, 2)
            }
            .frame(width: width, height: 15)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(.white.opacity(0.45))
                .frame(width: 2, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { shown = true }
        }
    }
}

/// Anillo de batería que se llena al aparecer (verde; rojo si queda poca).
struct BatteryRing: View {
    let level: Int
    @State private var shown = false

    private var color: Color { level <= 20 ? Color(red: 0.88, green: 0.30, blue: 0.27) : Color(red: 0.35, green: 0.80, blue: 0.40) }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 26, height: 26)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { shown = true }
        }
    }
}

/// Barra de batería con número (para dispositivos de una sola batería).
struct BatteryBar: View {
    let level: Int
    @State private var shown = false

    private let barWidth: CGFloat = 56
    private var color: Color { level <= 20 ? Color(red: 0.88, green: 0.30, blue: 0.27) : Color(red: 0.35, green: 0.80, blue: 0.40) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: max(7, shown ? barWidth * CGFloat(level) / 100 : 7))
            }
            .frame(width: barWidth, height: 7)
            Text("\(level)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { shown = true }
        }
    }
}

/// Barras de ecualizador que se mueven continuamente mientras suena la música.
struct EqualizerBars: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (3.0 + Double(i) * 0.9) + Double(i) * 1.7
                    let h: CGFloat = active ? 5 + 9 * CGFloat(abs(sin(phase))) : 4
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(width: 18, height: 16)
        }
    }
}


// MARK: - Brillo y sacudida

/// Brillo de la isla: un destello de luz que cruza la isla (al cambiar de canción,
/// conectar AirPods, cargar…). Ya no hay borde de color.
struct IslandGlow: View {
    let radius: CGFloat
    let colors: [Color]
    let playing: Bool
    let flash: Int

    @State private var flashAmount = 0.0
    @State private var sweep: CGFloat = -0.6

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.4)
                .offset(x: geo.size.width * sweep)
                .blendMode(.plusLighter)
                .opacity(flashAmount)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onChange(of: flash) { _, _ in runFlash() }
    }

    private func runFlash() {
        sweep = -0.6
        flashAmount = 1
        withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.2 }
        withAnimation(.easeOut(duration: 1.1).delay(0.2)) { flashAmount = 0 }
    }
}

/// Sacudida horizontal (se anima subiendo `animatableData` de n a n+1).
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}
