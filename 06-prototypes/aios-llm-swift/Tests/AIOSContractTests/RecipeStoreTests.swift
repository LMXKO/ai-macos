import Foundation
import XCTest
@testable import AIOS

final class RecipeStoreTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aios-recipe-store-tests-\(UUID().uuidString)", isDirectory: true)
        setenv("AIOS_STATE_DIR", stateDir.path, 1)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("AIOS_STATE_DIR")
        if let stateDir, FileManager.default.fileExists(atPath: stateDir.path) {
            try FileManager.default.removeItem(at: stateDir)
        }
    }

    func testRecipeListSkipsNonRecipeJSONArtifacts() throws {
        try RecipeStore.seedDefaults(overwrite: false)
        try FileManager.default.createDirectory(at: EventStore.recipesURL, withIntermediateDirectories: true)
        try #"{"schema":"aios.recipe.repair_hints.v1","hints":[]}"#
            .write(to: EventStore.recipesURL.appendingPathComponent("repair-hints.json"), atomically: true, encoding: .utf8)

        let recipes = try RecipeStore.list()

        XCTAssertTrue(recipes.contains { $0.id == "export-document-pdf" })
        XCTAssertFalse(recipes.contains { $0.id == "repair-hints" })
    }
}
