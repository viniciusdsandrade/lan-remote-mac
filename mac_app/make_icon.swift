// Desenha o ícone do app "Controle Remoto LG" em vetor (CoreGraphics) e gera o .iconset.
// Uso: swift make_icon.swift <saida.iconset>  →  iconutil -c icns <saida.iconset> -o AppIcon.icns
// Coordenadas de projeto: tela de 1024×1024 com origem no canto superior esquerdo.
import AppKit
import CoreText

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255,
                                           CGFloat(v & 0xFF) / 255, a])!
}
func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: sRGB, components: [1, 1, 1, a])! }
func black(_ a: CGFloat) -> CGColor { CGColor(colorSpace: sRGB, components: [0, 0, 0, a])! }
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// MARK: - Formas

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}

func pill(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    let r = min(w, h) / 2
    return CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                  cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Retângulo com cantos de curvatura contínua (o "squircle" dos ícones da Apple).
func continuousRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let a: CGFloat = 1.52866483, b: CGFloat = 1.08849323, c: CGFloat = 0.86840689
    let d: CGFloat = 0.66993427, e: CGFloat = 0.06549600, f: CGFloat = 0.63149399
    let g: CGFloat = 0.07491100, h: CGFloat = 0.37282392, i: CGFloat = 0.16905899
    let p = CGMutablePath()
    // m(x, y): x = distância até a aresta vertical do canto, y = até a aresta horizontal.
    func horizontalToVertical(_ m: (CGFloat, CGFloat) -> CGPoint) {
        p.addLine(to: m(a, 0))
        p.addCurve(to: m(d, e), control1: m(b, 0), control2: m(c, 0))
        p.addLine(to: m(f, g))
        p.addCurve(to: m(g, f), control1: m(h, i), control2: m(i, h))
        p.addCurve(to: m(0, a), control1: m(0, c), control2: m(0, b))
    }
    func verticalToHorizontal(_ m: (CGFloat, CGFloat) -> CGPoint) {
        p.addLine(to: m(0, a))
        p.addCurve(to: m(g, f), control1: m(0, b), control2: m(0, c))
        p.addCurve(to: m(f, g), control1: m(i, h), control2: m(h, i))
        p.addLine(to: m(d, e))
        p.addCurve(to: m(a, 0), control1: m(c, 0), control2: m(b, 0))
    }
    let tl = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }
    let tr = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
    let br = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
    let bl = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }
    p.move(to: tl(a, 0))
    horizontalToVertical(tr)
    verticalToHorizontal(br)
    horizontalToVertical(bl)
    verticalToHorizontal(tl)
    p.closeSubpath()
    return p
}

// MARK: - Pintura

struct Painter {
    let ctx: CGContext
    let k: CGFloat        // pixels por unidade de projeto
    let detail: Int       // 0: 16–32 px, 1: 64 px, 2: 128 px ou mais

    /// Largura de traço que nunca fica mais fina que `minPx` pixels reais.
    func w(_ units: CGFloat, minPx: CGFloat) -> CGFloat { max(units, minPx / k) }

    func shadowed(dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: black(alpha))
        draw()
        ctx.restoreGState()
    }
    func fill(_ p: CGPath, _ c: CGColor) {
        ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath()
    }
    func fill(_ p: CGPath, _ g: CGGradient, _ y0: CGFloat, _ y1: CGFloat) {
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func fillRadial(_ p: CGPath, _ g: CGGradient, _ center: CGPoint, _ radius: CGFloat) {
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func stroke(_ p: CGPath, _ width: CGFloat, _ g: CGGradient, _ y0: CGFloat, _ y1: CGFloat) {
        ctx.saveGState(); ctx.addPath(p); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func stroke(_ p: CGPath, _ width: CGFloat, _ c: CGColor) {
        ctx.saveGState(); ctx.addPath(p); ctx.setLineWidth(width); ctx.setStrokeColor(c)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath(); ctx.restoreGState()
    }
    /// Contorno interno: traço recortado pelo próprio caminho (só a metade de dentro aparece).
    func innerStroke(_ p: CGPath, _ width: CGFloat, _ g: CGGradient, _ y0: CGFloat, _ y1: CGFloat) {
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        stroke(p, width * 2, g, y0, y1)
        ctx.restoreGState()
    }
    func text(_ s: String, _ font: CTFont, _ color: CGColor, cx: CGFloat, cy: CGFloat, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
        ctx.saveGState()
        ctx.translateBy(x: cx - width / 2, y: cy + CTFontGetCapHeight(font) / 2)
        ctx.scaleBy(x: 1, y: -1)   // CoreText desenha com y para cima
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// Botão levemente saltado: sombra curta, gradiente vertical e brilho na borda de cima.
func button(_ P: Painter, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ y0: CGFloat, _ y1: CGFloat,
            rim: CGFloat = 0.20) {
    P.shadowed(dy: 3, blur: 7, alpha: 0.7) { P.fill(path, bottom) }
    P.fill(path, grad([(0, top), (1, bottom)]), y0, y1)
    if P.detail > 0 {
        P.innerStroke(path, P.w(2, minPx: 0.6), grad([(0, white(rim)), (0.45, white(0))]), y0, y1)
    }
}

// MARK: - Glifos

let glyph = hex(0xD5D8DE, 0.92)

func triangle(_ cx: CGFloat, _ cy: CGFloat, dx: CGFloat, dy: CGFloat, len: CGFloat, half: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx + dx * len * 0.55, y: cy + dy * len * 0.55))
    p.addLine(to: CGPoint(x: cx - dx * len * 0.45 - dy * half, y: cy - dy * len * 0.45 + dx * half))
    p.addLine(to: CGPoint(x: cx - dx * len * 0.45 + dy * half, y: cy - dy * len * 0.45 - dx * half))
    p.closeSubpath()
    return p
}

func roundedTriangle(_ P: Painter, _ path: CGPath, _ c: CGColor, round: CGFloat) {
    P.fill(path, c)
    P.stroke(path, round, c)
}

// MARK: - Controle

func drawRemote(_ P: Painter) {
    let body = CGRect(x: 262, y: 30, width: 500, height: 936)
    let bodyPath = continuousRect(body, 118)

    // Corpo: grafite que escurece até quase preto, com sombra projetada suave.
    P.shadowed(dy: 12, blur: 26, alpha: 0.55) { P.fill(bodyPath, hex(0x0B0C0E)) }
    P.fill(bodyPath, grad([(0, hex(0x2B2D32)), (0.16, hex(0x1C1D21)), (0.6, hex(0x131417)), (1, hex(0x0A0B0D))]),
           body.minY, body.maxY)
    P.fillRadial(bodyPath, grad([(0, white(0.07)), (1, white(0))]), CGPoint(x: 400, y: 70), 560)
    // Borda iluminada, mais forte em cima, para o preto não sumir em fundo escuro.
    P.innerStroke(bodyPath, P.w(2.5, minPx: 0.9),
                  grad([(0, white(0.42)), (0.12, white(0.16)), (0.6, white(0.07)), (1, white(0.12))]),
                  body.minY, body.maxY)

    // Janela do infravermelho.
    if P.detail > 0 {
        let ir = pill(512, 60, 84, 13)
        P.fill(ir, black(0.9))
        P.innerStroke(ir, 1.5, grad([(0, white(0)), (1, white(0.12))]), 54, 67)
    }

    // Linha de cima: liga/desliga (vermelho) e entrada.
    let power = circle(354, 134, 36)
    button(P, power, hex(0xF0544C), hex(0xB4231E), 98, 170, rim: 0.35)
    if P.detail > 0 {
        let ring = CGMutablePath()
        ring.addArc(center: CGPoint(x: 354, y: 135), radius: 15, startAngle: -.pi / 2 + 0.62,
                    endAngle: 1.5 * .pi - 0.62, clockwise: false)
        P.stroke(ring, 5.5, white(0.95))
        let bar = CGMutablePath(); bar.move(to: CGPoint(x: 354, y: 115)); bar.addLine(to: CGPoint(x: 354, y: 133))
        P.stroke(bar, 5.5, white(0.95))
    }
    if P.detail > 0 {
        let input = circle(670, 134, 30)
        button(P, input, hex(0x36383E), hex(0x1C1D21), 104, 164)
        if P.detail > 1 {
            let box = CGPath(roundedRect: CGRect(x: 659, y: 124, width: 24, height: 20), cornerWidth: 4,
                             cornerHeight: 4, transform: nil)
            P.stroke(box, 3.5, glyph)
            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: 652, y: 134)); arrow.addLine(to: CGPoint(x: 670, y: 134))
            arrow.move(to: CGPoint(x: 664, y: 128)); arrow.addLine(to: CGPoint(x: 670, y: 134))
            arrow.addLine(to: CGPoint(x: 664, y: 140))
            P.stroke(arrow, 3.5, glyph)
        }
    }

    // Direcional: base escura, anel metálico, setas e OK.
    let c = CGPoint(x: 512, y: 354)
    let padR: CGFloat = 158
    let pad = circle(c.x, c.y, padR)
    P.shadowed(dy: 5, blur: 12, alpha: 0.7) { P.fill(pad, hex(0x111215)) }
    P.fillRadial(pad, grad([(0, hex(0x2A2C31)), (0.7, hex(0x1A1B1F)), (1, hex(0x111215))]),
                 CGPoint(x: c.x, y: c.y - 50), padR * 1.2)
    P.stroke(circle(c.x, c.y, padR - 4), P.w(8, minPx: 1.2),
             grad([(0, hex(0xF5F6F8)), (0.28, hex(0xB9BCC3)), (0.55, hex(0x63666D)), (0.8, hex(0x8E9299)),
                   (1, hex(0xD8DADF))]), c.y - padR, c.y + padR)
    if P.detail > 0 {
        for (dx, dy) in [(0.0, -1.0), (1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)] {
            let t = triangle(c.x + dx * 114, c.y + dy * 114, dx: dx, dy: dy, len: 20, half: 15)
            roundedTriangle(P, t, glyph, round: 5)
        }
        P.stroke(circle(c.x, c.y, 77), 3, black(0.55))
        P.stroke(circle(c.x, c.y, 79.5), 1.5, white(0.06))
    }
    let ok = circle(c.x, c.y, 66)
    button(P, ok, hex(0x3C3E44), hex(0x1E1F23), c.y - 66, c.y + 66, rim: 0.24)
    if P.detail > 1 {
        P.text("OK", CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 34, nil), white(0.85),
               cx: c.x, cy: c.y)
    }

    // Volume e canal (balancins) com o botão "home" no meio.
    for x: CGFloat in [360, 664] {
        button(P, pill(x, 644, 86, 188), hex(0x33353A), hex(0x1A1B1F), 550, 738)
    }
    if P.detail > 0 {
        let s = CGMutablePath()
        s.move(to: CGPoint(x: 347, y: 594)); s.addLine(to: CGPoint(x: 373, y: 594))   // +
        s.move(to: CGPoint(x: 360, y: 581)); s.addLine(to: CGPoint(x: 360, y: 607))
        s.move(to: CGPoint(x: 347, y: 694)); s.addLine(to: CGPoint(x: 373, y: 694))   // −
        s.move(to: CGPoint(x: 651, y: 600)); s.addLine(to: CGPoint(x: 664, y: 587))   // ∧
        s.addLine(to: CGPoint(x: 677, y: 600))
        s.move(to: CGPoint(x: 651, y: 688)); s.addLine(to: CGPoint(x: 664, y: 701))   // ∨
        s.addLine(to: CGPoint(x: 677, y: 688))
        P.stroke(s, 5, glyph)

        let home = circle(512, 644, 40)
        button(P, home, hex(0x36383E), hex(0x1C1D21), 604, 684)
        if P.detail > 1 {
            let house = CGMutablePath()
            house.move(to: CGPoint(x: 494, y: 644)); house.addLine(to: CGPoint(x: 512, y: 628))
            house.addLine(to: CGPoint(x: 530, y: 644))
            house.move(to: CGPoint(x: 499, y: 640)); house.addLine(to: CGPoint(x: 499, y: 660))
            house.addLine(to: CGPoint(x: 525, y: 660)); house.addLine(to: CGPoint(x: 525, y: 640))
            P.stroke(house, 4, glyph)
        }
    }

    // Teclas coloridas, em tons mais sóbrios.
    let keys: [(UInt32, UInt32)] = [(0xDE4B43, 0xA62F29), (0x3DAE60, 0x217A3C), (0xE9BC3B, 0xB38612),
                                    (0x4385EA, 0x2257B5)]
    let kw: CGFloat = 86, kh: CGFloat = 28, gap: CGFloat = 18
    let start = 512 - (4 * kw + 3 * gap) / 2 + kw / 2
    for (i, key) in keys.enumerated() {
        let x = start + CGFloat(i) * (kw + gap)
        button(P, pill(x, 782, kw, kh), hex(key.0), hex(key.1), 768, 796, rim: 0.35)
    }

    // Mídia: voltar, tocar, pausar, avançar.
    if P.detail > 0 {
        for (i, x) in [362.0, 462.0, 562.0, 662.0].enumerated() {
            let cx = CGFloat(x), cy: CGFloat = 844
            button(P, circle(cx, cy, 25), hex(0x303237), hex(0x1A1B1F), cy - 25, cy + 25)
            guard P.detail > 1 else { continue }
            switch i {
            case 0:
                roundedTriangle(P, triangle(cx - 6, cy, dx: -1, dy: 0, len: 12, half: 8), glyph, round: 2)
                roundedTriangle(P, triangle(cx + 5, cy, dx: -1, dy: 0, len: 12, half: 8), glyph, round: 2)
            case 1:
                roundedTriangle(P, triangle(cx + 1, cy, dx: 1, dy: 0, len: 17, half: 10), glyph, round: 2)
            case 2:
                P.fill(CGPath(roundedRect: CGRect(x: cx - 8, y: cy - 9, width: 5.5, height: 18), cornerWidth: 1.5,
                              cornerHeight: 1.5, transform: nil), glyph)
                P.fill(CGPath(roundedRect: CGRect(x: cx + 2.5, y: cy - 9, width: 5.5, height: 18), cornerWidth: 1.5,
                              cornerHeight: 1.5, transform: nil), glyph)
            default:
                roundedTriangle(P, triangle(cx - 5, cy, dx: 1, dy: 0, len: 12, half: 8), glyph, round: 2)
                roundedTriangle(P, triangle(cx + 6, cy, dx: 1, dy: 0, len: 12, half: 8), glyph, round: 2)
            }
        }
    }

    // Marca.
    if P.detail > 1 {
        P.text("LG", CTFontCreateWithName("AvenirNext-Bold" as CFString, 42, nil), hex(0x9C9FA6, 0.85),
               cx: 512, cy: 916, kern: 1.5)
    }
}

// MARK: - Saída

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: k, y: -k)
    drawRemote(Painter(ctx: ctx, k: k, detail: size >= 128 ? 2 : (size >= 64 ? 1 : 0)))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("não consegui gravar \(path)") }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    writePNG(render(px), "\(out)/icon_\(name).png")
}
print("ícone gerado em \(out)")
