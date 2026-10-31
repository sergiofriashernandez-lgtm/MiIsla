import AppKit
import Combine

/// Detecta cuando la Mac se bloquea o se desbloquea: muestra un candado en la
/// isla un par de segundos y reproduce un sonido.
final class LockManager: ObservableObject {
    @Published var showing = false
    @Published var locked = false

    private var hideWork: DispatchWorkItem?

    /// Sonidos del sistema (de /System/Library/Sounds). Cámbialos por otros:
    /// Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr,
    /// Sosumi, Submarine, Tink. Pon "" para silenciar uno.
    static let lockSound = "Pop"
    static let unlockSound = "Tink"

    init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.change(locked: true)
        }
        center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.change(locked: false)
        }
    }

    private func change(locked: Bool) {
        print("[MiIsla] macOS avisó: pantalla \(locked ? "BLOQUEADA" : "desbloqueada")")
        self.locked = locked
        showing = true

        let soundName = locked ? Self.lockSound : Self.unlockSound
        if !soundName.isEmpty {
            NSSound(named: NSSound.Name(soundName))?.play()
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showing = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
