import SwiftUI
import AppKit

/// SwiftUI owns the draft. This bridge only intercepts native window closing
/// and forwards unrelated window delegate behavior to SwiftUI's own delegate.
struct WorkspaceWindowGuard: NSViewRepresentable {
    @ObservedObject var store: WorkspaceStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: HostView, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) { coordinator.detach() }

    final class HostView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let store: WorkspaceStore
        weak var window: NSWindow?
        weak var previous: NSWindowDelegate?
        init(store: WorkspaceStore) { self.store = store }
        @MainActor func attach(_ newWindow: NSWindow?) {
            guard let newWindow else { return }
            if window !== newWindow { detach(); window = newWindow }
            if newWindow.delegate !== self { previous = newWindow.delegate; newWindow.delegate = self }
            newWindow.isDocumentEdited = store.hasPendingEdits
        }
        @MainActor func detach() {
            if window?.delegate === self { window?.delegate = previous }
            window = nil; previous = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if store.busy { store.status = L10n.text("Bitte den laufenden Vorgang abschließen oder abbrechen."); return false }
            if store.deferNavigation(.close(sender.windowNumber)) { return false }
            return previous?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
    }
}
