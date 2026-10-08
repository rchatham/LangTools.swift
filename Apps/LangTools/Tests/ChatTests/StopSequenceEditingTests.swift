import Foundation
import XCTest
@testable import Chat

final class StopSequenceEditingTests: XCTestCase {
    func testAutomaticAndEnabledEmptyAreDistinct() {
        var editor = StopSequenceEditing(value: nil)
        XCTAssertFalse(editor.isEnabled)
        XCTAssertNil(editor.value)
        XCTAssertTrue(editor.rows.isEmpty)

        editor.setEnabled(true)
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.valueForPublishing(), [])
        editor.synchronize(with: [])
        XCTAssertTrue(editor.isEnabled)
        XCTAssertTrue(editor.rows.isEmpty)
    }

    func testAddFocusAndRepeatedEmptyWritesKeepBlankDraft() throws {
        var editor = StopSequenceEditing(value: [])
        editor.add()
        let id = try XCTUnwrap(editor.rows.first?.id)
        XCTAssertEqual(editor.valueForPublishing(), [])
        editor.synchronize(with: [])

        for _ in 0..<3 {
            XCTAssertTrue(editor.updateText("", for: id))
            XCTAssertEqual(editor.valueForPublishing(), [])
            editor.synchronize(with: [])
            XCTAssertEqual(editor.rows.map(\.id), [id])
            XCTAssertEqual(editor.rows.map(\.text), [""])
            XCTAssertTrue(editor.isEnabled)
        }
    }

    func testClearAndRetypeKeepsIdentityAndEnabledState() throws {
        var editor = StopSequenceEditing(value: ["END"])
        let id = try XCTUnwrap(editor.rows.first?.id)
        XCTAssertTrue(editor.updateText("", for: id))
        XCTAssertEqual(editor.valueForPublishing(), [])
        editor.synchronize(with: [])
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.rows.map(\.id), [id])

        XCTAssertTrue(editor.updateText("END", for: id))
        XCTAssertEqual(editor.valueForPublishing(), ["END"])
        editor.synchronize(with: ["END"])
        XCTAssertEqual(editor.rows.map(\.id), [id])
    }

    func testProjectionPreservesExactNonemptyStringsWithoutLimit() throws {
        let strings = [" ", "\n", " END ", "END", "END", "🛑\t"]
        var editor = StopSequenceEditing(value: strings)
        editor.add()
        XCTAssertEqual(editor.rows.count, strings.count + 1)
        XCTAssertEqual(editor.valueForPublishing(), strings)

        let settings = try ChatGenerationSettings(stop: editor.value)
        let restored = try JSONDecoder().decode(
            ChatGenerationSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.stop, strings)
        XCTAssertEqual(StopSequenceEditing(value: restored.stop).rows.map(\.text), strings)
    }

    func testBlankDraftsAreNotPersistedAndReopenOnlyRestoresCommittedRows() throws {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        editor.add()
        let settings = try ChatGenerationSettings(stop: editor.valueForPublishing())
        let restored = try JSONDecoder().decode(
            ChatGenerationSettings.self, from: JSONEncoder().encode(settings)
        )
        editor.synchronize(with: restored.stop, discardingDrafts: true)
        XCTAssertEqual(editor.rows.map(\.text), ["END"])
        XCTAssertTrue(editor.isEnabled)
    }

    func testReopenEnabledEmptyDropsUncommittedDraftButStaysEnabled() {
        var editor = StopSequenceEditing(value: [])
        editor.add()
        let published = editor.valueForPublishing()
        editor.synchronize(with: published, discardingDrafts: true)
        XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.value, [])
    }

    func testExistingPersistedBlanksAreNotRewrittenDuringSynchronization() {
        let saved = ["", "END", ""]
        var editor = StopSequenceEditing(value: saved)
        let ids = editor.rows.map(\.id)
        editor.synchronize(with: saved)
        XCTAssertEqual(editor.rows.map(\.id), ids)
        XCTAssertEqual(editor.rows.map(\.text), ["END"])
        XCTAssertEqual(editor.value, ["END"])
        // The editor never publishes merely by loading/synchronizing a binding.
    }

    func testRemovalUsesStableIdentityAfterIndexShift() throws {
        var editor = StopSequenceEditing(value: ["FIRST", "SECOND", "THIRD"])
        let ids = editor.rows.map(\.id)
        XCTAssertTrue(editor.remove(id: ids[0]))
        XCTAssertTrue(editor.updateText("LAST", for: ids[2]))
        XCTAssertEqual(editor.rows.map(\.id), Array(ids.dropFirst()))
        XCTAssertEqual(editor.valueForPublishing(), ["SECOND", "LAST"])
        XCTAssertFalse(editor.updateText("STALE", for: ids[0]))
        XCTAssertFalse(editor.remove(id: ids[0]))
        XCTAssertEqual(editor.value, ["SECOND", "LAST"])
    }

    func testExplicitFinalRemoveReturnsToAutomatic() throws {
        var editor = StopSequenceEditing(value: [])
        editor.add()
        let id = try XCTUnwrap(editor.rows.first?.id)
        XCTAssertTrue(editor.remove(id: id))
        XCTAssertNil(editor.valueForPublishing())
        XCTAssertFalse(editor.isEnabled)
        editor.synchronize(with: nil)
        XCTAssertTrue(editor.rows.isEmpty)
    }

    func testRemovingCommittedRowWithBlankDraftRemainingStaysEnabled() throws {
        var editor = StopSequenceEditing(value: ["END"])
        let committedID = try XCTUnwrap(editor.rows.first?.id)
        editor.add()
        let draftID = try XCTUnwrap(editor.rows.last?.id)
        XCTAssertTrue(editor.remove(id: committedID))
        XCTAssertEqual(editor.valueForPublishing(), [])
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.rows.map(\.id), [draftID])
        XCTAssertTrue(editor.remove(id: draftID))
        XCTAssertNil(editor.valueForPublishing())
    }

    func testToggleOffAndOnDiscardsDraftsAndInvalidatesOldEvents() throws {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        let oldID = try XCTUnwrap(editor.rows.last?.id)
        editor.setEnabled(false)
        XCTAssertNil(editor.valueForPublishing())
        XCTAssertTrue(editor.rows.isEmpty)
        editor.setEnabled(true)
        editor.add()
        XCTAssertFalse(editor.updateText("STALE", for: oldID))
        XCTAssertFalse(editor.remove(id: oldID))
        XCTAssertEqual(editor.valueForPublishing(), [])
        XCTAssertTrue(editor.isEnabled)
    }

    func testResetToAutomaticDiscardsDraftsAndIgnoresStaleEvents() throws {
        var editor = StopSequenceEditing(value: [])
        editor.add()
        let oldID = try XCTUnwrap(editor.rows.first?.id)
        editor.synchronize(with: nil, discardingDrafts: true)
        XCTAssertFalse(editor.isEnabled)
        XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertFalse(editor.updateText("STALE", for: oldID))
        XCTAssertFalse(editor.remove(id: oldID))
        XCTAssertNil(editor.value)
    }

    func testExternalUpdateReplacesDraftsBeforeLateFieldEvents() throws {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        _ = editor.valueForPublishing()
        let oldID = try XCTUnwrap(editor.rows.first?.id)
        // The view reconciles its current binding before any field mutation.
        editor.synchronize(with: ["EXTERNAL"])
        XCTAssertFalse(editor.updateText("STALE", for: oldID))
        XCTAssertFalse(editor.remove(id: oldID))
        XCTAssertEqual(editor.value, ["EXTERNAL"])
        XCTAssertEqual(editor.rows.map(\.text), ["EXTERNAL"])
    }

    func testExternalAutomaticAndEnabledEmptyChangesReconcile() {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        _ = editor.valueForPublishing()
        editor.synchronize(with: [])
        XCTAssertTrue(editor.isEnabled)
        XCTAssertTrue(editor.rows.isEmpty)
        editor.add()
        _ = editor.valueForPublishing()
        editor.synchronize(with: nil)
        XCTAssertFalse(editor.isEnabled)
        XCTAssertTrue(editor.rows.isEmpty)
    }

    func testSelfPublicationKeepsAllDraftsAndIDs() throws {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        editor.add()
        let ids = editor.rows.map(\.id)
        let published = editor.valueForPublishing()
        editor.synchronize(with: published)
        XCTAssertEqual(editor.rows.map(\.id), ids)
        XCTAssertEqual(editor.rows.map(\.text), ["END", "", ""])
        XCTAssertTrue(editor.updateText("NEXT", for: ids[1]))
        editor.synchronize(with: editor.valueForPublishing())
        XCTAssertEqual(editor.rows.map(\.id), ids)
        XCTAssertEqual(editor.rows.map(\.text), ["END", "NEXT", ""])
    }

    func testCapabilityChangeDiscardsDraftsButPreservesSavedValues() throws {
        var editor = StopSequenceEditing(value: ["END"])
        editor.add()
        let oldID = try XCTUnwrap(editor.rows.first?.id)
        let saved = editor.valueForPublishing()
        editor.synchronize(with: saved, discardingDrafts: true)
        XCTAssertEqual(editor.rows.map(\.text), ["END"])
        XCTAssertFalse(editor.updateText("STALE", for: oldID))
        XCTAssertEqual(editor.value, ["END"])
    }
}
