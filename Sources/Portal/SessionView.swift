import SwiftUI
import AppKit
import PortalCore

struct SessionView: View {
    @ObservedObject var session: Session
    @State private var fullscreen = false
    private enum Panel { case display, sound, session }
    @State private var panel: Panel?
    @State private var panelHeight: CGFloat = 320
    @FocusState private var panelFocused: Bool
    @State private var revealControls = false
    @State private var showHint = false
    @State private var hintWork: DispatchWorkItem?
    @AppStorage("hideFullscreenToolbar") private var hideToolbar = true
    private var controlsVisible: Bool { !fullscreen || !hideToolbar || revealControls || panel != nil }
    var body: some View {
        PortalAppearance {
            VStack(spacing:0) {
                if controlsVisible { toolbar }
                ZStack {
                    RemoteDesktop(session:session)
                    if !session.connected {
                        Color.black.opacity(0.72)
                        VStack(spacing:16) {
                            if session.error.isEmpty { PortalProgress() } else { Image(systemName:session.retrying ? "arrow.clockwise" : "network.slash").font(.system(size:30,weight:.light)) }
                            Text(session.status).font(.portal(size:20,weight:.semibold))
                            Text(session.computer.name).foregroundStyle(.secondary)
                            if !session.error.isEmpty { Text(session.error).font(.portal(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth:420) }
                            HStack { if !session.error.isEmpty { Button("Try Again") { session.start() }.buttonStyle(SoftButton(primary:true)) }; Button(session.retrying || session.error.isEmpty ? "Cancel" : "Close") { session.window?.close() }.buttonStyle(SoftButton()) }
                        }.padding(32).foregroundStyle(.white).colorScheme(.dark)
                    }
                    if showHint && session.connected {
                        VStack { Spacer(); Text("Control + Option + Escape releases your keyboard").font(.portal(size:12,weight:.medium)).padding(.horizontal,16).padding(.vertical,10).background(Color.portalBackground,in:RoundedRectangle(cornerRadius:7)).padding(.bottom,24) }.allowsHitTesting(false)
                    }
                    if fullscreen && hideToolbar { VStack { Color.clear.frame(height:8).contentShape(Rectangle()).onHover { over in if over { revealControls = true } }; Spacer() } }
                }
            }.overlay { sessionPanel }.background(Color.portalBackground).ignoresSafeArea(.container,edges:.top)
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didEnterFullScreenNotification)) { note in if note.object as? NSWindow === session.window { fullscreen = true; revealControls = false } }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didExitFullScreenNotification)) { note in if note.object as? NSWindow === session.window { fullscreen = false } }
            .onChange(of:session.captured) { _,captured in
                hintWork?.cancel(); showHint = captured
                if captured { let work = DispatchWorkItem { showHint = false }; hintWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+4,execute:work) }
            }
        }
    }
    private func toolbarButton(_ target: Panel) -> some View {
        let icon = target == .display ? "display" : target == .sound ? (session.audioAvailable && session.computer.audioEnabled ? "speaker.wave.2" : "speaker.slash") : "ellipsis"
        let title = target == .display ? "Display" : target == .sound ? "Sound" : "Session"
        return Button {
            if panel == nil { session.window?.makeFirstResponder(nil) }
            panel = panel == target ? nil : target
        } label: { toolbarIcon(icon) }
            .buttonStyle(.plain).modifier(ControlHover()).help(title).accessibilityLabel("\(title) controls")
    }
    private var sessionPanel: some View {
        GeometryReader { geometry in
            if let panel {
                ZStack(alignment:.topTrailing) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { self.panel = nil }.padding(.top,44)
                    ScrollView {
                        VStack(alignment:.leading,spacing:8) {
                            switch panel {
                            case .display: displayControls
                            case .sound: soundControls
                            case .session: sessionControls
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                            .onGeometryChange(for:CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    }.scrollBounceBehavior(.basedOnSize)
                        .frame(width:256,height:min(panelHeight,max(80,geometry.size.height-80)))
                        .padding(12).font(.portal(size:12)).toggleStyle(PortalToggle())
                        .background(Color.portalBackground,in:RoundedRectangle(cornerRadius:8))
                        .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.primary.opacity(0.12)))
                        .focusable().focusEffectDisabled().focused($panelFocused)
                        .onAppear { panelFocused = true }
                        .onExitCommand { self.panel = nil }
                        .environment(\.portalInsidePopover,true)
                        .environment(\.portalClosePopover,{ self.panel = nil })
                        .padding(.top,50).padding(.trailing,6)
                }
            }
        }
    }
    @ViewBuilder private var displayControls: some View {
        Text("Display").font(.portal(size:14,weight:.semibold))
        PortalChoice("Sizing",selection:$session.computer.sizing,options:DisplaySizing.choices)
        PortalChoice("Image quality",selection:$session.computer.quality,options:ImageQuality.choices)
        Divider()
        PortalAction("All displays",selected:session.selectedScreen == nil) { session.selectedScreen = nil }
        ForEach(Array(session.screens.enumerated()),id:\.element.id) { index, screen in
            PortalAction("Display \(index+1) · \(screen.width) × \(screen.height)",selected:session.selectedScreen == screen.id) { session.selectedScreen = screen.id }
        }
        PortalAction(fullscreen ? "Exit fullscreen" : "Enter fullscreen") { session.window?.toggleFullScreen(nil) }
    }
    @ViewBuilder private var soundControls: some View {
        Text("Sound").font(.portal(size:14,weight:.semibold))
        if session.audioAvailable {
            Toggle("Play remote audio",isOn:Binding(get:{ session.computer.audioEnabled },set:session.setAudio))
            PortalChoice("Volume",selection:Binding(get:{ session.computer.volume },set:{ session.computer.volume = $0; session.updatePreferences() }),options:[Float(0.25),0.5,0.75,1].map { ($0,"\(Int($0*100))%") })
            if !session.audioError.isEmpty { Text(session.audioError).foregroundStyle(.secondary) }
        } else {
            Text("Audio unavailable").font(.portal(size:12,weight:.medium))
            Text("This server does not provide compatible audio.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    @ViewBuilder private var sessionControls: some View {
        Text(session.status).font(.portal(size:14,weight:.semibold))
        Text(session.computer.address).font(.portalMono(size:11)).textSelection(.enabled)
        Text(session.encrypted ? "Encrypted connection" : "Unencrypted connection").foregroundStyle(.secondary)
        if let image = session.image { Text("\(image.width) × \(image.height)").foregroundStyle(.secondary) }
        Divider()
        Toggle("View only",isOn:$session.computer.viewOnly)
        PortalChoice("Clipboard",selection:$session.computer.clipboard,options:ClipboardMode.choices)
        if !session.clipboardError.isEmpty { Text(session.clipboardError).foregroundStyle(.secondary) }
        PortalPopover {
            HStack { Text("Send special keys"); Spacer(); Image(systemName:"chevron.right") }.padding(10)
        } content: {
            PortalAction("Control + Alt + Delete") { session.special([0xffe3,0xffe9,0xffff]) }
            PortalAction("Command / Windows key") { session.special([0xffeb]) }
            PortalAction("Escape") { session.special([0xff1b]) }
            PortalAction("Print Screen") { session.special([0xff61]) }
        }
        Text("Release keyboard: ⌃⌥Esc").font(.portal(size:11)).foregroundStyle(.secondary)
        Divider()
        PortalAction("Reconnect") { session.start() }
        PortalAction("Disconnect") { session.window?.close() }
    }
    private func toolbarIcon(_ name:String) -> some View { Image(systemName:name).resizable().scaledToFit().frame(width:20,height:20).frame(width:32,height:32).contentShape(Rectangle()).foregroundStyle(.secondary) }
    private var toolbar: some View {
        HStack(spacing:6) {
            Spacer().frame(width:76)
            Spacer()
            HStack(spacing:6) { if session.encrypted { Image(systemName:"lock.fill").font(.system(size:9)).foregroundStyle(.secondary) }; Text(session.computer.name).font(.portal(size:12,weight:.medium)).lineLimit(1) }
            Spacer()
            toolbarButton(.display)
            toolbarButton(.sound)
            toolbarButton(.session)
        }.buttonStyle(.plain).fixedSize(horizontal:false,vertical:true).padding(.trailing,6).frame(height:44).background(Color.portalBackground)
        .onHover { over in if fullscreen && hideToolbar && !over { DispatchQueue.main.asyncAfter(deadline:.now()+1) { revealControls = false } } }
        .onChange(of:session.computer.sizing) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.quality) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.clipboard) { _,_ in session.updatePreferences() }
        .onChange(of:session.computer.viewOnly) { _,_ in session.updatePreferences() }
    }
}
