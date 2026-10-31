import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let model = IslandModel()
    private let music = MusicManager()
    private let airpods = AirPodsManager()
    private let lock = LockManager()
    private let output = AudioOutputManager()
    private let power = PowerManager()
    private let volume = VolumeManager()
    private lazy var lockWidget = LockWidgetController(music: music, output: output)
    private var cancellables = Set<AnyCancellable>()
    private var resizeWork: DispatchWorkItem?
    private var currentMode: IslandMode = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Carpeta donde puedes poner tus imágenes de AirPods (opcional).
        try? FileManager.default.createDirectory(at: AirPodsArt.folder, withIntermediateDirectories: true)
        print("[MiIsla] imágenes opcionales en: \(AirPodsArt.folder.path)")

        setupPanel()
        setupStatusItem()
        startMissionControlWatcher()

        // Prepara el widget de bloqueo (y con él la búsqueda de letras) desde el inicio,
        // para que la letra ya esté lista cuando bloquees la Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in _ = self?.lockWidget }

        // Si cambias de Space o de monitor, la isla vuelve a su lugar.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.place(self.windowSize(for: self.currentMode))
        }

        // La ventana sigue el tamaño de la isla para no bloquear clics
        // en otras apps con zonas transparentes.
        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                Publishers.CombineLatest4(model.$expanded, model.$peeking, music.$isPlaying, airpods.$showing),
                lock.$showing,
                model.$shelf.map { !$0.isEmpty }.removeDuplicates()
            ),
            Publishers.CombineLatest(power.$showing, volume.$showing)
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inner, extra in
                let (chargingShowing, volumeShowing) = extra
                let (states, lockShowing, hasShelf) = inner
                let (expanded, peeking, playing, airpodsShowing) = states
                let mode = IslandSize.mode(expanded: expanded, peeking: peeking,
                                           playing: playing, airpods: airpodsShowing,
                                           lock: lockShowing, shelf: hasShelf,
                                           charging: chargingShowing, volume: volumeShowing)
                self?.syncPanel(to: mode)
            }
            .store(in: &cancellables)

        // Al bloquear la Mac aparece el widget de música; al desbloquear se oculta.
        lock.$locked
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                if locked {
                    self?.lockWidget.show()
                    self?.reassertIsland()
                } else {
                    self?.lockWidget.hide()
                }
            }
            .store(in: &cancellables)

        // Al cambiar de canción, la isla se asoma 3 segundos.
        music.$title
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self, !title.isEmpty, self.music.isPlaying else { return }
                self.model.peek()
            }
            .store(in: &cancellables)

        // Reposiciona si cambias de monitor o resolución.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.place(self.windowSize(for: self.currentMode))
        }
    }

    // MARK: - Ventana de la isla

    private func setupPanel() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar                       // por encima de casi todo
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: IslandView(model: model, music: music, airpods: airpods, lock: lock, output: output, power: power, volume: volume))

        place(windowSize(for: .idle))
        panel.orderFrontRegardless()

        // EXPERIMENTAL: mostrar la isla también sobre la pantalla de bloqueo.
        if lockScreenEnabled {
            SkyLight.delegate(panel)
        }
    }

    private var lockScreenEnabled: Bool {
        UserDefaults.standard.object(forKey: "lockScreenEnabled2") as? Bool ?? true
    }

    /// Al crecer, la ventana se agranda al instante (la animación de SwiftUI
    /// ocurre dentro). Al encogerse, espera a que termine la animación.
    private func syncPanel(to mode: IslandMode) {
        let target = windowSize(for: mode)
        let cur = panel.frame.size
        if mode == currentMode, cur == target { return }   // nada que hacer
        currentMode = mode
        place(CGSize(width: max(cur.width, target.width), height: max(cur.height, target.height)))

        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.place(target) }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func windowSize(for mode: IslandMode) -> CGSize {
        let s = IslandSize.size(for: mode)
        return CGSize(width: s.width + IslandSize.margin.width, height: s.height + IslandSize.margin.height)
    }

    /// Centra la ventana arriba de la pantalla, casi pegada al borde.
    private func place(_ size: CGSize) {
        let screen = IslandScreen.screen
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = (screen.frame.maxY - IslandSize.topGap - size.height).rounded()
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        guard panel.frame != frame else { return }   // no re-layout si no cambió nada
        panel.setFrame(frame, display: true)
    }

    // MARK: - Icono en la barra de menú (para poder cerrar la app)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "MiIsla")

        let menu = NSMenu()

        let lockItem = NSMenuItem(title: "Mostrar en pantalla de bloqueo (experimental)",
                                  action: #selector(toggleLockScreen(_:)), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = lockScreenEnabled ? .on : .off
        menu.addItem(lockItem)

        let loginItem = NSMenuItem(title: "Abrir al iniciar sesión (solo como app .app)",
                                   action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let ytItem = NSMenuItem(title: "Detectar YouTube Music (navegador)",
                                action: #selector(toggleYouTube(_:)), keyEquivalent: "")
        ytItem.target = self
        ytItem.state = MusicManager.youTubeEnabled ? .on : .off
        menu.addItem(ytItem)

        let neteaseItem = NSMenuItem(title: "Letras: usar también NetEase (no oficial)",
                                     action: #selector(toggleNetease(_:)), keyEquivalent: "")
        neteaseItem.target = self
        neteaseItem.state = LyricsPrefs.neteaseEnabled ? .on : .off
        menu.addItem(neteaseItem)

        let settingsItem = NSMenuItem(title: "Ajustes de pantalla de bloqueo…",
                                      action: #selector(openLockSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let glassItem = NSMenuItem(title: "Liquid Glass real en bloqueo (experimental)",
                                   action: #selector(toggleGlass(_:)), keyEquivalent: "")
        glassItem.target = self
        glassItem.state = LiquidGlass.enabled ? .on : .off
        menu.addItem(glassItem)

        let testItem = NSMenuItem(title: "Probar widget de bloqueo (8 s)",
                                  action: #selector(testLockWidget), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        let volumeTestItem = NSMenuItem(title: "Probar barra de volumen",
                                        action: #selector(testVolume), keyEquivalent: "")
        volumeTestItem.target = self
        menu.addItem(volumeTestItem)

        let chargingTestItem = NSMenuItem(title: "Probar animación de carga",
                                          action: #selector(testCharging), keyEquivalent: "")
        chargingTestItem.target = self
        menu.addItem(chargingTestItem)

        // Variantes de la técnica de pantalla de bloqueo, para probar cuál funciona.
        let techniqueMenu = NSMenu()
        for technique in LockTechnique.allCases {
            let item = NSMenuItem(title: technique.title,
                                  action: #selector(selectTechnique(_:)), keyEquivalent: "")
            item.target = self
            item.tag = technique.rawValue
            item.state = (technique == LockTechnique.current) ? .on : .off
            techniqueMenu.addItem(item)
        }
        let techniqueItem = NSMenuItem(title: "Técnica de pantalla de bloqueo", action: nil, keyEquivalent: "")
        techniqueItem.submenu = techniqueMenu
        menu.addItem(techniqueItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Salir de MiIsla", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Activa o desactiva la pantalla de bloqueo. Se aplica al volver a abrir la app.
    @objc private func toggleLockScreen(_ sender: NSMenuItem) {
        let newValue = !lockScreenEnabled
        UserDefaults.standard.set(newValue, forKey: "lockScreenEnabled2")
        sender.state = newValue ? .on : .off
        sender.title = "Mostrar en pantalla de bloqueo (experimental)" + (newValue ? "" : " — APAGADO")
        print("[MiIsla] pantalla de bloqueo: \(newValue ? "activada" : "desactivada")")
    }

    @objc private func selectTechnique(_ sender: NSMenuItem) {
        guard let technique = LockTechnique(rawValue: sender.tag) else { return }
        LockTechnique.current = technique
        sender.menu?.items.forEach { $0.state = ($0.tag == technique.rawValue) ? .on : .off }
        lockWidget.resetDelegation()
        if lockScreenEnabled { SkyLight.delegate(panel, technique: technique) }
        print("[MiIsla] Técnica de bloqueo elegida: \(technique.title)")
    }

    /// Vuelve a poner la isla al frente varias veces tras el bloqueo.
    private func reassertIsland() {
        guard lockScreenEnabled else { return }
        for delay in [0.0, 0.3, 0.8, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.panel.orderFrontRegardless()
                SkyLight.delegate(self.panel, quiet: true)
            }
        }
    }

    /// Muestra el widget 8 segundos sin bloquear la Mac, para comprobar que se dibuja.
    @objc private func testLockWidget() {
        lockWidget.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.lockWidget.hide()
        }
    }

    @objc private func testVolume() { volume.preview() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            print("[MiIsla] no se pudo cambiar 'abrir al iniciar sesión': \(error.localizedDescription)")
        }
        sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func toggleYouTube(_ sender: NSMenuItem) {
        MusicManager.youTubeEnabled.toggle()
        sender.state = MusicManager.youTubeEnabled ? .on : .off
    }

    @objc private func toggleNetease(_ sender: NSMenuItem) {
        LyricsPrefs.neteaseEnabled.toggle()
        sender.state = LyricsPrefs.neteaseEnabled ? .on : .off
    }

    @objc private func openLockSettings() { LockSettingsWindow.shared.show() }

    @objc private func toggleGlass(_ sender: NSMenuItem) {
        LiquidGlass.enabled.toggle()
        sender.state = LiquidGlass.enabled ? .on : .off
    }

    @objc private func testCharging() { power.preview() }

    // MARK: - Mission Control (tres dedos hacia arriba)

    private var missionControlTimer: Timer?
    private var inMissionControl = false
    private let windowScanQueue = DispatchQueue(label: "miisla.windowscan", qos: .utility)
    private var scanning = false

    /// Revisa dos veces por segundo si el Dock puso ventanas a pantalla completa
    /// (Mission Control, Exposé) o si una app está en pantalla completa. Mientras sea así,
    /// la isla se desvanece. La consulta de ventanas va en un hilo de fondo para no
    /// trabar la interfaz.
    private func startMissionControlWatcher() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkMissionControl()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        missionControlTimer = timer
    }

    private var inFullScreenApp = false

    /// Oculta la isla mientras Mission Control está abierto o hay una app en pantalla completa
    /// (Safari, un video, un juego...), y la regresa al salir.
    private func checkMissionControl() {
        if lock.locked || scanning { return }   // con la Mac bloqueada el Dock también pone ventanas grandes
        scanning = true
        let screen = IslandScreen.screen.frame
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        windowScanQueue.async { [weak self] in
            var mission = false
            var fullScreen = false
            if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                for w in list {
                    guard let layer = w[kCGWindowLayer as String] as? Int,
                          let owner = w[kCGWindowOwnerName as String] as? String,
                          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                          let width = b["Width"], let height = b["Height"] else { continue }
                    guard width >= screen.width - 2 && height >= screen.height - 2 else { continue }
                    if owner == "Dock" {
                        if layer >= 0 { mission = true }
                    } else if layer == 0, owner != "Window Server",
                              (w[kCGWindowOwnerPID as String] as? Int) != myPID {
                        // Una ventana normal que ocupa TODA la pantalla (incluida la barra de menús)
                        // solo existe cuando la app está en pantalla completa.
                        fullScreen = true
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if mission != self.inMissionControl {
                    self.inMissionControl = mission
                    print("[MiIsla] Mission Control \(mission ? "abierto" : "cerrado")")
                }
                if fullScreen != self.inFullScreenApp {
                    self.inFullScreenApp = fullScreen
                    print("[MiIsla] app en pantalla completa: \(fullScreen ? "sí, isla oculta" : "no, isla de vuelta")")
                }
                self.applyHidden(mission || fullScreen)
            }
        }
    }

    private var islandHidden = false

    private func applyHidden(_ hidden: Bool) {
        guard hidden != islandHidden else { return }
        islandHidden = hidden
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = hidden ? 0.25 : 0.4
            panel.animator().alphaValue = hidden ? 0.0 : 1.0
        }
        panel.ignoresMouseEvents = hidden
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
