import Foundation
import XCTest
@testable import MacSignal

final class ProcessDisplayNameTests: XCTestCase {
    func testRunningApplicationNameTakesPriorityAndUnknownProcessesKeepRawName() {
        XCTAssertEqual(ProcessDisplayName.resolve(applicationName: "Windows 11",
                                                  executableURL: nil,
                                                  executableName: "prl_vm_app"), "Windows 11")
        XCTAssertEqual(ProcessDisplayName.resolve(applicationName: "  ",
                                                  executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
                                                  executableName: "tool"), "tool")
        XCTAssertEqual(ProcessDisplayName.resolve(applicationName: nil,
                                                  executableURL: nil,
                                                  executableName: "Process 123"), "Process 123")
    }

    func testBundleDisplayNameAndWorkerNamesPreserveProcessIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Editor.app")
        try writeBundle(at: app, name: "Editor", displayName: "Friendly Editor", executable: "editor-bin")
        XCTAssertEqual(resolve(app.appendingPathComponent("Contents/MacOS/editor-bin")), "Friendly Editor")
        XCTAssertEqual(resolve(app.appendingPathComponent("Contents/Resources/SDK/dotnet")),
                       "Friendly Editor (dotnet)")

        let helper = app.appendingPathComponent("Contents/Helpers/Worker.app")
        try writeBundle(at: helper, name: "Editor Worker", executable: "worker-bin")
        XCTAssertEqual(resolve(helper.appendingPathComponent("Contents/MacOS/worker-bin")), "Editor Worker")
    }

    private func resolve(_ executableURL: URL) -> String {
        ProcessDisplayName.resolve(applicationName: nil, executableURL: executableURL,
                                   executableName: executableURL.lastPathComponent)
    }

    private func writeBundle(at url: URL, name: String, displayName: String? = nil,
                             executable: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        var info = ["CFBundleName": name, "CFBundleExecutable": executable,
                    "CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.\(UUID().uuidString)"]
        info["CFBundleDisplayName"] = displayName
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/\(executable)"))
    }
}
