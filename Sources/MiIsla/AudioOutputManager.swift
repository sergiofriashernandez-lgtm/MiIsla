import AppKit
import CoreAudio
import Combine

/// Sabe por dónde está saliendo el sonido: bocinas de la Mac, AirPods, otros
/// audífonos Bluetooth, una pantalla, etc. Usa CoreAudio (sin permisos) y se
/// actualiza solo cuando cambia el dispositivo de salida.
final class AudioOutputManager: ObservableObject {
    enum Kind { case speakers, airpods, headphones, bluetooth, display, other }

    @Published var kind: Kind = .speakers
    @Published var deviceName = ""

    init() {
        refresh()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refresh()
        }
    }

    /// Icono (SF Symbols) para mostrar en la isla.
    var symbol: String {
        switch kind {
        case .speakers:   return "laptopcomputer"
        case .airpods:
            let n = deviceName.lowercased()
            if n.contains("max") { return "airpodsmax" }
            if n.contains("pro") { return "airpodspro" }
            return "airpods"
        case .headphones: return "headphones"
        case .display:    return "display"
        case .bluetooth, .other: return "speaker.wave.2.fill"
        }
    }

    /// Texto corto para mostrar.
    var label: String {
        switch kind {
        case .speakers:   return "Mac Speakers"
        case .headphones: return "Headphones"
        case .airpods:
            let n = deviceName.lowercased()
            if n.contains("max") { return "AirPods Max" }
            if n.contains("pro") { return "AirPods Pro" }
            return "AirPods"
        case .bluetooth, .display, .other:
            return deviceName
        }
    }

    // MARK: - CoreAudio

    private func refresh() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return }

        let name = Self.name(of: deviceID)
        deviceName = name
        kind = Self.kind(name: name, transport: Self.transport(of: deviceID))
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let cfName else { return "" }
        return cfName.takeRetainedValue() as String
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func kind(name: String, transport: UInt32) -> Kind {
        if name.localizedCaseInsensitiveContains("AirPods") { return .airpods }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return name.localizedCaseInsensitiveContains("head") ? .headphones : .speakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        default:
            return .other
        }
    }
}
