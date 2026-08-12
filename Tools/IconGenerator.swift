import AppKit
import Foundation

// App 图标,规范「玻璃仪表」同源:石墨机身 + 白色脉搏线,唯一的颜色
// 是波形末端一颗绿点——与界面右上角的「实时」灯同色,黑白仪器上
// 唯一活着的东西。旧版绿紫蓝渐变与全单色界面互为外人,已废。

guard CommandLine.arguments.count == 2 else {
    fputs("usage: IconGenerator output.png\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("unable to create graphics context\n", stderr)
    exit(3)
}

context.setAllowsAntialiasing(true)
let outer = NSBezierPath(
    roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
    xRadius: 216,
    yRadius: 216
)
// 石墨机身:单色纵向渐变只做明暗,不做色相。
NSGradient(colors: [
    NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1),
    NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
])?.draw(in: outer, angle: -90)

// 发丝内边:深色 Dock 上勾出轮廓,亮度克制。
let border = NSBezierPath(
    roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848),
    xRadius: 202,
    yRadius: 202
)
NSColor.white.withAlphaComponent(0.10).setStroke()
border.lineWidth = 3
border.stroke()

// 脉搏线:白,圆帽圆角,无投影无辉光。
let pulse = NSBezierPath()
pulse.move(to: NSPoint(x: 238, y: 500))
pulse.line(to: NSPoint(x: 346, y: 500))
pulse.line(to: NSPoint(x: 404, y: 674))
pulse.line(to: NSPoint(x: 492, y: 360))
pulse.line(to: NSPoint(x: 570, y: 590))
pulse.line(to: NSPoint(x: 628, y: 500))
pulse.line(to: NSPoint(x: 752, y: 500))
pulse.lineWidth = 54
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.92).setStroke()
pulse.stroke()

// 唯一的颜色:波形末端的「实时」绿点,与界面语义色 normal 同值。
NSColor(red: 0.24, green: 0.84, blue: 0.55, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 762, y: 464, width: 72, height: 72)).fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("unable to encode png\n", stderr)
    exit(4)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
