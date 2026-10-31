import AppKit
import IOKit.ps
import Combine

/// Datos de la fila que va debajo del reloj en la pantalla completa:
/// No molestar, clima, batería de la Mac y batería de los AirPods.
final class LockStatus: ObservableObject {
    @Published var battery = 0
    @Published var charging = false
    @Published var temp: Int?
    @Published var weatherSymbol = "cloud.fill"
    @Published var dnd = false
    @Published var airpods: Int?

    private var lastWeather: Date?
    private var poll: Timer?
    private var pollCount = 0

    /// Mientras el widget está visible, la batería se vuelve a leer cada 10 s
    /// (y la de los AirPods cada minuto), sin tener que desbloquear.
    func startPolling(output: AudioOutputManager) {
        stopPolling()
        pollCount = 0
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self, weak output] _ in
            guard let self, let output else { return }
            self.pollCount += 1
            self.readBattery()
            if self.pollCount % 6 == 0 { self.refresh(output: output) }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func stopPolling() { poll?.invalidate(); poll = nil }

    /// Icono de batería según el nivel.
    var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        switch battery {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    func refresh(output: AudioOutputManager) {
        readBattery()
        dnd = Self.readDND()

        // Batería de los AirPods (solo si son la salida actual). system_profiler tarda, va aparte.
        if output.kind == .airpods {
            let name = output.deviceName
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let r = AirPodsManager.readBattery(name: name)
                var level: Int?
                if let (l, rr, m, _) = r {
                    if let m { level = m }
                    else if let l, let rr { level = (l + rr) / 2 }
                    else { level = l ?? rr }
                }
                DispatchQueue.main.async { self?.airpods = level }
            }
        } else {
            airpods = nil
        }

        if lastWeather == nil || Date().timeIntervalSince(lastWeather!) > 15 * 60 { fetchWeather() }
    }

    func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        charging = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            battery = Int((Double(cur) / Double(max) * 100).rounded())
            return
        }
    }

    /// Mejor esfuerzo: macOS solo deja leer el estado de Enfoque con "Acceso total al disco".
    private static func readDND() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return false }
        return items.contains { !(($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty }
    }

    /// Clima actual: ubicación aproximada por IP (ipwho.is) + Open-Meteo. Sin llaves ni permisos.
    private func fetchWeather() {
        lastWeather = Date()
        guard let geoURL = URL(string: "https://ipwho.is/") else { return }
        URLSession.shared.dataTask(with: geoURL) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = json["latitude"] as? Double, let lon = json["longitude"] as? Double,
                  let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code")
            else { self?.lastWeather = nil; return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cur = json["current"] as? [String: Any],
                      let t = cur["temperature_2m"] as? Double,
                      let code = cur["weather_code"] as? Int else { self?.lastWeather = nil; return }
                DispatchQueue.main.async {
                    self.temp = Int(t.rounded())
                    self.weatherSymbol = Self.symbol(forCode: code)
                }
            }.resume()
        }.resume()
    }

    private static func symbol(forCode c: Int) -> String {
        switch c {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "snowflake"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
