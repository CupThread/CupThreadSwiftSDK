import SwiftUI

@main
struct CupThreadDemoApp: App {
    // Created exactly once per process, outside any View struct: SwiftUI
    // re-creates View values on every parent re-evaluation, and a re-created
    // client would reset the shared search throttle/cooldown and the short-TTL
    // config cache (see DemoAppModel).
    @State private var model = DemoAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .overlay(alignment: .bottomTrailing) {
                    // Request-economy probe for the UI tests: the number of
                    // `GET /api/v1/public/config/{appKey}` requests the mock
                    // protocol has served this launch. Only mounted under the
                    // dedicated launch argument so screenshot captures stay clean.
                    if ProcessInfo.processInfo.arguments.contains("-configRequestProbe") {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text("\(DemoMockURLProtocol.configRequestCount)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .accessibilityIdentifier("cupthread.demo.config_request_count")
                        }
                    }
                }
        }
    }
}
