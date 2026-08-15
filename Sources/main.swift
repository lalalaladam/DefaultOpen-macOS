import AppKit
import Darwin

if FreshAssociationProbe.runIfRequested() {
    exit(EXIT_SUCCESS)
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = DefaultOpenAppDelegate()
        application.delegate = delegate

        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
