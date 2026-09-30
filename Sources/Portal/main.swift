import AppKit
import SwiftUI
import PortalCore

if CommandLine.arguments.contains("--ssh-askpass") { runAskpass() }

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    let model = AppModel()
    var home: NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle:"About Portal",action:#selector(about),keyEquivalent:"")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Settings",action:#selector(settings),keyEquivalent:",")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Hide Portal",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"Quit Portal",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        app.submenu = appMenu; menu.addItem(app)
        let file = NSMenuItem(); file.title = "File"; let fileMenu = NSMenu(title:"File")
        fileMenu.addItem(withTitle:"Add Computer",action:#selector(addComputer),keyEquivalent:"n")
        fileMenu.addItem(withTitle:"Show Computers",action:#selector(showHome),keyEquivalent:"0")
        fileMenu.addItem(withTitle:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        file.submenu = fileMenu; menu.addItem(file)
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title:"Edit")
        for (title,action,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle:title,action:action,keyEquivalent:key) }
        edit.submenu = editMenu; menu.addItem(edit)
        let windowItem = NSMenuItem(); windowItem.title = "Window"; let windowMenu = NSMenu(title:"Window")
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        windowItem.submenu = windowMenu; menu.addItem(windowItem); NSApp.windowsMenu = windowMenu; NSApp.mainMenu = menu
        let startingSize = NSSize(width:515,height:660)
        home = makeWindow(title:"Portal",size:startingSize)
        home.styleMask.remove(.fullSizeContentView)
        home.titleVisibility = .visible
        home.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier:"PortalHomeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        home.toolbar = toolbar
        let homeView = NSHostingView(rootView:HomeView(model:model))
        homeView.sizingOptions = []
        home.contentView = homeView
        home.minSize = NSSize(width:startingSize.width,height:460)
        home.maxSize = NSSize(width:startingSize.width,height:home.maxSize.height)
        home.collectionBehavior = [.fullScreenNone]
        home.setFrame(NSRect(origin:home.frame.origin,size:startingSize),display:false)
        home.center(); showHome(); NSApp.activate(ignoringOtherApps:true)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, NSToolbarItem.Identifier("addComputer")] }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "addComputer" else { return nil }
        let item = NSToolbarItem(itemIdentifier:identifier)
        item.label = "Add Computer"
        item.toolTip = "Add computer (⌘N)"
        item.image = NSImage(systemSymbolName:"plus",accessibilityDescription:"Add computer")
        item.target = self
        item.action = #selector(addComputer)
        item.isBordered = false
        return item
    }
    @objc func showHome() { home?.makeKeyAndOrderFront(nil) }
    @objc func settings() { showHome(); NotificationCenter.default.post(name:Notification.Name("PortalSettings"),object:nil) }
    @objc func addComputer() { showHome(); NotificationCenter.default.post(name:Notification.Name("PortalAddComputer"),object:nil) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Portal",.applicationVersion:"0.1.0",.credits:NSAttributedString(string:"A simple, native VNC client.\nFree software, licensed under GPL-2.0-or-later.\nPowered by LibVNCClient.")]) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { showHome(); return true }
    func applicationWillTerminate(_ notification:Notification) { model.stopAll() }
    func application(_ application:NSApplication,open urls:[URL]) { for url in urls where url.scheme == "vnc" { do { let endpoint = try Endpoint(url.absoluteString); model.connect(Computer(name:endpoint.host,address:endpoint.address)) } catch { model.alert = error.localizedDescription } } }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
