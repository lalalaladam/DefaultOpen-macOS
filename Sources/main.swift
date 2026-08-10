import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = DefaultOpenAppDelegate()
    application.delegate = delegate

    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
