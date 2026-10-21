import Foundation
import Testing
@testable import SkylineCore

struct UpdateRaceTests {
    @Test func aSecondClickIsBlockedWhileOneUpdateIsPending() {
        let ours: Int32 = 10
        #expect(!UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: nil, markerAlive: false, lockPID: nil, lockAlive: false))
        #expect(UpdateGate.updateInProgress(ourPID: ours, phaseBusy: true, markerPID: nil, markerAlive: false, lockPID: nil, lockAlive: false))
        #expect(UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: 22, markerAlive: true, lockPID: nil, lockAlive: false))
        #expect(!UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: 22, markerAlive: false, lockPID: nil, lockAlive: false))
        // A marker this process left behind while idle is not another update.
        #expect(!UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: ours, markerAlive: true, lockPID: nil, lockAlive: false))
        #expect(UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: nil, markerAlive: false, lockPID: 33, lockAlive: true))
        #expect(!UpdateGate.updateInProgress(ourPID: ours, phaseBusy: false, markerPID: nil, markerAlive: false, lockPID: 33, lockAlive: false))
        #expect(UpdateGate.downloadingTitle(build: 119) == "Downloading build 119…")
    }

    @Test func eachUpdateRunGetsItsOwnLogFile() {
        let a = UpdateScript.resultLogFileName(token: "one")
        let b = UpdateScript.resultLogFileName(token: "two")
        #expect(a == "skyline-update-one.txt")
        #expect(a != b)
        #expect(UpdateScript.isFailureLogName(a))
        #expect(UpdateScript.isFailureLogName("skyline-update-result.txt"))
        #expect(!UpdateScript.isFailureLogName("skyline-update-one.txt.partial"))
        #expect(!UpdateScript.isFailureLogName("skyline-dock-test.txt"))
        let cmd = UpdateScript.command(installer: "/A/install-verified.sh", newerThan: 117, zip: "/I/Skyline.zip",
                                        resultLog: "/L/\(a)")
        #expect(cmd.contains("> '/L/skyline-update-one.txt.partial' 2>&1"))
        #expect(cmd.contains("mv -f '/L/skyline-update-one.txt.partial' '/L/skyline-update-one.txt'"))
        #expect(!cmd.contains("skyline-update-two"))
        #expect(!cmd.contains("> '/L/skyline-update-one.txt' "))
    }

    @Test func installVerifiedHarness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/test-install-verified.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "install harness failed:\n\(text)")
        #expect(text.contains("ALL PASS"))
    }
}
