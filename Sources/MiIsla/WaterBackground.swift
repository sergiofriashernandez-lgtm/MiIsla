import SwiftUI
import AppKit

/// Fondo "de agua" para la pantalla completa del widget de bloqueo.
/// La portada desenfocada se mueve un poco con el cursor, unas manchas de luz de los colores
/// de la canción lo siguen con retraso (como líquido) como en el agua.
final class WaterSim {
    var blobs: [CGPoint] = []
    var cursor = CGPoint.zero
    var parallax = CGPoint.zero
    private var last: TimeInterval = 0

    func step(now: TimeInterval, size: CGSize) {
        let dt = last == 0 ? 1.0 / 60 : min(0.05, now - last)
        last = now

        // Cursor en coordenadas de la vista (origen arriba a la izquierda).
        let screen = IslandScreen.screen.frame
        let m = NSEvent.mouseLocation
        cursor = CGPoint(x: m.x - screen.minX, y: screen.maxY - m.y)

        if blobs.isEmpty { blobs = Array(repeating: CGPoint(x: size.width / 2, y: size.height / 2), count: 3) }

        // Cada mancha persigue al cursor con distinta suavidad: sensación de líquido.
        let rates: [Double] = [5.5, 2.8, 1.5]
        for i in 0..<blobs.count {
            let k = CGFloat(1 - exp(-rates[i] * dt))
            // Un vaivén lento para que nunca esté del todo quieto.
            let wobble = CGPoint(x: CGFloat(sin(now * (0.7 + Double(i) * 0.3)) * 26),
                                 y: CGFloat(cos(now * (0.5 + Double(i) * 0.4)) * 26))
            let target = CGPoint(x: cursor.x + wobble.x, y: cursor.y + wobble.y)
            blobs[i].x += (target.x - blobs[i].x) * k
            blobs[i].y += (target.y - blobs[i].y) * k
        }

        // La imagen de fondo se desplaza apenas, contraria al cursor (paralaje).
        let targetP = CGPoint(x: (size.width / 2 - cursor.x) * 0.05, y: (size.height / 2 - cursor.y) * 0.05)
        let kp = CGFloat(1 - exp(-3 * dt))
        parallax.x += (targetP.x - parallax.x) * kp
        parallax.y += (targetP.y - parallax.y) * kp
    }
}

struct WaterBackground: View {
    let tiny: NSImage?
    let palette: [NSColor]
    @State private var sim = WaterSim()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let _ = sim.step(now: now, size: geo.size)
                Canvas { gc, size in
                    gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                    if let tiny {
                        let w = size.width * 1.25, h = size.height * 1.25
                        let rect = CGRect(x: (size.width - w) / 2 + sim.parallax.x,
                                          y: (size.height - h) / 2 + sim.parallax.y,
                                          width: w, height: h)
                        var img = gc
                        img.addFilter(.saturation(1.1))
                        img.draw(img.resolve(Image(nsImage: tiny)), in: rect)
                    }

                    // Manchas de luz que siguen al cursor.
                    var light = gc
                    light.blendMode = .screen
                    let radii: [CGFloat] = [360, 280, 220]
                    for (i, p) in sim.blobs.enumerated() {
                        let ns = palette.isEmpty ? NSColor.white : palette[i % palette.count]
                        let c = Color(nsColor: ns)
                        let r = radii[i % radii.count]
                        light.fill(
                            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                            with: .radialGradient(Gradient(colors: [c.opacity(0.42), c.opacity(0)]),
                                                  center: p, startRadius: 0, endRadius: r))
                    }
                }
            }
        }
    }
}
