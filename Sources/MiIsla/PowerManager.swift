import AppKit
import IOKit.ps
import Combine

/// Detecta cuando conectas el cargador y muestra una animación en la isla,
/// como en el iPhone. Usa IOKit (no necesita permisos).
final class PowerManager: ObservableObject {
    @Published var showing = false
    @Published var percent = 0

    private var wasOnAC: Bool?
    private var hideWork: DispatchWorkItem?
    private var source: CFRunLoopSource?

    init() {
        // macOS avisa cada vez que cambia la fuente de energía o el porcentaje.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.powerChanged() }
        }, context) {
            let runLoopSource = unmanaged.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            source = runLoopSource
        }
        // Estado inicial (sin mostrar nada si ya estaba conectado al abrir la app).
        if let state = readState() {
            wasOnAC = state.onAC
            percent = state.percent
        }
    }

    /// Muestra la animación sin conectar el cargador (opción de prueba del menú).
    func preview() {
        if let state = readState() { percent = state.percent }
        showing = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showing = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func powerChanged() {
        guard let state = readState() else { return }
        percent = state.percent

        if state.onAC, wasOnAC == false {
            print("[MiIsla] Cargador conectado (\(state.percent)%)")
            showing = true
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showing = false }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
        }
        wasOnAC = state.onAC
    }

    private func readState() -> (onAC: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = (providing == kIOPSACPowerValue)

        for ps in list {
            guard let description = IOPSGetPowerSourceDescription(info, ps)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            guard maximum > 0 else { continue }
            return (onAC, Int((Double(current) / Double(maximum) * 100).rounded()))
        }
        return nil
    }
}
