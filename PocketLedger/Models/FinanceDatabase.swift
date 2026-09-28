import Foundation
import SwiftData

@Model
final class FinanceDatabaseRecord {
    var payload: Data
    var schemaVersion: Int

    init(payload: Data, schemaVersion: Int = 1) {
        self.payload = payload
        self.schemaVersion = schemaVersion
    }
}
