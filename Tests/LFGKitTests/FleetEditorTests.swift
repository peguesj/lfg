import XCTest
@testable import LFGKit

final class FleetEditorTests: XCTestCase {

    // MARK: - Helpers

    private func tempFleetURL(json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-fleet.json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    private let minimalFleet = """
    {
      "drives": [
        {
          "id": "901DEVLIB",
          "image": "/Volumes/YJ_MORE/DevDrive/901DEVLIB.dmg.sparseimage",
          "mount": "/Volumes/DDRV-901-DEVLIB",
          "host": "YJ_MORE",
          "reconnect_policy": "auto",
          "symlinks": []
        }
      ],
      "external_hosts": [
        {
          "name": "YJ_MORE",
          "mount": "/Volumes/YJ_MORE",
          "role": "external_host",
          "keep_awake": true
        }
      ]
    }
    """

    // MARK: - updateBackend

    func testUpdateBackendMutatesPurpose() throws {
        let url = try tempFleetURL(json: minimalFleet)
        try FleetEditor.updateBackend(id: "901DEVLIB", at: url) { drive in
            drive["purpose"] = "Updated purpose"
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let drives = raw["drives"] as! [[String: Any]]
        XCTAssertEqual(drives.first?["purpose"] as? String, "Updated purpose")
    }

    func testUpdateBackendThrowsForUnknownID() throws {
        let url = try tempFleetURL(json: minimalFleet)
        XCTAssertThrowsError(
            try FleetEditor.updateBackend(id: "NONEXISTENT", at: url) { _ in }
        ) { error in
            guard case FleetEditorError.backendNotFound(let id) = error else {
                return XCTFail("Expected backendNotFound, got \(error)")
            }
            XCTAssertEqual(id, "NONEXISTENT")
        }
    }

    func testUpdateBackendCanMutateSymlinks() throws {
        let url = try tempFleetURL(json: minimalFleet)
        try FleetEditor.updateBackend(id: "901DEVLIB", at: url) { drive in
            drive["symlinks"] = ["~/.npm-cache → /Volumes/DDRV-901-DEVLIB/npm-cache"]
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let drives = raw["drives"] as! [[String: Any]]
        let syms = drives.first?["symlinks"] as? [String]
        XCTAssertEqual(syms?.count, 1)
    }

    // MARK: - addBackend

    func testAddBackendAppendsEntry() throws {
        let url = try tempFleetURL(json: minimalFleet)
        let newDrive: [String: Any] = [
            "id": "905NEW",
            "image": "/Volumes/YJ_MORE/DevDrive/905NEW.dmg.sparseimage",
            "mount": "/Volumes/DDRV-905-NEW",
            "host": "YJ_MORE",
            "reconnect_policy": "manual",
            "symlinks": []
        ]
        try FleetEditor.addBackend(newDrive, at: url)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let drives = raw["drives"] as! [[String: Any]]
        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives.last?["id"] as? String, "905NEW")
    }

    // MARK: - removeBackend

    func testRemoveBackendDeletesEntry() throws {
        let url = try tempFleetURL(json: minimalFleet)
        try FleetEditor.removeBackend(id: "901DEVLIB", at: url)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let drives = raw["drives"] as! [[String: Any]]
        XCTAssertTrue(drives.isEmpty)
    }

    func testRemoveBackendSilentForMissingID() throws {
        let url = try tempFleetURL(json: minimalFleet)
        XCTAssertNoThrow(try FleetEditor.removeBackend(id: "GHOST", at: url))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let drives = raw["drives"] as! [[String: Any]]
        XCTAssertEqual(drives.count, 1)  // unmodified
    }

    // MARK: - updateSourceVolume

    func testUpdateSourceVolumeToggleKeepAwake() throws {
        let url = try tempFleetURL(json: minimalFleet)
        try FleetEditor.updateSourceVolume(name: "YJ_MORE", at: url) { host in
            host["keep_awake"] = false
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hosts = raw["external_hosts"] as! [[String: Any]]
        XCTAssertEqual(hosts.first?["keep_awake"] as? Bool, false)
    }

    func testUpdateSourceVolumeThrowsForUnknown() throws {
        let url = try tempFleetURL(json: minimalFleet)
        XCTAssertThrowsError(
            try FleetEditor.updateSourceVolume(name: "UNKNOWN", at: url) { _ in }
        ) { error in
            guard case FleetEditorError.sourceVolumeNotFound = error else {
                return XCTFail("Expected sourceVolumeNotFound")
            }
        }
    }

    // MARK: - Atomic write

    func testWriteIsAtomicAndReadable() throws {
        let url = try tempFleetURL(json: minimalFleet)
        try FleetEditor.updateBackend(id: "901DEVLIB", at: url) { drive in
            drive["tier"] = "hot"
        }
        // Re-parse to confirm valid JSON was written.
        XCTAssertNoThrow(
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        )
    }
}
