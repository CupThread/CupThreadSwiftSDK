import SwiftUI

@main
struct CupThreadDemoApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") ||
            ProcessInfo.processInfo.arguments.contains("-mockData") ||
            ProcessInfo.processInfo.environment["CUPTHREAD_USE_MOCKS"] == "1" ||
            ProcessInfo.processInfo.environment["CUPTHREAD_BASE_URL"] == nil {
            URLProtocol.registerClass(DemoMockURLProtocol.self)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
