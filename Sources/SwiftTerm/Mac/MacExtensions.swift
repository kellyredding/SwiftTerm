//
//  MacExtensions.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//

#if os(macOS)
import Foundation
import AppKit

extension NSColor {
    func getTerminalColor () -> Color {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return Color.defaultForeground
        }
        
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: UInt16(red*65535), green: UInt16(green*65535), blue: UInt16(blue*65535))
    }
    func inverseColor() -> NSColor {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return self
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(calibratedRed: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    /// Returns a dimmed version of the color (for SGR 2 faint/dim text attribute)
    /// Reduces the color intensity by approximately 50%
    func dimmedColor() -> NSColor {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return self
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // Dim by reducing brightness to ~50% (blend toward black)
        let dimFactor: CGFloat = 0.5
        return NSColor(calibratedRed: red * dimFactor, green: green * dimFactor, blue: blue * dimFactor, alpha: alpha)
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor
    {
        // GALAXY: Use sRGB for true color (24-bit) values, matching Terminal.app rendering.
        return NSColor (srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return NSColor (
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha)
    }

    static func make (color: Color) -> NSColor
    {
        // GALAXY: Use sRGB color space instead of uncalibrated device RGB.
        // On P3 displays, deviceRed produces more saturated colors than intended,
        // shifting magenta toward purple and cyan toward teal. sRGB matches
        // Terminal.app's color rendering.
        return NSColor (srgbRed: CGFloat (color.red) / 65535.0,
                        green: CGFloat (color.green) / 65535.0,
                        blue: CGFloat (color.blue) / 65535.0,
                        alpha: 1.0)
    }
    
    static func transparent () -> NSColor {
        return NSColor (calibratedWhite: 0, alpha: 0)
    }
}

extension NSBezierPath {
    func addLine(to: CGPoint)
    {
        self.line (to: to)
    }
}

extension NSView {
    func rectsBeingDrawn() -> [CGRect] {
       var rectsPtr: UnsafePointer<CGRect>? = nil
       var count: Int = 0
       self.getRectsBeingDrawn(&rectsPtr, count: &count)

       return Array(UnsafeBufferPointer(start: rectsPtr, count: count))
     }
    
    public func pending(_ msg: String = "PENDING RECTS") {
        print (msg)
        for x in rectsBeingDrawn() {
            print ("   -> \(x)")
        }
    }
}
extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ignored: Bool) -> Bool
    {
        return attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue)
    }
}
#endif
