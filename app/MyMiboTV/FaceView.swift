import SwiftUI

/// Mibo's face, drawn the same way as on the iPad: big eyes set wide with the
/// smile between them, on the full orange glow.
struct FaceView: View {
    @ObservedObject var convo: Conversation
    @ObservedObject var speaker: Speaker
    @State private var face = FaceMotion()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let state = convo.state, level = speaker.level, speaking = speaker.isSpeaking, acc = convo.accessory
            let face = self.face
            Canvas { ctx, size in
                face.step(t: t, state: state, level: level, speaking: speaking)
                face.draw(&ctx, size: size, t: t, accessory: acc)
            }
        }
        .background(
            RadialGradient(colors: [Mibo.pale, Mibo.glow, Mibo.deep], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 1300)
        )
        .ignoresSafeArea()
    }
}

enum Mibo {
    static let glow = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x15 / 255)
    static let deep = Color(red: 0xA9 / 255, green: 0x5D / 255, blue: 0x10 / 255)
    static let pale = Color(red: 0xEA / 255, green: 0xA7 / 255, blue: 0x66 / 255)
    static let eye = Color(red: 0x2B / 255, green: 0x1F / 255, blue: 0x27 / 255)
    static let listen = Color(red: 0x8F / 255, green: 0xD3 / 255, blue: 0xC8 / 255)
}

/// The face's movement: where it looks, blinking, the mouth, and the listening/thinking signs.
final class FaceMotion {
    private var last = 0.0
    private var gaze = CGPoint.zero, gazeT = CGPoint.zero
    private var nextWander = 0.0, blinkAt = -1.0, nextBlink = 2.0
    private var mouth = 0.0, listenAmt = 0.0, thinkAmt = 0.0
    private var accAmt = 0.0, acc: String?
    private var lid = 1.0
    // The TV plays sound a little after the Apple TV sends it, so the mouth follows the
    // loudness from a moment ago to line up with what you hear.
    private var levels: [(t: Double, level: Double)] = []
    private let mouthDelay = 0.15

    private func ease(_ cur: Double, _ target: Double, _ rate: Double, _ dt: Double) -> Double {
        cur + (target - cur) * (1 - exp(-rate * dt))
    }

    func step(t: Double, state: Conversation.State, level: Double, speaking: Bool) {
        let dt = last == 0 ? 0.016 : min(0.05, t - last)
        last = t
        switch state {
        case .listening: gazeT = CGPoint(x: 0, y: 0.08)
        case .thinking: gazeT = CGPoint(x: 0.4, y: -0.45)
        case .speaking: gazeT = CGPoint(x: sin(t * 0.6) * 0.12, y: 0.02)
        case .idle:
            if t > nextWander {
                gazeT = CGPoint(x: Double.random(in: -0.35...0.35), y: Double.random(in: -0.2...0.2))
                nextWander = t + 2.2 + Double.random(in: 0...3.5)
            }
        }
        gaze.x = ease(gaze.x, gazeT.x, 4, dt)
        gaze.y = ease(gaze.y, gazeT.y, 4, dt)

        if t > nextBlink { blinkAt = t; nextBlink = t + (Double.random(in: 0...1) < 0.18 ? 0.35 : 2.4 + Double.random(in: 0...4)) }
        let bp = t - blinkAt
        lid = bp >= 0 && bp < 0.16 ? max(0.06, 1 - sin(.pi * bp / 0.16)) : 1

        levels.append((t, level))
        while levels.count > 1 && levels[1].t <= t - mouthDelay { levels.removeFirst() }
        let level = levels.first?.level ?? level

        let target: Double
        if level >= 0 && speaking { target = level }
        else if speaking { target = min(1, 0.22 + 0.42 * (0.5 + 0.5 * sin(t * 11.7)) * (0.55 + 0.45 * sin(t * 3.9 + 1.3))) }
        else { target = 0 }
        mouth = ease(mouth, target, level >= 0 ? 28 : 18, dt)
        listenAmt = ease(listenAmt, state == .listening ? 1 : 0, 6, dt)
        thinkAmt = ease(thinkAmt, state == .thinking ? 1 : 0, 6, dt)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, accessory: String?) {
        let W = size.width, H = size.height
        let cx = W / 2, cy = H * 0.45, R = max(40, min(W, H) * 0.28)

        // A personality's accessory fades out before the next one fades in.
        if acc != accessory { accAmt = ease(accAmt, 0, 7, 0.016); if accAmt < 0.03 { acc = accessory } }
        else { accAmt = ease(accAmt, accessory == nil ? 0 : 1, 3, 0.016) }

        // A soft brightening while listening or talking.
        let pulse = 0.06 * listenAmt + 0.1 * mouth
        if pulse > 0.005 {
            let g = Gradient(colors: [Color.white.opacity(pulse * 0.6), Color.white.opacity(0)])
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(g, center: CGPoint(x: cx, y: cy), startRadius: R * 0.3, endRadius: R * 2.6))
        }

        // Listening: two soft teal rings drifting outward.
        if listenAmt > 0.01 {
            for i in 0..<2 {
                let p = (t * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let r = R * (1.12 + 0.35 * p)
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                           with: .color(Mibo.listen.opacity(listenAmt * 0.55 * (1 - p))), lineWidth: 4)
            }
        }

        // Big eyes set wide, with the smile tucked between them.
        let ew = R * 0.21, eh = R * 0.4 * lid * (1 + 0.1 * listenAmt)
        let eyeY = cy - R * 0.12
        for side in [-1.0, 1.0] {
            let x = cx + side * R * 0.37 + gaze.x * R * 0.12
            let y = eyeY + gaze.y * R * 0.1
            let h = max(1.5, eh)
            ctx.fill(Path(ellipseIn: CGRect(x: x - ew / 2, y: y - h / 2, width: ew, height: h)), with: .color(Mibo.eye))
            if lid > 0.4 {
                let r = ew * 0.17, hx = x - ew * 0.18, hy = y - eh * 0.2
                ctx.fill(Path(ellipseIn: CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 1, green: 0.957, blue: 0.925).opacity(0.85)))
            }
        }

        let mx = cx + gaze.x * R * 0.05, my = eyeY + R * 0.25 + gaze.y * R * 0.04
        let open = min(1, mouth * 1.6)
        if open < 0.98 {
            ctx.stroke(arc(CGPoint(x: mx, y: my - R * 0.13), R * 0.17, 0.22 * .pi, 0.78 * .pi),
                       with: .color(Mibo.eye.opacity(1 - open)),
                       style: StrokeStyle(lineWidth: R * 0.034, lineCap: .round))
        }
        if open > 0.02 {
            let w = R * (0.1 + 0.03 * mouth), h = R * (0.025 + 0.11 * mouth)
            ctx.fill(Path(ellipseIn: CGRect(x: mx - w, y: my - h, width: w * 2, height: h * 2)), with: .color(Mibo.eye.opacity(open)))
        }

        if let acc, accAmt > 0.01 { drawAccessory(&ctx, acc, cx, cy, R, accAmt) }

        // Thinking: three little dots circling above the head.
        if thinkAmt > 0.01 {
            for i in 0..<3 {
                let a = t * 2.2 + Double(i) * 2 * .pi / 3
                let x = cx + R * 0.72 + cos(a) * R * 0.13, y = cy - R * 1.05 + sin(a) * R * 0.06
                let r = R * 0.035
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(Mibo.pale.opacity(thinkAmt * (0.5 + 0.5 * sin(a)))))
            }
        }
    }

    /// An arc that goes from angle a0 to a1 through increasing angles (screen y points down).
    private func arc(_ c: CGPoint, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        for i in 0...24 {
            let a = a0 + (a1 - a0) * Double(i) / 24
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    }

    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    private func drawAccessory(_ base: inout GraphicsContext, _ acc: String, _ cx: Double, _ cy: Double, _ R: Double, _ a: Double) {
        var ctx = base
        ctx.opacity = a
        switch acc {
        case "bowtie":
            let by = cy + R * 1.16
            for s in [-1.0, 1.0] {
                var p = Path()
                p.move(to: CGPoint(x: cx, y: by))
                p.addLine(to: CGPoint(x: cx + s * R * 0.34, y: by - R * 0.14))
                p.addQuadCurve(to: CGPoint(x: cx + s * R * 0.34, y: by + R * 0.14), control: CGPoint(x: cx + s * R * 0.4, y: by))
                p.closeSubpath()
                ctx.fill(p, with: .color(hex(0x3a4d78)))
            }
            ctx.fill(ellipse(cx, by, R * 0.07, R * 0.08), with: .color(hex(0x5670a3)))
        case "beret":
            var c = ctx
            c.translateBy(x: cx - R * 0.14, y: cy - R * 0.96)
            c.rotate(by: .radians(-0.2))
            c.fill(ellipse(0, 0, R * 0.72, R * 0.27), with: .color(hex(0x4b2a5c)))
            c.fill(ellipse(-R * 0.08, -R * 0.06, R * 0.5, R * 0.15), with: .color(hex(0x5e3673)))
            c.fill(ellipse(R * 0.05, -R * 0.29, R * 0.04, R * 0.07), with: .color(hex(0x4b2a5c)))
        case "headphones":
            ctx.stroke(arc(CGPoint(x: cx, y: cy - R * 0.02), R * 1.14, .pi * 1.06, .pi * 1.94),
                       with: .color(hex(0x2b2a30)), style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round))
            for s in [-1.0, 1.0] {
                let x = cx + s * R * 1.07, y = cy + R * 0.02
                ctx.fill(ellipse(x, y, R * 0.14, R * 0.26), with: .color(hex(0x2b2a30)))
                ctx.fill(ellipse(x + s * R * 0.03, y, R * 0.06, R * 0.17), with: .color(hex(0xb8483d)))
            }
        case "pencil":
            var c = ctx
            c.translateBy(x: cx + R * 0.86, y: cy - R * 0.66)
            c.rotate(by: .radians(0.85))
            let L = R * 0.4, w = R * 0.05
            c.fill(Path(CGRect(x: -L, y: -w, width: L * 2, height: w * 2)), with: .color(hex(0xe9b82c)))
            c.fill(Path(CGRect(x: -L, y: -w * 0.25, width: L * 2, height: w * 0.5)), with: .color(hex(0xc99a1c)))
            var tip = Path()
            tip.move(to: CGPoint(x: L, y: -w)); tip.addLine(to: CGPoint(x: L + R * 0.13, y: 0)); tip.addLine(to: CGPoint(x: L, y: w)); tip.closeSubpath()
            c.fill(tip, with: .color(hex(0xe8c9a0)))
            var lead = Path()
            lead.move(to: CGPoint(x: L + R * 0.09, y: -w * 0.3)); lead.addLine(to: CGPoint(x: L + R * 0.13, y: 0)); lead.addLine(to: CGPoint(x: L + R * 0.09, y: w * 0.3)); lead.closeSubpath()
            c.fill(lead, with: .color(hex(0x3a3438)))
            c.fill(Path(CGRect(x: -L - R * 0.05, y: -w, width: R * 0.05, height: w * 2)), with: .color(hex(0xa9a9b2)))
            c.fill(Path(CGRect(x: -L - R * 0.13, y: -w, width: R * 0.08, height: w * 2)), with: .color(hex(0xe58a98)))
        case "glasses":
            let pts = [-1.0, 1.0].map { CGPoint(x: cx + $0 * R * 0.37 + gaze.x * R * 0.12, y: cy - R * 0.12 + gaze.y * R * 0.1) }
            for p in pts {
                ctx.stroke(ellipse(p.x, p.y, R * 0.25, R * 0.25), with: .color(hex(0x6b4a22)), lineWidth: R * 0.026)
            }
            ctx.stroke(arc(CGPoint(x: (pts[0].x + pts[1].x) / 2, y: pts[0].y - R * 0.02), R * 0.12, .pi * 1.15, .pi * 1.85),
                       with: .color(hex(0x6b4a22)), lineWidth: R * 0.026)
        default:
            break
        }
    }
}
