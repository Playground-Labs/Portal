import SwiftUI
import AppKit
import PortalCore

struct SessionView: View {
    @ObservedObject var session: Session
    @State private var fullscreen = false
    @State private var revealControls = false
    @State private var showHint = false
    @State private var hintWork: DispatchWorkItem?
    @AppStorage("hideFullscreenToolbar") private var hideToolbar = true
    private var controlsVisible: Bool { !fullscreen || !hideToolbar || revealControls }
    var body: some View {
        PortalAppearance {
            VStack(spacing:0) {
                if controlsVisible { toolbar }
                ZStack {
                    RemoteDesktop(session:session)
                    if !session.connected {
                        Color.black.opacity(0.72)
                        VStack(spacing:16) {
                            if session.error.isEmpty { ProgressView().controlSize(.large) } else { Image(systemName:session.retrying ? "arrow.clockwise" : "network.slash").font(.system(size:30,weight:.light)) }
                            Text(session.status).font(.system(size:20,weight:.semibold))
                            Text(session.computer.name).foregroundStyle(.secondary)
                            if !session.error.isEmpty { Text(session.error).font(.system(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth:420) }
                            HStack { if !session.error.isEmpty { Button("Try Again") { session.start() }.buttonStyle(SoftButton(primary:true)) }; Button(session.retrying || session.error.isEmpty ? "Cancel" : "Close") { session.window?.close() }.buttonStyle(SoftButton()) }
                        }.padding(32).foregroundStyle(.white).colorScheme(.dark)
                    }
                    if showHint && session.connected {
                        VStack { Spacer(); Text("Control + Option + Escape releases your keyboard").font(.system(size:12,weight:.medium)).padding(.horizontal,16).padding(.vertical,10).background(.regularMaterial,in:Capsule()).padding(.bottom,24) }.allowsHitTesting(false)
                    }
                    if fullscreen && hideToolbar { VStack { Color.clear.frame(height:8).contentShape(Rectangle()).onHover { over in if over { revealControls = true } }; Spacer() } }
                }
            }.background(Color.portalBackground).ignoresSafeArea(.container,edges:.top)
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didEnterFullScreenNotification)) { note in if note.object as? NSWindow === session.window { fullscreen = true; revealControls = false } }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didExitFullScreenNotification)) { note in if note.object as? NSWindow === session.window { fullscreen = false } }
            .onChange(of:session.captured) { _,captured in
                hintWork?.cancel(); showHint = captured
                if captured { let work = DispatchWorkItem { showHint = false }; hintWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+4,execute:work) }
            }
        }
    }
    private var toolbar: some View {
        HStack(spacing:6) {
            Spacer().frame(width:76)
            Spacer()
            HStack(spacing:6) { if session.encrypted { Image(systemName:"lock.fill").font(.system(size:9)).foregroundStyle(.secondary) }; Text(session.computer.name).font(.system(size:12,weight:.medium)).lineLimit(1) }
            Spacer()
            Menu {
                Picker("Display sizing",selection:$session.computer.sizing) { Text("Automatic resize, or fit").tag(DisplaySizing.automatic); Text("Fit to Window").tag(DisplaySizing.fit); Text("Actual Size").tag(DisplaySizing.actual) }
                Divider()
                Button("All Displays") { session.selectedScreen = nil }
                ForEach(Array(session.screens.enumerated()),id:\.element.id) { index, screen in Button("Display \(index+1) · \(screen.width) × \(screen.height)") { session.selectedScreen = screen.id } }
                Divider()
                Picker("Image quality",selection:$session.computer.quality) { ForEach(ImageQuality.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }
                Button(fullscreen ? "Exit Fullscreen" : "Enter Fullscreen") { session.window?.toggleFullScreen(nil) }
            } label: { Image(systemName:"display").frame(width:26,height:28) }.fixedSize().menuIndicator(.hidden).frame(width:32).modifier(ControlHover()).foregroundStyle(.secondary).help("Display").accessibilityLabel("Display controls")
            Menu {
                if session.audioAvailable {
                    Toggle("Play Remote Audio",isOn:Binding(get:{ session.computer.audioEnabled },set:session.setAudio))
                    Menu("Volume") { ForEach([25,50,75,100],id:\.self) { volume in Button("\(volume)%") { session.computer.volume = Float(volume)/100; session.updatePreferences() } } }
                    if !session.audioError.isEmpty { Text(session.audioError) }
                } else { Text("Audio unavailable"); Text("This server does not provide compatible audio.") }
            } label: { Image(systemName:session.audioAvailable && session.computer.audioEnabled ? "speaker.wave.2" : "speaker.slash").frame(width:26,height:28) }.fixedSize().menuIndicator(.hidden).frame(width:32).modifier(ControlHover()).foregroundStyle(.secondary).help(session.audioAvailable ? "Sound" : "Audio unavailable on this server").accessibilityLabel("Sound controls")
            Menu {
                Text(session.status)
                Text(session.computer.address)
                Text(session.encrypted ? "Encrypted connection" : "Unencrypted connection")
                if let image = session.image { Text("\(image.width) × \(image.height)") }
                Divider()
                Toggle("View Only",isOn:$session.computer.viewOnly)
                Picker("Clipboard",selection:$session.computer.clipboard) { Text("Share Both Ways").tag(ClipboardMode.bidirectional); Text("Receive Only").tag(ClipboardMode.receive); Text("Off").tag(ClipboardMode.off) }
                if !session.clipboardError.isEmpty { Text(session.clipboardError) }
                Menu("Send Special Keys") {
                    Button("Control + Alt + Delete") { session.special([0xffe3,0xffe9,0xffff]) }
                    Button("Command / Windows Key") { session.special([0xffeb]) }
                    Button("Escape") { session.special([0xff1b]) }
                    Button("Print Screen") { session.special([0xff61]) }
                }
                Text("Release keyboard: ⌃⌥Esc")
                Divider()
                Button("Reconnect") { session.start() }
                Button("Disconnect") { session.window?.close() }
            } label: { Image(systemName:"ellipsis").frame(width:26,height:28) }.fixedSize().menuIndicator(.hidden).frame(width:32).modifier(ControlHover()).foregroundStyle(.secondary).help("Session").accessibilityLabel("Session controls")
        }.menuStyle(.borderlessButton).fixedSize(horizontal:false,vertical:true).padding(.trailing,14).frame(height:44).background(Color.portalBackground)
        .onHover { over in if fullscreen && hideToolbar && !over { DispatchQueue.main.asyncAfter(deadline:.now()+1) { revealControls = false } } }
        .onChange(of:session.computer.sizing) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.quality) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.clipboard) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.viewOnly) { _,_ in session.updatePreferences() }
    }
}
