import Foundation
import Testing
@testable import SkylineCore

struct WindowReopenStateTests {
    private func city(_ name: String, lat: Double, lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    @Test func closeReopenDoesNotWriteLocations() throws {
        let saved = city("New York", lat: 40.7128, lon: -74.0060)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let document = SyncDocument.migrating(locations: [saved], settings: ["unitPreference": "imperial"], now: now)
        let bytes = try document.encoded()
        guard case .document(let read) = SyncDocument.read(bytes) else {
            Issue.record("sync.json did not decode")
            return
        }
        let writer = CountingDocumentWriter()
        let after = WindowReopenPersistence.closeAndReopen(locations: read.locations, settings: read.settings,
                                                           syncBytes: bytes, writer: writer, now: now)
        #expect(writer.locationWrites == 0)
        #expect(writer.syncWrites == 0)
        #expect(after.locations == read.locations)
        #expect(LocationPersistence.launchLocations(local: after.locations, lastSynced: read.locations) == [saved])
    }

    @Test func closeReopenDoesNotWriteSettingsOrSync() throws {
        let units = "imperial"
        let saved = city("Boston", lat: 42.3601, lon: -71.0589)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = ["unitPreference": units, "unit.temperature": "F"]
        let document = SyncDocument.migrating(locations: [saved], settings: settings, now: now)
        let bytes = try document.encoded()
        let writer = CountingDocumentWriter()
        let after = WindowReopenPersistence.closeAndReopen(locations: document.locations, settings: settings,
                                                           syncBytes: bytes, writer: writer, now: now)
        #expect(writer.settingsWrites == 0)
        #expect(writer.syncWrites == 0)
        #expect(writer.locationWrites == 0)
        #expect(after.syncBytes == bytes)
        #expect(after.settings["unitPreference"] == units)
        guard case .document(let read) = SyncDocument.read(after.syncBytes) else {
            Issue.record("sync.json did not decode")
            return
        }
        #expect(read.settings["unitPreference"] == units)
        #expect(read.settings["unit.temperature"] == "F")
        #expect(read.sameContent(as: document))
    }
}
