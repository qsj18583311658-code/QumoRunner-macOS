import AppKit
import Foundation

@main
enum QumoRunnerAgentMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let delegate = RunnerAgentListenerDelegate()
        let listener = NSXPCListener(machServiceName: runnerAgentMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        withExtendedLifetime(delegate) {}
    }
}
