import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The share-sheet entry for Kioku: shows the text or link another app shared, lets the user title
// it, and drops it in the App Group inbox for the app to turn into a note. Hosts SwiftUI
// (ShareComposeView) inside the extension's view controller.
final class ShareViewController: UIViewController {
    // Reads what was shared, then shows the compose sheet.
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let shared = await loadSharedContent()
            present(shared)
        }
    }

    // Pulls the first text or URL out of the extension's input items. Plain text wins over a URL,
    // since sharing a selection can include both the selection and its page.
    private func loadSharedContent() async -> SharedContent {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadString(from: provider), text.isEmpty == false {
                return SharedContent(text: text, url: nil)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURLString(from: provider) {
                return SharedContent(text: nil, url: url)
            }
        }
        return SharedContent(text: nil, url: nil)
    }

    // Awaits the text of an attachment; a failed load is logged and treated as "nothing here".
    private func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, error in
                if let error { NSLog("Kioku share: could not load shared text: \(error)") }
                continuation.resume(returning: (value as? NSString).map { $0 as String })
            }
        }
    }

    // Awaits the link of an attachment, with the same failure handling.
    private func loadURLString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { value, error in
                if let error { NSLog("Kioku share: could not load shared link: \(error)") }
                continuation.resume(returning: (value as? NSURL)?.absoluteString)
            }
        }
    }

    // Hosts the compose view full-screen inside this controller.
    private func present(_ shared: SharedContent) {
        let compose = ShareComposeView(
            shared: shared,
            onSave: { [weak self] item in self?.save(item) },
            onCancel: { [weak self] in self?.finish(error: nil) }
        )
        let host = UIHostingController(rootView: compose)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // Writes the item to the inbox; a failure ends the extension with an error rather than
    // pretending the content was kept.
    private func save(_ item: SharedInboxItem) {
        guard let directory = SharedInbox.defaultDirectory() else {
            finish(error: NSError(domain: "Kioku.ShareExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kioku's shared storage is unavailable."]))
            return
        }
        do {
            try SharedInbox.enqueue(item, in: directory)
            finish(error: nil)
        } catch {
            finish(error: error)
        }
    }

    // Closes the sheet, reporting failure to the host app when there was one.
    private func finish(error: Error?) {
        if let error {
            extensionContext?.cancelRequest(withError: error)
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
