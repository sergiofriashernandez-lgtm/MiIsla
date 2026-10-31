import SwiftUI
import AppKit
import IOKit.pwr_mgt

/// Ajustes de la pantalla de bloqueo (se abren desde el menú de la cápsula).
/// Se guardan en UserDefaults; el widget los lee en vivo con @AppStorage.
enum LockPrefs {
    static let glassStyle = "lockGlassStyle"     // "clear" | "frosted"
    static let fullArt = "lockFullArt"
    static let lyrics = "lockLyrics"
    static let syncMs = "lockSyncMs"             // -1000...1000 (negativo = letra más tarde)
    static let glassArt = "lockGlassArt"
    static let glassCard = "lockGlassCard"
    static let keepAwake = "lockKeepAwake"
    static let awakeMinutes = "lockAwakeMinutes"
}

struct LockSettingsView: View {
    @AppStorage(LockPrefs.glassStyle) private var glassStyle = "clear"
    @AppStorage(LockPrefs.fullArt) private var fullArt = true
    @AppStorage(LockPrefs.lyrics) private var lyrics = true
    @AppStorage(LockPrefs.syncMs) private var syncMs = 0.0
    @AppStorage(LockPrefs.glassArt) private var glassArt = false
    @AppStorage(LockPrefs.glassCard) private var glassCard = true
    @AppStorage(LockPrefs.keepAwake) private var keepAwake = false
    @AppStorage(LockPrefs.awakeMinutes) private var awakeMinutes = 10.0

    var body: some View {
        Form {
            Section("Estilo de cristal") {
                Picker("", selection: $glassStyle) {
                    Text("Transparente").tag("clear")
                    Text("Esmerilado").tag("frosted")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Comportamiento") {
                Toggle("Portada completa (al tocar la portada)", isOn: $fullArt)
                Toggle("Letras sincronizadas", isOn: $lyrics)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sincronía de la letra")
                        Spacer()
                        Text("\(Int(syncMs)) ms").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $syncMs, in: -1000...1000, step: 50)
                    HStack {
                        Text("Más tarde").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Más pronto").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!lyrics)
                Toggle("Portada de cristal", isOn: $glassArt)
                Toggle("Tarjeta de cristal", isOn: $glassCard)
            }

            Section("Pantalla") {
                Text("El widget de música se apaga solo tras esta duración (10 min por defecto).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mantener la pantalla encendida", isOn: $keepAwake)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Apagar tras")
                        Spacer()
                        Text("\(Int(awakeMinutes)) min").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $awakeMinutes, in: 5...60, step: 5)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 520)
    }
}

final class LockSettingsWindow {
    static let shared = LockSettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LockSettingsView()))
            w.title = "Pantalla de bloqueo"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Mantiene la pantalla encendida un rato (mientras está bloqueada y suena música).
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var active = false
    private var stopWork: DispatchWorkItem?

    func start() {
        guard UserDefaults.standard.bool(forKey: LockPrefs.keepAwake) else { return }
        stop()
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MiIsla: música en la pantalla de bloqueo" as CFString,
            &assertion)
        active = (result == kIOReturnSuccess)
        let minutes = UserDefaults.standard.object(forKey: LockPrefs.awakeMinutes) as? Double ?? 10
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60, execute: work)
        print("[MiIsla] pantalla encendida \(Int(minutes)) min: \(active ? "sí" : "no se pudo")")
    }

    func stop() {
        stopWork?.cancel()
        if active { IOPMAssertionRelease(assertion); active = false }
    }
}
