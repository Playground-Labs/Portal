import SwiftUI
import AppKit
import PortalCore

extension Color {
    static let portalAccent = Color(red:0.65,green:0.36,blue:0.07)
    static let portalBackground = Color(nsColor:.windowBackgroundColor)
}
struct ControlHover: ViewModifier {
    var pressed = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius:5))
            .overlay {
                RoundedRectangle(cornerRadius:5)
                    .fill((scheme == .dark ? Color.white : Color.black).opacity(enabled ? (pressed ? 0.16 : hovering ? 0.09 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:hovering)
    }
}

struct SoftButton: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        let dark = scheme == .dark
        let background = primary ? (dark ? Color(red:0.30,green:0.22,blue:0.14) : Color(red:0.96,green:0.90,blue:0.81)) : (dark ? Color(red:0.20,green:0.23,blue:0.21) : Color(red:0.94,green:0.95,blue:0.94))
        let foreground = primary ? (dark ? Color(red:0.95,green:0.79,blue:0.54) : Color(red:0.47,green:0.26,blue:0.04)) : Color.primary
        configuration.label.font(.system(size:12,weight:.medium)).padding(.horizontal,12).frame(minHeight:30).foregroundStyle(foreground).background(background.opacity(configuration.isPressed ? 0.65 : 1),in:RoundedRectangle(cornerRadius:5)).opacity(enabled ? 1 : 0.45).modifier(ControlHover(pressed:configuration.isPressed))
    }
}
struct PortalAppearance<Content: View>: View {
    @AppStorage("appearance") var appearance = "system"
    @ViewBuilder var content: () -> Content
    var body: some View { content().tint(.portalAccent).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil) }
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @StateObject var discovery = Discovery()
    @State private var address = ""
    @State private var editing: Computer?
    @State private var settings = false
    @State private var selected: UUID?
    @State private var deleting: Computer?
    @AppStorage("discoverNearby") private var discoverNearby = true
    var body: some View {
        PortalAppearance {
            VStack(spacing:0) {
                ScrollView {
                    VStack(alignment:.leading,spacing:26) {
                        VStack(alignment:.leading,spacing:6) { Text("Your computers").font(.system(size:24,weight:.semibold)); Text("Your 127.0.0.1 away from home").foregroundStyle(.secondary).font(.system(size:13)) }
                        HStack(spacing:12) {
                            TextField("Enter an address to connect",text:$address).textFieldStyle(.plain).onSubmit(quickConnect).accessibilityLabel("Quick Connect address")
                            Button("Connect",action:quickConnect).buttonStyle(SoftButton(primary:true)).disabled(address.trimmingCharacters(in:.whitespaces).isEmpty)
                        }.padding(.horizontal,12).frame(height:44).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.primary.opacity(0.1)))
                        VStack(alignment:.leading,spacing:12) {
                            sectionLabel("SAVED COMPUTERS",count:model.computers.count)
                            if model.computers.isEmpty {
                                VStack(spacing:12) { Image(systemName:"desktopcomputer").font(.system(size:32,weight:.light)).foregroundStyle(.secondary); Text("Your computers belong here").font(.headline); Text("Save a computer for an effortless return.").foregroundStyle(.secondary) }.frame(maxWidth:.infinity).padding(.vertical,36)
                            } else {
                                VStack(spacing:0) { ForEach(model.computers) { computer in
                                    computerRow(computer,saved:true)
                                    if computer.id != model.computers.last?.id { Divider().padding(.leading,56).opacity(0.45) }
                                } }.background(Color(nsColor:.textBackgroundColor).opacity(0.5),in:RoundedRectangle(cornerRadius:8))
                            }
                        }
                        if discoverNearby {
                            VStack(alignment:.leading,spacing:12) {
                                sectionLabel("NEARBY",count:discovery.computers.count)
                                if discovery.computers.isEmpty { HStack(spacing:8) { Image(systemName:"network"); Text("Computers on your network appear here.") }.font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,10) }
                                else { ForEach(discovery.computers) { computer in computerRow(computer,saved:false) } }
                            }
                        }
                    }.padding(.horizontal,24).padding(.vertical,28)
                }
                Divider().opacity(0.5)
                HStack {
                    Button { settings = true } label: {
                        Image(systemName:"gearshape").font(.system(size:18,weight:.regular))
                            .frame(width:32,height:32).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).modifier(ControlHover())
                        .help("Settings (⌘,)").accessibilityLabel("Settings")
                    Spacer()
                    Text("Free and open source").font(.system(size:11)).foregroundStyle(.tertiary)
                }.padding(.leading,17).padding(.trailing,24).frame(height:44)
            }.background(Color.portalBackground)
            .sheet(item:$editing) { computer in ConnectionEditor(computer:computer) { model.save($0) } }
            .sheet(isPresented:$settings) { SettingsView(model:model) }
            .alert("Portal",isPresented:Binding(get:{ model.alert != nil },set:{ if !$0 { model.alert = nil } })) { Button("OK") { model.alert = nil } } message: { Text(model.alert ?? "") }
            .confirmationDialog("Remove \(deleting?.name ?? "computer")?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } })) { Button("Remove",role:.destructive) { if let deleting { model.remove(deleting) }; deleting = nil }; Button("Cancel",role:.cancel) { deleting = nil } } message: { Text("Its saved password will also be removed from Keychain.") }
            .onAppear { discovery.setEnabled(discoverNearby) }
            .onChange(of:discoverNearby) { _,enabled in discovery.setEnabled(enabled) }
            .onReceive(NotificationCenter.default.publisher(for:Notification.Name("PortalSettings"))) { _ in settings = true }
            .onReceive(NotificationCenter.default.publisher(for:Notification.Name("PortalAddComputer"))) { _ in editing = Computer(name:"",address:"") }
        }
    }
    private func sectionLabel(_ text:String,count:Int) -> some View { HStack(spacing:8) { Text(text).tracking(1.1); Text("\(count)").foregroundStyle(.tertiary); Spacer() }.font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary) }
    private func computerRow(_ computer:Computer,saved:Bool) -> some View {
        HStack(spacing:14) {
            Image(systemName:"desktopcomputer").font(.system(size:21,weight:.light)).foregroundStyle(.secondary).frame(width:30)
            VStack(alignment:.leading,spacing:5) { Text(computer.name).font(.system(size:13,weight:.medium)); Text(computer.address).font(.system(size:11)).foregroundStyle(.secondary) }
            Spacer()
            if computer.ssh.enabled { Image(systemName:"lock.shield").font(.system(size:12)).foregroundStyle(.secondary).help("Connects through SSH") }
            Button("Connect") { model.connect(computer) }.buttonStyle(SoftButton(primary:selected == computer.id))
            Menu { if saved { Button("Edit Computer") { editing = computer }; Button("Forget Password") { do { try Keychain.write(nil,account:computer.credentialAccount) } catch { model.alert = error.localizedDescription } }; Divider(); Button("Remove Computer",role:.destructive) { deleting = computer } } else { Button("Save Computer") { model.save(computer) } } } label: { Image(systemName:"ellipsis").frame(width:20,height:28) }.menuStyle(.borderlessButton).fixedSize().modifier(ControlHover()).accessibilityLabel("Computer actions")
        }.padding(.horizontal,14).frame(height:66).contentShape(Rectangle()).background(selected == computer.id ? Color.portalAccent.opacity(0.06) : .clear).onTapGesture(count:2) { model.connect(computer) }.onTapGesture { selected = computer.id }
    }
    private func quickConnect() {
        do { let endpoint = try Endpoint(address); let computer = model.computers.first(where:{ $0.address == endpoint.address }) ?? Computer(name:endpoint.host,address:endpoint.address); model.connect(computer) } catch { model.alert = error.localizedDescription }
    }
}

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var computer: Computer
    var save: (Computer) -> Void
    @State private var advanced = false
    @State private var error = ""
    var body: some View {
        PortalAppearance {
            VStack(spacing:0) {
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                Text(computer.name.isEmpty ? "New computer" : "Edit computer").font(.system(size:20,weight:.semibold))
                VStack(alignment:.leading,spacing:14) {
                    field("Name",placeholder:"Studio Mac",text:$computer.name)
                    field("Address",placeholder:"computer.local or 192.168.1.10",text:$computer.address)
                    Text("VNC must be enabled on the remote computer. Add :5901 for a custom port.").font(.system(size:11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Advanced",isExpanded:$advanced) {
                        VStack(alignment:.leading,spacing:16) {
                            field("Username",placeholder:"Ask when needed",text:$computer.username)
                            Toggle("Connect through SSH",isOn:$computer.ssh.enabled)
                            if computer.ssh.enabled {
                                HStack { field("SSH server",placeholder:"server.example.com",text:$computer.ssh.host); VStack(alignment:.leading) { Text("Port").font(.system(size:12,weight:.medium)); TextField("22",value:$computer.ssh.port,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width:72) } }
                                field("SSH username",placeholder:"Username",text:$computer.ssh.username)
                                HStack(alignment:.bottom) { field("Private key (optional)",placeholder:"Use password or SSH agent",text:$computer.ssh.keyPath); Button("Choose") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.showsHiddenFiles = true; if panel.runModal() == .OK { computer.ssh.keyPath = panel.url?.path ?? "" } }.buttonStyle(SoftButton()) }
                                Text("The VNC address is reached from the SSH server.").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            Picker("Display",selection:$computer.sizing) { Text("Automatic resize, or fit").tag(DisplaySizing.automatic); Text("Fit to window").tag(DisplaySizing.fit); Text("Actual size").tag(DisplaySizing.actual) }
                            Picker("Image quality",selection:$computer.quality) { ForEach(ImageQuality.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }
                            Picker("Clipboard",selection:$computer.clipboard) { Text("Share both ways").tag(ClipboardMode.bidirectional); Text("Receive only").tag(ClipboardMode.receive); Text("Off").tag(ClipboardMode.off) }
                            Toggle("View only",isOn:$computer.viewOnly)
                            Toggle("Play remote audio when available",isOn:$computer.audioEnabled)
                        }.padding(.top,16).padding(.trailing,4)
                }.font(.system(size:12)).toggleStyle(.switch).controlSize(.small)
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
                    }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
                }
                Divider().opacity(0.5)
                HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction); Button("Save") { do { computer.address = try Endpoint(computer.address).address; if computer.name.trimmingCharacters(in:.whitespaces).isEmpty { computer.name = try Endpoint(computer.address).host }; try computer.validate(); save(computer); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(SoftButton(primary:true)).keyboardShortcut(.defaultAction) }.padding(.horizontal,24).padding(.vertical,12)
            }.frame(width:468,height:560)
        }
    }
    private func field(_ title:String,placeholder:String,text:Binding<String>) -> some View { VStack(alignment:.leading,spacing:7) { Text(title).font(.system(size:12,weight:.medium)); TextField(placeholder,text:text).textFieldStyle(.roundedBorder) } }
}

struct SettingsView: View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("autoReconnect") var reconnect = true
    @AppStorage("discoverNearby") var discovery = true
    @AppStorage("hideFullscreenToolbar") var hideToolbar = true
    var body:some View {
        PortalAppearance {
            VStack(spacing:0) {
                HStack { Text("Settings").font(.system(size:20,weight:.semibold)); Spacer() }
                    .padding(.horizontal,24).padding(.top,20).padding(.bottom,16)
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        VStack(spacing:0) {
                            HStack {
                                Text("Appearance")
                                Spacer()
                                Picker("Appearance",selection:$appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                                    .labelsHidden().frame(width:120)
                            }.frame(minHeight:34)
                            Divider()
                            Toggle(isOn:$discovery) { HStack { Text("Discover nearby computers"); Spacer() } }.frame(minHeight:34)
                            Divider()
                            Toggle(isOn:$reconnect) { HStack { Text("Reconnect after an interruption"); Spacer() } }.frame(minHeight:34)
                            Divider()
                            Toggle(isOn:$hideToolbar) { HStack { Text("Hide session controls in fullscreen"); Spacer() } }.frame(minHeight:34)
                        }.toggleStyle(.switch).controlSize(.small).padding(.horizontal,12).padding(.vertical,4)
                            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                        VStack(alignment:.leading,spacing:8) {
                            Text("Privacy & security").font(.system(size:13,weight:.semibold))
                            Text("Passwords stay in macOS Keychain. No analytics.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            Button("Reset Connection Trust") { model.resetTrust() }.buttonStyle(SoftButton())
                            Text("Shows encryption and certificate prompts again. Previously trusted SSH servers stay trusted.").font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                    }.padding(.horizontal,24).padding(.bottom,16)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider().opacity(0.5)
                HStack {
                    Text("Portal · Free and open source").font(.system(size:11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(SoftButton(primary:true)).keyboardShortcut(.defaultAction)
                }.padding(.horizontal,24).padding(.vertical,12)
            }.font(.system(size:12)).frame(width:468,height:400)
        }
    }
}
