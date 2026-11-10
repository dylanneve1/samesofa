import Foundation
import XCTest
@testable import SameSofaCore

final class AudioRoutingTests: XCTestCase {
    func testOutputKinds() {
        func kind(_ name: String, _ transport: OutputRoute.Transport, source: String? = nil, input: Bool = false) -> OutputKind {
            OutputRoute(name: name, transport: transport, dataSource: source, hasInput: input).kind
        }
        XCTAssertEqual(kind("MacBook Pro Speakers", .builtIn, source: "ispk"), .speakers)
        XCTAssertEqual(kind("External Headphones", .builtIn, source: "hdpn"), .headphones)
        XCTAssertEqual(kind("Built-in Output", .builtIn, source: "hdpn"), .headphones)
        XCTAssertEqual(kind("Anna's AirPods Pro", .bluetooth, input: true), .headphones)
        XCTAssertEqual(kind("WH-1000XM5", .bluetooth), .headphones)
        XCTAssertEqual(kind("Kitchen Speaker", .bluetooth), .speakers)
        XCTAssertEqual(kind("USB Headset", .usb, input: true), .headphones)
        XCTAssertEqual(kind("Gaming Dongle", .usb, input: true), .headphones)
        XCTAssertEqual(kind("Studio Display Speakers", .usb), .speakers)
        XCTAssertEqual(kind("USB DAC", .usb), .speakers)
        XCTAssertEqual(kind("LG TV", .hdmi), .speakers)
        XCTAssertEqual(kind("Living Room", .airPlay), .speakers)
    }

    func testEchoSetting() {
        let speakers = OutputRoute(name: "MacBook Pro Speakers", transport: .builtIn, dataSource: "ispk")
        let headphones = OutputRoute(name: "AirPods", transport: .bluetooth)
        XCTAssertTrue(EchoSetting.automatic.cancelsFilmEcho(on: speakers))
        XCTAssertFalse(EchoSetting.automatic.cancelsFilmEcho(on: headphones))
        XCTAssertTrue(EchoSetting.speakers.cancelsFilmEcho(on: headphones), "manual override")
        XCTAssertFalse(EchoSetting.headphones.cancelsFilmEcho(on: speakers), "manual override")
    }

    func testStereoFoldDown() {
        // AAC 5.1 arrives as C L R Ls Rs LFE.
        let gains = Downmix.stereoGains(for: [.centre, .left, .right, .leftSurround, .rightSurround, .lfe])
        XCTAssertEqual(gains[0], StereoGain(left: 0.70710678, right: 0.70710678), "dialogue equally in both")
        XCTAssertEqual(gains[1], StereoGain(left: 1, right: 0))
        XCTAssertEqual(gains[2], StereoGain(left: 0, right: 1))
        XCTAssertEqual(gains[3], StereoGain(left: 0.70710678, right: 0))
        XCTAssertEqual(gains[4], StereoGain(left: 0, right: 0.70710678))
        XCTAssertEqual(gains[5], StereoGain(left: 0, right: 0))
        XCTAssertEqual(Downmix.stereoGains(for: Downmix.assumedRoles(channelCount: 1)), [StereoGain(left: 0.70710678, right: 0.70710678)])
        XCTAssertEqual(Downmix.assumedRoles(channelCount: 6).count, 6)
    }

    func testReferenceCursorFollowsWithoutJumping() {
        var cursor = ReferenceCursor(sampleRate: 48_000)
        // First block: starts where it should.
        var read = cursor.next(desired: 1000, step: 1, frames: 480)
        XCTAssertEqual(read.start, 1000)
        XCTAssertEqual(read.step, 1)
        // The timeline runs 100 ppm fast: the cursor reads contiguously and bends its speed a little.
        var desired = 1000.0, previousEnd = 1480.0
        for _ in 0..<2000 {
            desired += 480 * 1.0001
            read = cursor.next(desired: desired, step: 1, frames: 480)
            XCTAssertEqual(read.start, previousEnd, accuracy: 1e-6, "no gap, no overlap")
            XCTAssertLessThanOrEqual(abs(read.step - 1), 0.0031)
            previousEnd = read.start + read.step * 480
        }
        XCTAssertLessThan(abs(previousEnd - (desired + 480)), 48, "stays within a millisecond of the timeline")
        // A seek: jump.
        read = cursor.next(desired: 5_000_000, step: 1, frames: 480)
        XCTAssertEqual(read.start, 5_000_000)
        cursor.reset()
        XCTAssertNil(cursor.position)
    }

    func testFrameRateMatching() {
        XCTAssertEqual(FrameRateMatch.preferredRefreshRate(filmFrameRate: 24, displayMaximum: 120), 48)
        XCTAssertEqual(try XCTUnwrap(FrameRateMatch.preferredRefreshRate(filmFrameRate: 23.976, displayMaximum: 120)), 47.952, accuracy: 0.001)
        XCTAssertEqual(FrameRateMatch.preferredRefreshRate(filmFrameRate: 25, displayMaximum: 120), 50)
        XCTAssertEqual(FrameRateMatch.preferredRefreshRate(filmFrameRate: 30, displayMaximum: 60), 60)
        XCTAssertEqual(FrameRateMatch.preferredRefreshRate(filmFrameRate: 50, displayMaximum: 120), 50)
        XCTAssertEqual(FrameRateMatch.preferredRefreshRate(filmFrameRate: 60, displayMaximum: 60), 60)
        XCTAssertNil(FrameRateMatch.preferredRefreshRate(filmFrameRate: 0, displayMaximum: 120))
        XCTAssertFalse(FrameRateMatch.isEvenCadence(filmFrameRate: 23.976, refreshRate: 60), "3:2 judder")
        XCTAssertTrue(FrameRateMatch.isEvenCadence(filmFrameRate: 23.976, refreshRate: 120))
        XCTAssertTrue(FrameRateMatch.isEvenCadence(filmFrameRate: 24, refreshRate: 48))
        XCTAssertTrue(FrameRateMatch.isEvenCadence(filmFrameRate: 30, refreshRate: 60))
        XCTAssertFalse(FrameRateMatch.isEvenCadence(filmFrameRate: 25, refreshRate: 60))
    }

    func testFileInfoStaysCompatibleWithOlderVersions() throws {
        // What 1.1.0 sends: no conversion fields.
        let old = #"{"size":1000,"name":"Film.mp4","uti":"public.mpeg-4","chunkSize":65536}"#
        let info = try JSONDecoder().decode(FileInfo.self, from: Data(old.utf8))
        XCTAssertNil(info.videoConverted)
        XCTAssertNil(info.audioConverted)
        // What 1.2.0 sends decodes with a decoder that only knows the old fields.
        struct OldFileInfo: Codable { var size: Int64; var name: String; var uti: String; var chunkSize: Int }
        let new = try JSONEncoder().encode(FileInfo(size: 1000, name: "Film.mp4", uti: "public.mpeg-4", videoConverted: false, audioConverted: true))
        XCTAssertEqual(try JSONDecoder().decode(OldFileInfo.self, from: new).name, "Film.mp4")
        let message = ControlMessage.fileInfo(FileInfo(size: 1, name: "a", uti: "b", videoConverted: true, audioConverted: false))
        XCTAssertEqual(ControlMessage.decode(message.encoded()), message)
    }
}
