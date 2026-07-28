import Foundation
import Testing
import AngelLiveCore
@testable import AngelLiveDependencies

private let runLiveMacastIntegration =
    ProcessInfo.processInfo.environment["DLNA_LIVE_INTEGRATION"] == "1"

@Suite("Live Macast integration", .serialized)
struct DLNALiveMacastTests {
    @Test(
        "discovers Macast and completes the AVTransport lifecycle",
        .enabled(if: runLiveMacastIntegration),
        .timeLimit(.minutes(1))
    )
    func castsPublicHLSAndStops() async throws {
        let service = DLNAService()
        let devices = try await service.discoverDevices(timeout: 3)
        let device = try #require(devices.first {
            $0.friendlyName.localizedCaseInsensitiveContains("Macast")
        })
        let streamURLString = ProcessInfo.processInfo.environment["DLNA_TEST_URL"]
            ?? "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        let streamURL = try #require(URL(string: streamURLString))
        let resource = DLNAMediaResource(
            url: streamURL,
            title: "AngelLive DLNA Integration Test",
            mimeType: "application/vnd.apple.mpegurl"
        )
        let transport = DLNAAVTransportClient()

        do {
            try await transport.setAVTransportURI(device: device, resource: resource)
            try await transport.play(device: device)
            let state = try await waitForPlaybackState(transport: transport, device: device)
            #expect(["PLAYING", "TRANSITIONING"].contains(state))
        } catch {
            try? await transport.stop(device: device)
            throw error
        }

        try await transport.stop(device: device)
        let stoppedState = try await transport.transportState(device: device)
        #expect(["STOPPED", "NO_MEDIA_PRESENT"].contains(stoppedState))
    }

    private func waitForPlaybackState(
        transport: DLNAAVTransportClient,
        device: DLNADevice
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var state = "UNKNOWN"

        repeat {
            state = try await transport.transportState(device: device)
            if ["PLAYING", "TRANSITIONING"].contains(state) {
                return state
            }
            try await clock.sleep(for: .milliseconds(250))
        } while clock.now < deadline

        return state
    }
}
