import SwiftUI
import AppKit
import PortalCore

struct PortalToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing:12) {
                configuration.label
                Spacer(minLength:8)
                ZStack(alignment:configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.portalAccent : Color.primary.opacity(0.15))
                    Circle().fill(.white).padding(3).frame(width:20,height:20)
                }.frame(width:34,height:20)
            }.padding(.vertical,6).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(ControlHover()).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct PortalPopover<Label: View, Content: View>: View {
    @State private var presented = false
    @FocusState private var contentFocused: Bool
    var onPresentationChange: (Bool) -> Void = { _ in }
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content
    @Environment(\.portalInsidePopover) private var insidePopover
    var body: some View {
        if insidePopover {
            VStack(alignment:.leading,spacing:6) {
                trigger
                if presented { items.padding(4).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:7)) }
            }
        } else {
            trigger.popover(isPresented:$presented,arrowEdge:.bottom) {
                items.padding(12).frame(width:280).fixedSize(horizontal:false,vertical:true)
                    .background(Color.portalBackground)

            }
        }
    }
    private var trigger: some View {
        Button { presented.toggle() } label: { label() }
            .buttonStyle(.plain).modifier(ControlHover())
            .onChange(of:presented) { _,value in onPresentationChange(value) }
    }
    private var items: some View {
        VStack(alignment:.leading,spacing:8) { content() }
            .font(.portal(size:12)).toggleStyle(PortalToggle())
            .focusable().focusEffectDisabled().focused($contentFocused)
            .onAppear { contentFocused = true }
            .onExitCommand { presented = false }
            .environment(\.portalInsidePopover,true)
            .environment(\.portalClosePopover, { presented = false })
    }
}
private struct InsidePopoverKey: EnvironmentKey { static let defaultValue = false }

private struct ClosePopoverKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var portalInsidePopover: Bool {
        get { self[InsidePopoverKey.self] }
        set { self[InsidePopoverKey.self] = newValue }
    }
    var portalClosePopover: () -> Void {
        get { self[ClosePopoverKey.self] }
        set { self[ClosePopoverKey.self] = newValue }
    }
}
struct PortalAction: View {
    let title: String
    var selected = false
    var action: () -> Void
    @Environment(\.portalClosePopover) private var close
    init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.action = action
    }
    var body: some View {
        Button {
            close()
            // Let SwiftUI finish dismissing the menu before an action starts a modal loop.
            DispatchQueue.main.async(execute:action)
        } label: {
            HStack { Text(title); Spacer(); if selected { Image(systemName:"checkmark").foregroundStyle(Color.portalAccent) } }
                .padding(.horizontal,10).frame(minHeight:32).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(ControlHover()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct PortalChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value,String)]
    init(_ title: String, selection: Binding<Value>, options: [(Value,String)]) {
        self.title = title; _selection = selection; self.options = options
    }
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.portal(size:12,weight:.medium)).foregroundStyle(.secondary)
            PortalPopover {
                HStack { Text(options.first(where:{ $0.0 == selection })?.1 ?? ""); Spacer(); Image(systemName:"chevron.down").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary) }
                    .modifier(ConnectionFieldSurface()).accessibilityLabel(title).accessibilityValue(options.first(where:{ $0.0 == selection })?.1 ?? "")
            } content: {
                ForEach(options,id:\.0) { value, label in PortalAction(label,selected:selection == value) { selection = value } }
            }
        }
    }
}
extension DisplaySizing {
    static let choices: [(Self,String)] = [(.automatic,"Automatic resize, or fit"),(.fit,"Fit to window"),(.actual,"Actual size")]
}
extension ClipboardMode {
    static let choices: [(Self,String)] = [(.bidirectional,"Share both ways"),(.receive,"Receive only"),(.off,"Off")]
}
extension ImageQuality { static var choices: [(Self,String)] { allCases.map { ($0,$0.rawValue.capitalized) } } }

// One modal boundary serves VNC, SSH, and local confirmations; closing always cancels.
final class PortalDialog: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.stopModal(withCode:.cancel); return false }
    func run<Content: View>(_ title: String, message: String, accept: String = "OK", cancel: Bool = true, @ViewBuilder content: () -> Content) -> Bool {
        let window = NSPanel(contentRect:.zero,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel = window; window.delegate = self; window.title = title
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let fields = content()
        let host = NSHostingView(rootView:PortalAppearance {
            VStack(alignment:.leading,spacing:20) {
                Text(title).font(.portal(size:20,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                if !message.isEmpty { Text(message).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
                fields
                HStack {
                    Spacer()
                    if cancel { Button("Cancel") { NSApp.stopModal(withCode:.cancel) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction) }
                    Button(accept) { NSApp.stopModal(withCode:.OK) }.buttonStyle(SoftButton(primary:true)).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width:400).background(Color.portalBackground)
        })
        window.contentView = host; window.setContentSize(host.fittingSize)
        window.center(); window.makeKeyAndOrderFront(nil)
        let result = withExtendedLifetime(self) { NSApp.runModal(for:window) }
        window.orderOut(nil); window.close(); panel = nil
        return result == .OK
    }
    @discardableResult static func confirm(_ title:String,message:String,accept:String = "OK",cancel:Bool = true) -> Bool {
        let dialog = PortalDialog()
        return dialog.run(title,message:message,accept:accept,cancel:cancel) { EmptyView() }
    }
}
struct RenameField: View {
    @ObservedObject var input: CredentialInput
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Nickname",text:$input.username).textFieldStyle(.plain).modifier(ConnectionFieldSurface())
            .accessibilityLabel("Nickname").focused($focused).onAppear { focused = true }
    }
}

struct PortalProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval:1/30,paused:reduceMotion)) { context in
            Circle().trim(from:0,to:0.7).stroke(Color.portalAccent,style:StrokeStyle(lineWidth:3,lineCap:.round))
                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:1)*360))
                .frame(width:28,height:28)
        }.accessibilityLabel("Connecting")
    }
}
