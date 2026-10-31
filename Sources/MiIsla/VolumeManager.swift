import AppKit
import CoreAudio
import Combine

/// Vigila el volumen de la salida de audio actual (AirPods, bocinas, etc.) y,
/// cuando cambia, pide a la isla que muestre una barra de volumen un momento.
final class VolumeManager: ObservableObject {
    @Published var showing = false
    @Published var level: Double = 0      // 0...1
    @Published var muted = false

    private var deviceID: AudioDeviceID = 0
    private var lastLevel: Double?
    private var hideWork: DispatchWorkItem?
    private var volumeBlock: AudioObjectPropertyListenerBlock?

    // 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume (volumen "real" del sistema)
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D7663)

    init() {
        attachToDefaultDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
    }

    /// Para probar desde el menú sin tocar el volumen.
    func preview() {
        level = Self.readVolume(deviceID) ?? level
        present()
    }

    // MARK: - CoreAudio

    private func attachToDefaultDevice() {
        // Quita el oyente del dispositivo anterior.
        if deviceID != 0, let block = volumeBlock {
            for address in Self.addresses {
                var a = address
                AudioObjectRemovePropertyListenerBlock(deviceID, &a, DispatchQueue.main, block)
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return }

        deviceID = id
        lastLevel = Self.readVolume(id)          // al cambiar de dispositivo no se muestra nada
        if let v = lastLevel { level = v }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        volumeBlock = block
        for address in Self.addresses {
            var a = address
            AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
    }

    private static var addresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(mSelector: virtualMainVolume,
                                       mScope: kAudioDevicePropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                       mScope: kAudioDevicePropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
        ]
    }

    private func volumeChanged() {
        let newMuted = Self.readMute(deviceID)
        guard let v = Self.readVolume(deviceID) else { return }
        let changed = abs(v - (lastLevel ?? -1)) > 0.001 || newMuted != muted
        lastLevel = v
        level = v
        muted = newMuted
        if changed { present() }
    }

    private func present() {
        showing = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showing = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private static func readVolume(_ id: AudioDeviceID) -> Double? {
        guard id != 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: virtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    private static func readMute(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}


/// Lectura y ajuste directo del volumen del sistema (para el deslizador del widget de bloqueo).
enum SystemVolume {
    private static let selector = AudioObjectPropertySelector(0x766D7663)   // 'vmvc'

    private static var device: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get() -> Double? {
        guard let id = device else { return nil }
        var a = address
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    static func set(_ level: Double) {
        guard let id = device else { return }
        var a = address
        var v = Float32(min(1, max(0, level)))
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
