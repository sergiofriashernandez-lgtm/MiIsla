import AppKit

/// Técnicas para mostrar una ventana por encima de la pantalla de bloqueo.
/// Se eligen desde el menú de la cápsula ("Técnica de pantalla de bloqueo")
/// para probar cuál funciona en tu versión de macOS.
enum LockTechnique: Int, CaseIterable {
    /// Espacio con nivel absoluto 400.
    case level400 = 0
    /// Espacio con nivel absoluto máximo (2147483647).
    case levelMax = 1
    /// Espacio con nivel 400 y, además, la ventana con nivel de "escudo" (muy alto).
    case level400HighWindow = 2

    private static let key = "lockTechnique"

    static var current: LockTechnique {
        get { LockTechnique(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .level400 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .level400:           return "B · espacio nivel 400 (recomendada)"
        case .levelMax:           return "A · espacio nivel máximo"
        case .level400HighWindow: return "C · nivel 400 + ventana muy alta"
        }
    }

    fileprivate var spaceLevel: Int32 {
        self == .levelMax ? 2147483647 : 400
    }
}

/// EXPERIMENTAL — muestra una ventana por encima de la pantalla de bloqueo.
///
/// Usa funciones privadas de macOS (framework SkyLight): crea un "espacio"
/// propio con un nivel más alto que el de la pantalla de bloqueo y mueve ahí
/// la ventana. Son APIs sin documentar: pueden cambiar o dejar de funcionar
/// con cualquier actualización de macOS, y por eso una app que las usa no
/// puede publicarse en la Mac App Store.
///
/// Las funciones se buscan en tiempo de ejecución (dlopen/dlsym). Si alguna no
/// existe, la app sigue funcionando normal, solo sin pantalla de bloqueo.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Void

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    )

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Un espacio por técnica (se crea una sola vez).
    private static var spaces: [LockTechnique: Int32] = [:]

    /// Mueve la ventana al espacio que está por encima de la pantalla de bloqueo.
    /// `quiet` evita imprimir mensajes cuando se repite varias veces seguidas.
    @discardableResult
    static func delegate(_ window: NSWindow,
                         technique: LockTechnique = .current,
                         quiet: Bool = false) -> Bool {
        guard let mainConnection: MainConnectionID = symbol("SLSMainConnectionID"),
              let createSpace: SpaceCreate = symbol("SLSSpaceCreate"),
              let setLevel: SpaceSetAbsoluteLevel = symbol("SLSSpaceSetAbsoluteLevel"),
              let showSpaces: ShowSpaces = symbol("SLSShowSpaces"),
              let addWindows: SpaceAddWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            if !quiet { print("[MiIsla] SkyLight no disponible: no se mostrará en la pantalla de bloqueo.") }
            return false
        }
        guard window.windowNumber > 0 else {
            if !quiet { print("[MiIsla] La ventana aún no tiene número; no se pudo mover a la pantalla de bloqueo.") }
            return false
        }

        let connection = mainConnection()
        if spaces[technique] == nil {
            let newSpace = createSpace(connection, 1, 0)
            setLevel(connection, newSpace, technique.spaceLevel)
            showSpaces(connection, [newSpace] as CFArray)
            spaces[technique] = newSpace
        }
        guard let space = spaces[technique] else { return false }

        if technique == .level400HighWindow {
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        }
        addWindows(connection, space, [window.windowNumber] as CFArray, 7)

        if !quiet {
            print("[MiIsla] Ventana movida al espacio de bloqueo. Técnica: \(technique.title)")
        }
        return true
    }
}
