import AppKit
import SwiftUI

/// AppKit owns page snapshots, interactive tracking, and completion/cancellation.
/// SwiftUI owns the selected album and the content of each page.
struct AlbumPageNavigation<Root: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var album: Album?
    @ViewBuilder var root: () -> Root
    @ViewBuilder var detail: (Album) -> Detail
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeNSViewController(context: Context) -> NSPageController {
        let controller = NSPageController()
        controller.transitionStyle = .stackHistory
        controller.delegate = context.coordinator
        controller.arrangedObjects = [Page.library]
        controller.selectedIndex = 0
        return controller
    }

    func updateNSViewController(_ controller: NSPageController, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.update(controller)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSPageController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSViewController(_ controller: NSPageController, coordinator: Coordinator) {
        controller.delegate = nil
        coordinator.isAttached = false
    }

    enum Page {
        case library
        case album(Album)

        var album: Album? {
            if case let .album(album) = self { return album }
            return nil
        }
    }

    final class Coordinator: NSObject, NSPageControllerDelegate {
        var configuration: AlbumPageNavigation
        var isAttached = true
        private var requestedAlbum: Album?
        private var isTransitioning = false
        private var hosts: [String: NSHostingController<AnyView>] = [:]

        init(configuration: AlbumPageNavigation) {
            self.configuration = configuration
        }

        func update(_ controller: NSPageController) {
            guard !isTransitioning else { return }
            // Keep the existing root host alive so search and scroll position survive.
            for object in controller.arrangedObjects {
                guard let page = object as? Page,
                      let host = hosts[identifier(for: page)] else { continue }
                host.rootView = content(for: page)
            }
            guard configuration.album != requestedAlbum else { return }
            requestedAlbum = configuration.album
            if let album = configuration.album {
                // Returning to the wall then opening an album replaces forward history.
                controller.arrangedObjects = [Page.library, Page.album(album)]
                isTransitioning = true
                if configuration.environment.accessibilityReduceMotion {
                    controller.selectedIndex = 1
                    finish(controller)
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.32
                        controller.animator().selectedIndex = 1
                    } completionHandler: { [weak self, weak controller] in
                        MainActor.assumeIsolated {
                            guard let self, let controller, self.isAttached else { return }
                            self.finish(controller)
                        }
                    }
                }
            } else if controller.selectedIndex > 0 {
                if configuration.environment.accessibilityReduceMotion {
                    controller.selectedIndex = 0
                    finish(controller)
                } else {
                    controller.navigateBack(nil)
                }
            }
        }

        private func identifier(for page: Page) -> String {
            page.album.map { "album:\($0.id)" } ?? "library"
        }

        private func content(for page: Page) -> AnyView {
            switch page {
            case .library:
                AnyView(configuration.root().environment(\.self, configuration.environment))
            case let .album(album):
                AnyView(configuration.detail(album).environment(\.self, configuration.environment))
            }
        }

        func pageController(_ pageController: NSPageController, identifierFor object: Any) -> String {
            identifier(for: object as! Page)
        }

        func pageController(_ pageController: NSPageController, viewControllerForIdentifier identifier: String) -> NSViewController {
            if let host = hosts[identifier] { return host }
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            host.sizingOptions = []
            host.view.autoresizingMask = [.width, .height]
            hosts[identifier] = host
            return host
        }

        func pageController(_ pageController: NSPageController, frameFor object: Any?) -> NSRect {
            pageController.view.bounds
        }

        func pageController(_ pageController: NSPageController, prepare viewController: NSViewController, with object: Any?) {
            guard let page = object as? Page,
                  let host = viewController as? NSHostingController<AnyView> else { return }
            host.rootView = content(for: page)
            host.view.frame = pageController.view.bounds
            host.view.layoutSubtreeIfNeeded()
        }

        func pageControllerWillStartLiveTransition(_ pageController: NSPageController) {
            isTransitioning = true
        }

        func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
            finish(pageController)
        }

        private func finish(_ controller: NSPageController) {
            controller.completeTransition()
            isTransitioning = false
            // A toolbar action may arrive while the previous animation is running.
            if configuration.album != requestedAlbum {
                update(controller)
                return
            }
            let selected = (controller.arrangedObjects[controller.selectedIndex] as? Page)?.album
            requestedAlbum = selected
            // Keep only the root and current/forward page, not every album ever opened.
            let identifiers = Set(controller.arrangedObjects.compactMap { ($0 as? Page).map(identifier(for:)) })
            hosts = hosts.filter { identifiers.contains($0.key) }
            // Delegate callbacks can run during updateNSViewController.
            let previousSelection = configuration.album
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isAttached, !self.isTransitioning,
                      self.requestedAlbum == selected,
                      self.configuration.album == previousSelection else { return }
                self.configuration.album = selected
            }
        }
    }
}
