import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let background = NSBezierPath(roundedRect:NSRect(x:32,y:32,width:960,height:960),xRadius:216,yRadius:216)
NSColor(calibratedRed:0.17,green:0.18,blue:0.16,alpha:1).setFill(); background.fill()
let arch = NSBezierPath(roundedRect:NSRect(x:264,y:196,width:496,height:632),xRadius:190,yRadius:190)
NSColor(calibratedRed:0.92,green:0.62,blue:0.27,alpha:1).setFill(); arch.fill()
let opening = NSBezierPath(roundedRect:NSRect(x:356,y:196,width:312,height:540),xRadius:144,yRadius:144)
NSColor(calibratedRed:0.17,green:0.18,blue:0.16,alpha:1).setFill(); opening.fill()
NSBezierPath(rect:NSRect(x:356,y:184,width:312,height:260)).fill()
let threshold = NSBezierPath(roundedRect:NSRect(x:236,y:196,width:552,height:64),xRadius:32,yRadius:32)
NSColor(calibratedRed:0.92,green:0.62,blue:0.27,alpha:1).setFill(); threshold.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
