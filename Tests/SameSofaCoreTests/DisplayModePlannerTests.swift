import XCTest
@testable import SameSofaCore

final class DisplayModePlannerTests: XCTestCase {
    typealias P = DisplayModePlanner

    // MARK: helpers

    /// Builds a list of modes with the given size and rates; indexes continue from `start`.
    func modes(_ rates: [Double], w: Int = 1920, h: Int = 1080, pw: Int? = nil, ph: Int? = nil,
               usable: Bool = true, start: Int = 0) -> [DisplayModeInfo] {
        rates.enumerated().map {
            DisplayModeInfo(index: start + $0.offset, width: w, height: h, pixelWidth: pw ?? w,
                            pixelHeight: ph ?? h, refreshRate: $0.element, usableForDesktop: usable)
        }
    }

    func pick(_ fps: Double, _ list: [DisplayModeInfo], current: Double, variable: Bool = false) -> Double? {
        guard let cur = list.first(where: { $0.refreshRate == current }) else {
            XCTFail("current mode \(current) not in list"); return nil
        }
        return P.bestMode(filmFrameRate: fps, current: cur, available: list, variableRefresh: variable)?.refreshRate
    }

    let films: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    // MARK: cadence

    func testCadenceError() {
        XCTAssertEqual(P.cadenceError(filmFrameRate: 24, refreshRate: 48)!, 0, accuracy: 1e-9)
        XCTAssertEqual(P.cadenceError(filmFrameRate: 23.976, refreshRate: 60)!, 0.5 / 3, accuracy: 0.01) // 2.5
        XCTAssertEqual(P.cadenceError(filmFrameRate: 23.976, refreshRate: 24)!, 0.001, accuracy: 0.0001)
        XCTAssertNil(P.cadenceError(filmFrameRate: 60, refreshRate: 24))
        XCTAssertNil(P.cadenceError(filmFrameRate: 0, refreshRate: 60))
        XCTAssertNil(P.cadenceError(filmFrameRate: 24, refreshRate: 0))
        XCTAssertNotNil(P.cadenceError(filmFrameRate: 60, refreshRate: 59.94)) // within 1%
    }

    func testIsEven() {
        XCTAssertTrue(P.isEven(filmFrameRate: 23.976, refreshRate: 120))
        XCTAssertTrue(P.isEven(filmFrameRate: 24, refreshRate: 120))
        XCTAssertTrue(P.isEven(filmFrameRate: 25, refreshRate: 50))
        XCTAssertTrue(P.isEven(filmFrameRate: 29.97, refreshRate: 59.94))
        XCTAssertTrue(P.isEven(filmFrameRate: 59.94, refreshRate: 60))
        XCTAssertFalse(P.isEven(filmFrameRate: 23.976, refreshRate: 60))
        XCTAssertFalse(P.isEven(filmFrameRate: 25, refreshRate: 60))
        XCTAssertFalse(P.isEven(filmFrameRate: 50, refreshRate: 60))
        XCTAssertFalse(P.isEven(filmFrameRate: 60, refreshRate: 30))
    }

    // MARK: (a) a 60 Hz-only panel

    func testSixtyHzOnly() {
        let list = modes([60])
        for fps in films { XCTAssertNil(pick(fps, list, current: 60), "fps \(fps)") }
    }

    // MARK: (b) a typical TV list

    func testTelevisionList() {
        let tv = modes([23.976, 24, 25, 29.97, 30, 50, 59.94, 60])
        // Other resolutions with the same rates must never be chosen.
        let other4k = modes([23.976, 24, 25, 29.97, 30, 50, 59.94, 60], w: 3840, h: 2160, start: 100)
        let other720 = modes([24, 50, 60], w: 1280, h: 720, start: 200)
        let list = tv + other4k + other720
        // 23.976 Hz fits a 23.976 fps film precisely, 24 Hz only but for the 1000/1001 difference.
        // 25 fps: 25 and 50 Hz are both precise, the higher one wins.
        // 29.97, 30, 59.94 and 60 are already exact on 60 Hz and are tested below.
        let expected: [Double: Double] = [23.976: 23.976, 24: 24, 25: 50, 50: 50]
        for (fps, hz) in expected {
            let result = P.bestMode(filmFrameRate: fps, current: tv[7], available: list, variableRefresh: false)
            XCTAssertEqual(result?.refreshRate, hz, "fps \(fps)")
            XCTAssertEqual(result.map { $0.width }, 1920, "fps \(fps)")
            XCTAssertTrue((result?.index ?? 999) < 8, "fps \(fps) picked another resolution")
        }
        for fps in [29.97, 30, 59.94, 60] {
            XCTAssertNil(P.bestMode(filmFrameRate: fps, current: tv[7], available: list, variableRefresh: false), "fps \(fps)")
        }
        // 60 fps film on 60 Hz: already exact.
        XCTAssertNil(P.bestMode(filmFrameRate: 60, current: tv[7], available: list, variableRefresh: false))
        // 59.94 fps film on 60 Hz: 60/59.94 = 1.001, already exact.
        XCTAssertNil(P.bestMode(filmFrameRate: 59.94, current: tv[7], available: list, variableRefresh: false))
        // Currently on 24 Hz with a 23.976 film: already exact, leave it.
        XCTAssertNil(P.bestMode(filmFrameRate: 23.976, current: tv[1], available: list, variableRefresh: false))
    }

    // MARK: (c) a monitor with 48/50/60/75/100/120/144

    func testMonitorList() {
        let list = modes([48, 50, 60, 75, 100, 120, 144])
        XCTAssertEqual(pick(23.976, list, current: 60), 144) // 6.006x, exact; 144 is the highest exact rate
        XCTAssertEqual(pick(24, list, current: 60), 144) // 6x, highest exact
        XCTAssertEqual(pick(25, list, current: 60), 100) // 4x beats 2x(50) and 6x(150 absent)
        XCTAssertEqual(pick(50, list, current: 60), 100)
        XCTAssertEqual(pick(30, list, current: 75), 120) // 4x; 60 is 2x but lower
        XCTAssertNil(pick(29.97, modes([60, 75]), current: 60)) // 60/29.97 = 2.002 exact already
        XCTAssertNil(pick(60, list, current: 60))
        XCTAssertEqual(pick(48, list, current: 60), 144) // 3x
    }

    func testHighestExactRateWins() {
        let list = modes([60, 24, 48, 72, 120])
        XCTAssertEqual(pick(24, list, current: 60), 120)
    }

    // MARK: (d) ProMotion fixed-rate list

    func testProMotionFixedList() {
        let list = modes([47.95, 48, 50, 59.94, 60, 120])
        XCTAssertEqual(pick(23.976, list, current: 60), 47.95) // precise (x2); 120 is only exact (x5.005)
        XCTAssertEqual(pick(24, list, current: 60), 120)
        XCTAssertEqual(pick(25, list, current: 60), 50)
        XCTAssertEqual(pick(50, list, current: 60), 50)
        XCTAssertNil(pick(60, list, current: 60))
        XCTAssertNil(pick(30, list, current: 60))
        XCTAssertEqual(pick(29.97, list, current: 50), 59.94) // precise; 60 and 120 are only exact
    }

    func testProMotionVariableRefreshNeverSwitches() {
        let list = modes([47.95, 48, 50, 59.94, 60, 120])
        for fps in films { XCTAssertNil(pick(fps, list, current: 120, variable: true), "fps \(fps)") }
        XCTAssertNil(pick(25, list, current: 60, variable: true))
    }

    func testProMotionFromOddCurrent() {
        // 23.976 on 59.94 (2.5x) can use 47.95 or 119.88 (precise) or 48/120 (exact): the higher precise one wins.
        let list = modes([47.95, 48, 59.94, 119.88, 120])
        XCTAssertEqual(pick(23.976, list, current: 59.94), 119.88)
    }

    // MARK: (e) HiDPI

    func testSamePointSizeDifferentPixelSizeIsNotChosen() {
        let hidpi = DisplayModeInfo(index: 0, width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800,
                                    refreshRate: 60, usableForDesktop: true)
        let lowRes = DisplayModeInfo(index: 1, width: 1440, height: 900, pixelWidth: 1440, pixelHeight: 900,
                                     refreshRate: 24, usableForDesktop: true)
        let hidpi24 = DisplayModeInfo(index: 2, width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800,
                                      refreshRate: 24, usableForDesktop: true)
        XCTAssertNil(P.bestMode(filmFrameRate: 24, current: hidpi, available: [hidpi, lowRes], variableRefresh: false))
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: hidpi, available: [hidpi, lowRes, hidpi24],
                                  variableRefresh: false)?.index, 2)
    }

    func testDifferentPointSizeSamePixelSizeIsNotChosen() {
        let a = DisplayModeInfo(index: 0, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                                refreshRate: 60, usableForDesktop: true)
        let b = DisplayModeInfo(index: 1, width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160,
                                refreshRate: 24, usableForDesktop: true)
        XCTAssertNil(P.bestMode(filmFrameRate: 24, current: a, available: [a, b], variableRefresh: false))
    }

    // MARK: (f) not usable for the desktop

    func testUnusableModesAreSkipped() {
        let usable = modes([60])
        let unusable = modes([24, 48], usable: false, start: 1)
        XCTAssertNil(P.bestMode(filmFrameRate: 24, current: usable[0], available: usable + unusable, variableRefresh: false))
        let mixed = usable + unusable + modes([24], start: 3)
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: usable[0], available: mixed, variableRefresh: false)?.index, 3)
    }

    // MARK: (g) current refresh 0

    func testCurrentRefreshZeroMeansUnknown() {
        let current = DisplayModeInfo(index: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964,
                                      refreshRate: 0, usableForDesktop: true)
        let other = DisplayModeInfo(index: 1, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964,
                                    refreshRate: 24, usableForDesktop: true)
        XCTAssertNil(P.bestMode(filmFrameRate: 24, current: current, available: [current, other], variableRefresh: false))
    }

    func testCandidateWithZeroRefreshIsSkipped() {
        let list = modes([60, 0])
        XCTAssertNil(P.bestMode(filmFrameRate: 24, current: list[0], available: list, variableRefresh: false))
    }

    // MARK: (h) already exact

    func testAlreadyExactReturnsNil() {
        let list = modes([24, 25, 48, 50, 60, 120])
        XCTAssertNil(pick(24, list, current: 24))
        XCTAssertNil(pick(24, list, current: 48))
        XCTAssertNil(pick(25, list, current: 50))
        XCTAssertNil(pick(30, list, current: 60))
        XCTAssertNil(pick(23.976, list, current: 120)) // 5.005x, error 0.001
    }

    func testEvenButNotExactOnlyMovesToExact() {
        // 30 fps on 60.5 Hz is even (0.8 %) but not exact. 90 is exact, 61 is not.
        let list = modes([60.5, 61, 60, 90])
        let cur = list[0]
        XCTAssertEqual(P.bestMode(filmFrameRate: 30, current: cur, available: list, variableRefresh: false)?.refreshRate, 90)
        // Only a not-exact candidate: stay.
        let list2 = modes([60.5, 61])
        XCTAssertNil(P.bestMode(filmFrameRate: 30, current: list2[0], available: list2, variableRefresh: false))
    }

    func testNotEvenCurrentMayTakeANotExactCandidate() {
        // 25 fps on 60 Hz is not even. 75.5 Hz is 3.02x (0.7 %), even but not exact.
        let list = modes([60, 75.5])
        XCTAssertEqual(P.bestMode(filmFrameRate: 25, current: list[0], available: list, variableRefresh: false)?.refreshRate, 75.5)
        // An exact candidate beats a faster non-exact one.
        let list2 = modes([60, 75.5, 50])
        XCTAssertEqual(P.bestMode(filmFrameRate: 25, current: list2[0], available: list2, variableRefresh: false)?.refreshRate, 50)
    }

    func testTieGoesToLowerIndex() {
        let a = DisplayModeInfo(index: 5, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080,
                                refreshRate: 24, usableForDesktop: true)
        let b = DisplayModeInfo(index: 2, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080,
                                refreshRate: 24, usableForDesktop: true)
        let cur = modes([60], start: 9)[0]
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: cur, available: [cur, a, b], variableRefresh: false)?.index, 2)
    }

    // MARK: (i) film faster than every mode

    func testFilmFasterThanEveryMode() {
        let list = modes([24, 30, 60])
        XCTAssertNil(pick(120, list, current: 60))
        XCTAssertNil(pick(100, list, current: 60))
    }

    func testBadFilmRate() {
        let list = modes([24, 60])
        XCTAssertNil(pick(0, list, current: 60))
        XCTAssertNil(pick(-5, list, current: 60))
        XCTAssertNil(pick(0.5, list, current: 60))
        XCTAssertNil(pick(.nan, list, current: 60))
    }

    func testSkipsCurrentRefreshInList() {
        let list = modes([60, 60])
        XCTAssertNil(pick(24, list, current: 60))
    }

    // MARK: describe

    func testDescribe() {
        XCTAssertEqual(P.describe(filmFrameRate: 23.976, refreshRate: 47.95, variableRefresh: false, switched: true),
                       "23.976 fps on 47.95 Hz (display matched to the film): every frame is shown for the same time.")
        XCTAssertEqual(P.describe(filmFrameRate: 23.976, refreshRate: 60, variableRefresh: false, switched: false),
                       "23.976 fps on 60 Hz: frames alternate between 2 and 3 refreshes (judder).")
        XCTAssertEqual(P.describe(filmFrameRate: 24, refreshRate: 120, variableRefresh: true, switched: false),
                       "24 fps on a variable-refresh display: every frame is shown for the same time.")
        XCTAssertEqual(P.describe(filmFrameRate: 24, refreshRate: 48, variableRefresh: false, switched: false),
                       "24 fps on 48 Hz: every frame is shown for the same time.")
        XCTAssertEqual(P.describe(filmFrameRate: 25, refreshRate: 60, variableRefresh: false, switched: false),
                       "25 fps on 60 Hz: frames alternate between 2 and 3 refreshes (judder).")
        XCTAssertEqual(P.describe(filmFrameRate: 50, refreshRate: 60, variableRefresh: false, switched: false),
                       "50 fps on 60 Hz: frames alternate between 1 and 2 refreshes (judder).")
        XCTAssertEqual(P.describe(filmFrameRate: 59.94, refreshRate: 59.94, variableRefresh: false, switched: false),
                       "59.94 fps on 59.94 Hz: every frame is shown for the same time.")
    }

    func testFormatNumber() {
        XCTAssertEqual(P.formatNumber(24, maxDecimals: 3), "24")
        XCTAssertEqual(P.formatNumber(23.976, maxDecimals: 3), "23.976")
        XCTAssertEqual(P.formatNumber(47.95, maxDecimals: 2), "47.95")
        XCTAssertEqual(P.formatNumber(59.940, maxDecimals: 2), "59.94")
        XCTAssertEqual(P.formatNumber(120, maxDecimals: 2), "120")
    }

    func testAllFilmsAgainstAllLists() {
        // Whatever is chosen must be even, in the same geometry, and never the current rate.
        let lists = [modes([60]), modes([23.976, 24, 25, 29.97, 30, 50, 59.94, 60]),
                     modes([48, 50, 60, 75, 100, 120, 144]), modes([47.95, 48, 50, 59.94, 60, 120])]
        for list in lists {
            for cur in list {
                for fps in films {
                    guard let m = P.bestMode(filmFrameRate: fps, current: cur, available: list, variableRefresh: false) else { continue }
                    XCTAssertTrue(P.isEven(filmFrameRate: fps, refreshRate: m.refreshRate))
                    XCTAssertNotEqual(m.refreshRate, cur.refreshRate)
                    XCTAssertTrue(m.sameGeometry(as: cur))
                }
            }
        }
    }

    // MARK: real lists

    /// Refresh rates as Core Graphics reports them (not rounded).
    func testRatesAsTheSystemReportsThem() {
        let tv = modes([59.94005994, 60, 50, 29.97002997, 30, 25, 23.97602398, 24])
        XCTAssertEqual(pick(24000.0 / 1001, tv, current: 60), 23.97602398)
        XCTAssertEqual(pick(24, tv, current: 60), 24)
        XCTAssertEqual(pick(25, tv, current: 60), 50)
        XCTAssertNil(pick(30000.0 / 1001, tv, current: 60), "exact already (one repeated frame every 33 s): no blanking for that")
        XCTAssertNil(pick(60000.0 / 1001, tv, current: 60))
        XCTAssertEqual(pick(50, tv, current: 59.94005994), 50)
    }

    /// The same panel in scaled HiDPI and native modes, each with several rates: never leave the current scaling.
    func testHiDPIVariantsWithRates() {
        func mode(_ index: Int, _ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double) -> DisplayModeInfo {
            DisplayModeInfo(index: index, width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: hz, usableForDesktop: true)
        }
        let list = [mode(0, 1920, 1080, 3840, 2160, 60), mode(1, 1920, 1080, 3840, 2160, 24), mode(2, 3840, 2160, 3840, 2160, 60),
                    mode(3, 3840, 2160, 3840, 2160, 24), mode(4, 1920, 1080, 1920, 1080, 60), mode(5, 1920, 1080, 1920, 1080, 24),
                    mode(6, 2560, 1440, 5120, 2880, 24)]
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: list[0], available: list, variableRefresh: false)?.index, 1)
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: list[2], available: list, variableRefresh: false)?.index, 3)
        XCTAssertEqual(P.bestMode(filmFrameRate: 24, current: list[4], available: list, variableRefresh: false)?.index, 5)
    }

    func testGrades() {
        XCTAssertEqual(P.grade(filmFrameRate: 23.976, refreshRate: 47.952), 0)
        XCTAssertEqual(P.grade(filmFrameRate: 23.976, refreshRate: 24), 1)
        XCTAssertEqual(P.grade(filmFrameRate: 23.976, refreshRate: 120), 1)
        XCTAssertEqual(P.grade(filmFrameRate: 30, refreshRate: 60.5), 2)
        XCTAssertEqual(P.grade(filmFrameRate: 23.976, refreshRate: 60), 3)
        XCTAssertEqual(P.grade(filmFrameRate: 60, refreshRate: 24), 3)
        XCTAssertEqual(P.grade(filmFrameRate: 24, refreshRate: 0), 3)
    }
}
