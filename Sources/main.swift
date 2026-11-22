import AppKit
import ScreenCaptureKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate {
    enum State { case idle, selecting, preparing, recording, saving }
    private var state: State = .idle
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let selector = RegionSelector()
    private var stream: SCStream?
    private var sink: MovieSink?
    private var destination: URL?
    private var lastFile: URL?
    private var region = false
    private var started = Date()
    private var blink = true
    private var timer: Timer?
    private var quitAfterSave = false
    private var frameReceived = false
    private var summary = "Gotowy · wybierz obraz i dźwięk"
    private var previewWindow: NSWindow?
    private var testReport: URL?
    private var smoke = false
    private var audioSource = AudioSource(rawValue: UserDefaults.standard.string(forKey: "audioSource") ?? "none") ?? .none
    private var microphone: MicrophoneCapture?
    private var testSeconds = 3.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "pl.krzyhoo.screenrecorder").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("Screen Recorder by Krzyhoo")
        refresh()
        timer = Timer(timeInterval: 0.5, repeats: true) { [self] _ in
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let args = CommandLine.arguments
        if args.contains("--preview") { makePreview() }
        if let i = args.firstIndex(of: "--report"), i + 1 < args.count { testReport = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let seconds = Double(args[i + 1]) { testSeconds = max(1, min(60, seconds)) }
        if let i = args.firstIndex(of: "--audio"), i + 1 < args.count { audioSource = AudioSource(rawValue: args[i+1]) ?? .none }
        if args.contains("--smoke-full") || args.contains("--smoke-region") {
            smoke = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let screen = NSScreen.screens.first else { return }
                let rect = args.contains("--smoke-region") ? CGRect(x: 100, y: 140, width: 480, height: 320) : nil
                self.start(screen: screen, rect: rect)
            }
        }
    }

    // Development-only window exposes the exact menu actions for visual UI verification.
    private func makePreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Screen Recorder by Krzyhoo — podgląd menu"
        window.isReleasedWhenClosed = false
        previewWindow = window
        updatePreview()
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func updatePreview() {
        guard let window = previewWindow else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if item.action == #selector(changeAudio(_:)) {
                let button = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(previewAudio(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(item.representedObject as! String)
                button.state = item.state; button.isEnabled = item.isEnabled; stack.addArrangedSubview(button)
            } else if item.action != nil {
                let button = NSButton(title: item.title, target: self, action: item.action)
                button.isEnabled = item.isEnabled; button.bezelStyle = .rounded; stack.addArrangedSubview(button)
            } else { stack.addArrangedSubview(NSTextField(labelWithString: item.title)) }
        }
        let view = NSView(); view.addSubview(stack); window.contentView = view
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)])
    }
    @objc private func previewAudio(_ button: NSButton) {
        let item = NSMenuItem(); item.representedObject = button.identifier?.rawValue
        changeAudio(item)
    }

    private func tick() {
        if state == .recording { blink.toggle() }
        else { blink = true }
        updateIcon()
        if state == .recording { menu.item(at: 1)?.title = recordingText() }
    }
    private func recordingText() -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(started)))
        return "\(region ? "Fragment" : "Cały ekran") · \(String(format: "%02d:%02d", seconds / 60, seconds % 60))"
    }
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = state == .recording || state == .saving
        let color: NSColor = active ? (region ? .systemBlue : .systemRed) : .systemGreen
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            color.withAlphaComponent(self.blink || !active ? 1 : 0.25).setFill()
            NSBezierPath(roundedRect: CGRect(x: 1, y: 3, width: 14, height: 12), xRadius: 2, yRadius: 2).fill()
            let lens = NSBezierPath(); lens.move(to: NSPoint(x: 16, y: 6)); lens.line(to: NSPoint(x: 21, y: 3))
            lens.line(to: NSPoint(x: 21, y: 15)); lens.line(to: NSPoint(x: 16, y: 12)); lens.close(); lens.fill()
            return true
        }
        image.isTemplate = false; button.image = image
        button.title = active ? (state == .saving ? " …" : " " + recordingText().components(separatedBy: " · ").last!) : ""
        button.toolTip = "Screen Recorder by Krzyhoo — \(summary)"
    }
    private func add(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled
        menu.addItem(item)
    }
    private func refresh() {
        menu.removeAllItems(); menu.autoenablesItems = false
        add("Screen Recorder by Krzyhoo", enabled: false)
        add(state == .recording ? recordingText() : summary, enabled: false)
        menu.addItem(.separator())
        for source in AudioSource.allCases {
            let item = NSMenuItem(title: source.title, action: #selector(changeAudio(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = source.rawValue
            item.state = audioSource == source ? .on : .off; item.isEnabled = state == .idle
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Nagraj cały ekran", action: #selector(full), key: "f", enabled: state == .idle)
        add("Nagraj zaznaczony fragment…", action: #selector(selectRegion), key: "r", enabled: state == .idle)
        add("Zatrzymaj i zapisz", action: #selector(stopAction), key: "s", enabled: state == .recording)
        add("Anuluj wybór", action: #selector(cancelSelection), enabled: state == .selecting)
        menu.addItem(.separator())
        add("Pokaż ostatni film", action: #selector(reveal), enabled: lastFile != nil)
        add("Otwórz Pobrane", action: #selector(openDownloads))
        add("Dostęp do nagrywania ekranu…", action: #selector(permissions))
        add("Informacje i obsługa…", action: #selector(about))
        menu.addItem(.separator())
        add(state == .recording ? "Zapisz i zakończ aplikację" : "Zakończ aplikację", action: #selector(quit), key: "q", enabled: state != .saving)
        updateIcon(); updatePreview()
    }
    @objc private func changeAudio(_ item: NSMenuItem) {
        guard state == .idle, let raw = item.representedObject as? String, let source = AudioSource(rawValue: raw) else { return }
        audioSource = source; UserDefaults.standard.set(raw, forKey: "audioSource")
        summary = "Gotowy · " + source.title; refresh()
    }
    @objc private func full() { guard let screen = NSScreen.screens.first, state == .idle else { return }; start(screen: screen, rect: nil) }
    @objc private func selectRegion() {
        guard state == .idle else { return }
        state = .selecting; summary = "Wybierz fragment · Escape anuluje"; refresh()
        // Wait for status menu to close before showing the overlay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.state == .selecting else { return }
            self.selector.begin { screen, rect in
                self.state = .idle
                if let rect {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.start(screen: screen, rect: rect) }
                } else { self.summary = "Anulowano wybór · gotowy"; self.refresh() }
            }
        }
    }
    @objc private func cancelSelection() { selector.cancel() }
    private var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    private func start(screen: NSScreen, rect: CGRect?) {
        guard state == .idle else { return }
        state = .preparing; summary = "Przygotowanie nagrywania…"; region = rect != nil; refresh()
        Task {
            var createdSink: MovieSink?
            do {
                // Only requested after the user's recording action. No permission requests on launch,
                // no subprocess with a different TCC identity, no resetting system permissions.
                if audioSource == .microphone { try await MicrophoneCapture.requestPermission() }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if quitAfterSave { NSApp.terminate(nil); return }
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else {
                    throw RecorderFailure(message: "Wybrany monitor nie jest dostępny. Spróbuj ponownie.")
                }
                let selection = rect ?? CGRect(origin: .zero, size: screen.frame.size)
                let source = CaptureGeometry.sourceRect(selection: selection, screenSize: screen.frame.size)
                let (width, height) = CaptureGeometry.outputSize(rect: source, scale: screen.backingScaleFactor)
                let config = SCStreamConfiguration()
                config.sourceRect = source; config.width = width; config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 5; config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true; config.capturesAudio = audioSource == .system
                config.colorSpaceName = CGColorSpace.sRGB
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"; stamp.locale = Locale(identifier: "en_US_POSIX")
                let name = "Screen Recorder \(region ? "fragment" : "ekran") \(stamp.string(from: Date())) \(UUID().uuidString.prefix(8))"
                let final = downloads.appendingPathComponent(name + ".mp4")
                let temporary = downloads.appendingPathComponent("." + name + ".recording.mp4")
                let output = try MovieSink(url: temporary, width: width, height: height, audioSource: audioSource)
                createdSink = output; sink = output; destination = final; frameReceived = false
                output.onFirstFrame = { [weak self] in
                    DispatchQueue.main.async { self?.frameReceived = true }
                }
                output.onFailure = { [weak self] error in
                    DispatchQueue.main.async { self?.recordingFailed(error) }
                }
                let capture = SCStream(filter: filter, configuration: config, delegate: self)
                try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                if audioSource == .system { try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
                if audioSource == .microphone {
                    let mic = try MicrophoneCapture(sink: output)
                    microphone = mic; await mic.start()
                }
                stream = capture
                try await capture.startCapture()
                state = .recording; started = Date(); summary = "Nagrywanie · kliknij Zatrzymaj i zapisz"; refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak output] in
                    guard let self, self.sink === output, self.state == .recording, !self.frameReceived else { return }
                    self.recordingFailed(RecorderFailure(message: "Przez 8 sekund nie odebrano obrazu. Sprawdź zgodę na nagrywanie ekranu."))
                }
                if smoke {
                    DispatchQueue.main.asyncAfter(deadline: .now() + testSeconds) { [weak self] in self?.stopAction() }
                }
                if quitAfterSave { stopAction() }
            } catch {
                if let capture = stream { try? await capture.stopCapture() }
                await microphone?.stop(); microphone = nil
                await createdSink?.cancel()
                stream = nil; sink = nil; destination = nil; state = .idle
                summary = "Nie rozpoczęto nagrywania"; refresh()
                report("FAIL start: \(error.localizedDescription)")
                showError("Nie można rozpocząć nagrywania", error: error, permissionHelp: true)
                if smoke || quitAfterSave { NSApp.terminate(nil) }
            }
        }
    }
    @objc private func stopAction() { finish(error: nil) }
    private func recordingFailed(_ error: Error) { if state == .recording { finish(error: error) } }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.recordingFailed(error) }
    }
    private func finish(error captureError: Error?) {
        guard state == .recording, let capture = stream, let output = sink, let final = destination else { return }
        state = .saving; summary = "Kończenie i sprawdzanie filmu…"; refresh()
        Task {
            var stopError: Error?
            do { try await capture.stopCapture() } catch { stopError = error }
            await microphone?.stop(); microphone = nil
            do {
                let frames = try await output.finish()
                let result = try await validateMovie(output.temporaryURL, expectsAudio: audioSource != .none)
                try FileManager.default.moveItem(at: output.temporaryURL, to: final)
                lastFile = final
                summary = "Zapisano w Pobranych · \(String(format: "%.1f", result.1)) s"
                report("PASS \(region ? "region" : "full"): \(final.path) | \(Int(result.0.width))x\(Int(result.0.height)) | \(String(format: "%.3f", result.1))s | \(frames) frames | audio=\(audioSource.rawValue), audioSamples=\(output.audioSamples) | decoded beginning/end")
                if let error = captureError ?? stopError {
                    showError("Nagrywanie zostało przerwane — odebrany obraz zapisano", error: error)
                }
            } catch {
                try? FileManager.default.removeItem(at: output.temporaryURL)
                summary = "Nie zapisano filmu · sprawdź błąd"
                report("FAIL finish: \(error.localizedDescription)")
                showError("Nie udało się zapisać filmu", error: error)
            }
            stream = nil; sink = nil; destination = nil; state = .idle; refresh()
            if smoke || quitAfterSave { NSApp.terminate(nil) }
        }
    }
    private func report(_ line: String) {
        print(line)
        if let testReport { try? (line + "\n").write(to: testReport, atomically: true, encoding: .utf8) }
    }
    private func showError(_ title: String, error: Error, permissionHelp: Bool = false) {
        if smoke { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title
        alert.informativeText = error.localizedDescription + (permissionHelp ? "\n\nW Ustawieniach systemowych → Prywatność i ochrona → Nagrywanie ekranu włącz Screen Recorder by Krzyhoo. Po zmianie zgody zakończ i ponownie uruchom kopię z Aplikacji. Sprawdź też dostęp do Pobranych oraz wolne miejsce." : "")
        alert.addButton(withTitle: "OK")
        if permissionHelp { alert.addButton(withTitle: "Otwórz ustawienia") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { permissions() }
    }
    @objc private func reveal() { if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) } }
    @objc private func openDownloads() { NSWorkspace.shared.open(downloads) }
    @objc private func permissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "Screen Recorder by Krzyhoo · 1.0.1"
        alert.informativeText = "Zielona kamera: gotowy. Czerwona migająca: cały ekran. Niebieska migająca: fragment.\n\nCały ekran nagrywa główny monitor. Fragment wybierzesz przeciągnięciem na jednym z monitorów; Escape anuluje. Aby zakończyć, kliknij kamerę → Zatrzymaj i zapisz. MP4 z kursorem trafia do Pobranych. Przed startem wybierz dźwięk z komputera, sam mikrofon albo bez dźwięku. Dźwięk trafia do tego samego filmu. Nie mieszamy mikrofonu z dźwiękiem systemowym.\n\nPrywatna aplikacja, dane pozostają na Macu. macOS 13 lub nowszy. Podpis lokalny ad hoc, bez notaryzacji."
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state == .recording { quitAfterSave = true; stopAction(); return .terminateCancel }
        if state == .preparing || state == .saving { quitAfterSave = true; return .terminateCancel }
        if state == .selecting { selector.cancel() }
        return .terminateNow
    }
}

@main
struct ScreenRecorderApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
