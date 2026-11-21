// Decks Visuals for Mac: shows the visuals site full screen and feeds it the Mac's own sound
// (everything playing: YouTube, Spotify, rekordbox), captured with ScreenCaptureKit. No browser, no sharing bars.
import Cocoa
import WebKit
import ScreenCaptureKit
import CoreMedia
import AVFoundation

let siteURL = URL(string: "https://jondik14.github.io/visuals-/")!
let siteHost = "jondik14.github.io"

// MARK: - System audio capture

final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var web: WKWebView?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "decks.audio")
    private let videoQueue = DispatchQueue(label: "decks.video")
    private var pending = [Float]()

    static let permissionHelp = "macOS hasn't allowed Decks Visuals to hear this Mac yet. Open System Settings → Privacy & Security → Screen & System Audio Recording, turn on Decks Visuals, then quit and reopen the app."

    func start(_ done: @escaping (String?) -> Void) {
        if stream != nil { done(nil); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content = content, let display = content.displays.first else {
                done(SystemAudio.permissionHelp); return
            }
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            // ScreenCaptureKit always captures video too; keep it tiny and slow, it is thrown away.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 3
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
            } catch {
                done("Couldn't start listening: \(error.localizedDescription)"); return
            }
            s.startCapture { err in
                if let err = err {
                    done("Couldn't start listening: \(err.localizedDescription). " + SystemAudio.permissionHelp)
                } else {
                    self.stream = s
                    done(nil)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        let msg = "Stopped listening to this Mac (\(error.localizedDescription)). Click 'This computer's sound' to start again."
        DispatchQueue.main.async { App.shared?.callPage("__decksNativeError", msg) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let asbd = sb.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        var mono = [Float](repeating: 0, count: n)
        try? sb.withAudioBufferList { abl, _ in
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                let ch = Float(max(1, abl.count))
                for buf in abl {
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let frames = min(n, Int(buf.mDataByteSize) / 4)
                    for i in 0..<frames { mono[i] += p[i] / ch }
                }
            } else if let first = abl.first, let p = first.mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(asbd.mChannelsPerFrame))
                let frames = min(n, Int(first.mDataByteSize) / 4 / ch)
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<ch { s += p[i * ch + c] }
                    mono[i] = s / Float(ch)
                }
            }
        }
        pending += mono
        if pending.count < 1024 { return }
        let data = pending.withUnsafeBufferPointer { Data(buffer: $0) }
        pending.removeAll(keepingCapacity: true)
        let js = "window.__decksPCM&&__decksPCM('\(data.base64EncodedString())')"
        DispatchQueue.main.async { [weak self] in self?.web?.evaluateJavaScript(js, completionHandler: nil) }
    }
}

// MARK: - App window

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    static weak var shared: App?
    var window: NSWindow!
    var web: WKWebView!
    let audio = SystemAudio()
    var triedOffline = false

    func applicationDidFinishLaunching(_ note: Notification) {
        App.shared = self
        let cfg = WKWebViewConfiguration()
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let uc = WKUserContentController()
        uc.add(self, name: "decks")
        // Copy feedback goes to the Mac clipboard.
        uc.addUserScript(WKUserScript(source: """
            (()=>{const w=t=>{window.webkit.messageHandlers.decks.postMessage({cmd:'copy',text:String(t)});return Promise.resolve()};
            try{if(navigator.clipboard)navigator.clipboard.writeText=w;else Object.defineProperty(navigator,'clipboard',{value:{writeText:w}})}catch(e){}})();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = uc

        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        audio.web = web

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Decks Visuals"
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = web
        window.setFrameAutosaveName("DecksVisualsWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: siteURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func callPage(_ fn: String, _ arg: String) {
        let data = try? JSONSerialization.data(withJSONObject: [arg])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        web.evaluateJavaScript("window.\(fn)&&\(fn)(...\(json))", completionHandler: nil)
    }

    // Messages from the page
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "startAudio":
            audio.start { err in
                DispatchQueue.main.async {
                    if let err = err { self.callPage("__decksNativeError", err) }
                    else { self.web.evaluateJavaScript("window.__decksNativeReady&&__decksNativeReady()", completionHandler: nil) }
                }
            }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
        case "fullscreen":
            window.toggleFullScreen(nil)
        default: break
        }
    }

    // Microphone for the page (the "Microphone" option), only for the visuals site.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == siteHost ? .grant : .prompt)
    }

    // File pickers (drawings, clips, audio files, imports)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }

    // Exported looks download to ~/Downloads
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var url = dir.appendingPathComponent(suggestedFilename)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
            url = dir.appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)")); i += 1
        }
        completionHandler(url)
    }

    // No internet: use the copy of the visuals built into the app.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadOffline() }
    func loadOffline() {
        guard !triedOffline, let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "site") else { return }
        triedOffline = true
        web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
    }

    @objc func reloadPage(_ sender: Any?) { triedOffline = false; web.load(URLRequest(url: siteURL, cachePolicy: .reloadIgnoringLocalCacheData)) }
}

// MARK: - Menus and launch

func makeMenu() -> NSMenu {
    let main = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) {
        let top = NSMenuItem(); let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }; top.submenu = m; main.addItem(top)
    }
    add("Decks Visuals", [
        NSMenuItem(title: "Hide Decks Visuals", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
        .separator(),
        NSMenuItem(title: "Quit Decks Visuals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
    ])
    add("Edit", [
        NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
        NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
        NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
    ])
    let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fs.keyEquivalentModifierMask = [.command, .control]
    add("View", [NSMenuItem(title: "Reload", action: #selector(App.reloadPage(_:)), keyEquivalent: "r"), fs])
    return main
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = makeMenu()
app.run()
