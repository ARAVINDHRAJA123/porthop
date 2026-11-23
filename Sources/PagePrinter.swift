import AppKit
import WebKit

/// Prints a web page (a saved chat) to a paginated PDF, off screen, with the page's text kept as real text.
final class PagePrinter: NSObject, WKNavigationDelegate {
    private static var running: [PagePrinter] = []
    private var web: WKWebView!
    private var window: NSWindow!
    private var output: URL!
    private var finish: ((Bool) -> Void)?

    @MainActor static func pdf(from page: URL, to output: URL, done: @escaping (Bool) -> Void) {
        let p = PagePrinter()
        running.append(p)
        p.finish = { ok in done(ok); running.removeAll { $0 === p } }
        p.output = output
        p.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 1000))
        p.window = NSWindow(contentRect: p.web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        p.window.contentView = p.web
        p.web.navigationDelegate = p
        p.web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for the pictures to lay out before printing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
            let op = web.printOperation(with: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.view?.frame = web.bounds
            op.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:context:)), contextInfo: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish?(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish?(false) }

    @objc private func printed(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        finish?(success && FileManager.default.fileExists(atPath: output.path))
    }
}
