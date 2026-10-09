import AppKit

/// The share sheet's view controller. It records that something was shared in
/// the App Group, where the app can pick it up, and closes.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        UserDefaults(suiteName: "group.com.example.flutterapp")?
            .set("shared", forKey: "note")
        extensionContext?.completeRequest(returningItems: nil)
    }
}
