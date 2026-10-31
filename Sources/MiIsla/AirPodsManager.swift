import IOBluetooth
import CoreAudio
import Combine

/// Detecta cuando se conectan unos AirPods (o Beats) y obtiene su batería.
///
/// - Conexión: se detecta de dos formas a la vez (IOBluetooth y un nuevo
///   dispositivo de audio en el sistema). La segunda no necesita permisos.
/// - Batería: no hay API pública, así que se lee de `system_profiler`.
///   Con muchos dispositivos Bluetooth guardados tarda varios segundos,
///   por eso la isla espera y reintenta.
final class AirPodsManager: NSObject, ObservableObject {
    @Published var showing = false
    @Published var name = ""
    @Published var left: Int?
    @Published var right: Int?
    @Published var mainLevel: Int?     // AirPods Max y similares (una sola batería)
    @Published var caseLevel: Int?

    private var connectNote: IOBluetoothUserNotification?
    private var hideWork: DispatchWorkItem?
    private let startupDate = Date()
    private var fetching = false
    private var attempts = 0
    private var knownAudioDevices = Set<String>()

    override init() {
        super.init()
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:fromDevice:))
        )
        startAudioWatcher()
    }

    private static func isAirPodsName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("AirPods") || name.localizedCaseInsensitiveContains("Beats")
    }

    var symbolName: String {
        let n = name.lowercased()
        if n.contains("max") { return "airpodsmax" }
        if n.contains("pro") { return "airpodspro" }
        return "airpods"
    }

    // MARK: - Detección por Bluetooth

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification,
                                       fromDevice device: IOBluetoothDevice) {
        // Ignora los avisos de dispositivos que ya estaban conectados al abrir la app.
        guard Date().timeIntervalSince(startupDate) > 8 else { return }
        let deviceName = device.name ?? ""
        guard Self.isAirPodsName(deviceName) else { return }
        DispatchQueue.main.async { self.present(name: deviceName) }
    }

    // MARK: - Detección por dispositivos de audio (no necesita permisos)

    /// Cuando unos AirPods se conectan, aparecen como un nuevo dispositivo de audio.
    private func startAudioWatcher() {
        knownAudioDevices = Set(currentAudioDeviceNames())
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.audioDevicesChanged()
        }
    }

    private func audioDevicesChanged() {
        let names = Set(currentAudioDeviceNames())
        let added = names.subtracting(knownAudioDevices)
        knownAudioDevices = names
        for name in added where Self.isAirPodsName(name) {
            present(name: name)
        }
    }

    private func currentAudioDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName)
            guard status == noErr, let cfName else { return nil }
            return cfName.takeRetainedValue() as String
        }
    }

    // MARK: - Mostrar / ocultar

    /// ¿Están de verdad conectados? Evita la animación falsa al abrir la app: IOBluetooth y CoreAudio
    /// a veces avisan de dispositivos que están emparejados pero NO conectados.
    private func isReallyConnected(_ name: String) -> Bool {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return true }
        let matches = paired.filter { ($0.name ?? "").caseInsensitiveCompare(name) == .orderedSame }
        if matches.isEmpty { return true }          // no se puede comprobar: se confía en el aviso
        return matches.contains { $0.isConnected() }
    }

    private func present(name: String) {
        // Los primeros segundos tras abrir la app solo se reconoce lo que ya estaba conectado.
        guard Date().timeIntervalSince(startupDate) > 8 else { return }
        // Las dos formas de detección pueden avisar a la vez: se ignora el duplicado.
        if showing && self.name == name { return }
        // Se espera un instante a que el estado de conexión se actualice y se comprueba.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.isReallyConnected(name) else {
                print("[MiIsla] aviso de \(name) ignorado: no está conectado")
                return
            }
            self.reallyPresent(name: name)
        }
    }

    private func reallyPresent(name: String) {
        if showing && self.name == name { return }
        self.name = name
        left = nil; right = nil; mainLevel = nil; caseLevel = nil
        attempts = 0
        showing = true

        // Si la batería tarda, la isla espera hasta 8 s. En cuanto llega, se
        // queda 4 s más para que se vea.
        scheduleHide(after: 8.0)
        fetchBattery(name: name)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showing = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Batería

    private func fetchBattery(name: String) {
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AirPodsManager.readBattery(name: name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard self.showing, self.name == name else { return }

                if let (l, r, m, c) = result, (l ?? r ?? m ?? c) != nil {
                    self.left = l
                    self.right = r
                    self.mainLevel = m
                    self.caseLevel = c
                    self.scheduleHide(after: 4.0)
                } else {
                    self.attempts += 1
                    print("[MiIsla] batería de \(name) aún no disponible (intento \(self.attempts))")
                    if self.attempts < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.fetchBattery(name: name)
                        }
                    }
                }
            }
        }
    }

    /// Lee la batería con system_profiler (puede tardar varios segundos).
    static func readBattery(name: String) -> (Int?, Int?, Int?, Int?)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        var props: [String: Any]?
        for entry in list {
            guard let connected = entry["device_connected"] as? [[String: Any]] else { continue }
            for dict in connected {
                for (key, value) in dict where key.caseInsensitiveCompare(name) == .orderedSame {
                    props = value as? [String: Any]
                }
            }
        }
        guard let p = props else { return nil }

        func percent(_ key: String) -> Int? {
            guard let s = p[key] as? String else { return nil }
            return Int(s.filter(\.isNumber))
        }
        return (percent("device_batteryLevelLeft"),
                percent("device_batteryLevelRight"),
                percent("device_batteryLevelMain"),
                percent("device_batteryLevelCase"))
    }
}
