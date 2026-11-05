import AppKit
import Foundation

final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var titleLabel: NSTextField!
    var detailLabel: NSTextField!
    var progress: NSProgressIndicator!
    var done: NSButton!
    var process: Process?
    var captured = ""
    var isStop = false
    var logURL: URL!
    var logHandle: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        isStop = Bundle.main.bundleIdentifier?.hasSuffix(".stop") ?? false
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Project-NOMAD")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".microsandbox-nomad")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        logURL = home.appendingPathComponent(isStop ? "gui-stop.log" : "gui-start.log")
        if !FileManager.default.fileExists(atPath:logURL.path) {FileManager.default.createFile(atPath:logURL.path,contents:nil)}
        logHandle = try? FileHandle(forWritingTo:logURL)
        _ = try? logHandle?.seekToEnd()
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:560,height:250), styleMask:[.titled,.closable,.miniaturizable], backing:.buffered, defer:false)
        window.title = isStop ? "Stop NOMAD" : "NOMAD"
        window.delegate = self
        window.center()
        let view = window.contentView!
        let picture = NSImageView(frame:NSRect(x:26,y:143,width:76,height:76))
        picture.image = NSImage(contentsOf:root.appendingPathComponent(isStop ? "assets/stop-nomad.png" : "assets/nomad.png"))
        view.addSubview(picture)
        titleLabel = NSTextField(labelWithString:isStop ? "Stopping NOMAD" : "Starting NOMAD")
        titleLabel.font = .systemFont(ofSize:24,weight:.semibold)
        titleLabel.frame = NSRect(x:120,y:180,width:410,height:32)
        view.addSubview(titleLabel)
        detailLabel = NSTextField(wrappingLabelWithString:isStop ? "Finishing writes to your portable workspace." : "Preparing your offline workspace. First use can take a few minutes.")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x:120,y:130,width:400,height:45)
        view.addSubview(detailLabel)
        progress = NSProgressIndicator(frame:NSRect(x:28,y:91,width:504,height:16))
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        view.addSubview(progress)
        let logs = NSButton(title:"View startup log",target:self,action:#selector(openLog))
        logs.frame = NSRect(x:24,y:27,width:160,height:32);view.addSubview(logs)
        done = NSButton(title:"Done",target:self,action:#selector(closeApp))
        done.frame = NSRect(x:438,y:27,width:96,height:32);done.bezelStyle = .rounded;done.isEnabled = false;view.addSubview(done)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let job = Process(); process = job
        job.executableURL = root.appendingPathComponent("bin/darwin-arm64/nomad")
        job.arguments = [isStop ? "stop" : "start"]
        let pipe = Pipe();job.standardOutput = pipe;job.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let string = String(data:data,encoding:.utf8) else { return }
            DispatchQueue.main.async { self?.record(string) }
        }
        job.terminationHandler = { [weak self] finished in DispatchQueue.main.async { self?.finished(finished.terminationStatus) } }
        do {try job.run()} catch {record("Could not start launcher: \(error.localizedDescription)\n");finished(1)}
    }
    func record(_ text:String) {
        captured += text
        if let data = text.data(using:.utf8) {try? logHandle?.write(contentsOf:data)}
        if text.contains("Checking portable") {detailLabel.stringValue = "Checking workspace files…"}
        if text.contains("Preparing Ubuntu") {detailLabel.stringValue = "Preparing the Ubuntu runtime…"}
        if text.contains("Checking Ubuntu") {detailLabel.stringValue = "Checking the runtime…"}
        if text.contains("Starting NOMAD") {detailLabel.stringValue = "Starting your offline workspace…"}
    }
    func finished(_ status:Int32) {
        progress.stopAnimation(nil);progress.isIndeterminate = false;progress.doubleValue = status == 0 ? 100 : 0
        done.isEnabled = true
        if status == 0 {
            let pending = captured.contains("NOMAD is already starting")
            titleLabel.stringValue = isStop ? "NOMAD stopped" : (pending ? "NOMAD is starting" : "NOMAD ready")
            detailLabel.stringValue = isStop ? "Your workspace is stopped. External storage can now be disconnected." : (pending ? "The existing startup will open your dashboard when ready." : "Your dashboard is opening in the browser.")
            if !isStop {DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {NSApp.terminate(nil)}}
        } else {
            titleLabel.stringValue = "NOMAD needs attention"
            detailLabel.stringValue = "Startup did not finish. View the startup log for the failed step. Your existing files are retained."
        }
    }
    @objc func openLog() {NSWorkspace.shared.open(logURL)}
    @objc func closeApp() {NSApp.terminate(nil)}
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if process?.isRunning == true {window.miniaturize(nil);return false}
        NSApp.terminate(nil);return true
    }
}
let app = NSApplication.shared
let delegate = Launcher()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
