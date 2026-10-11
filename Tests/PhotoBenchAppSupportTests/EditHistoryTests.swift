import PhotoBenchAppSupport
import PhotoCore
import NihoCameraCutout
import Testing

struct EditHistoryTests {
    @Test func backgroundRecipeParticipatesInUndoRedo() {
        let photoID = "/photos/cutout.jpg"
        let reference = CutoutMaskReference(
            artifactID: String(repeating: "1", count: 64),
            maskSHA256: String(repeating: "2", count: 64),
            inputSHA256: String(repeating: "3", count: 64),
            width: 100,
            height: 200,
            selection: .instance(1)
        )
        var cutout = PhotoEditSnapshot.neutral
        cutout.backgroundEdit = BackgroundEditRecipe(
            subjects: [CutoutSubject(selection: .instance(1), pixelCount: 10_000, mask: reference)],
            selectedSubject: .instance(1),
            background: .transparent
        )
        var history = PerPhotoEditHistory()
        history.record(before: .neutral, after: cutout, for: photoID)
        #expect(history.undo(for: photoID, current: cutout) == .neutral)
        #expect(history.redo(for: photoID, current: .neutral) == cutout)
    }

    @Test func dragIsOneUndoGroupAndUndoRedoFollowSnapshots() {
        let photoID = "/photos/one.jpg"
        let neutral = PhotoEditSnapshot.neutral
        var history = PerPhotoEditHistory()
        history.beginGroup(for: photoID, startingAt: neutral)

        var firstDragValue = neutral
        firstDragValue.settings.relativeTemperature = 20
        history.record(before: neutral, after: firstDragValue, for: photoID)
        var finalDragValue = firstDragValue
        finalDragValue.settings.relativeTemperature = 55
        finalDragValue.settings.relativeTint = -15
        history.record(before: firstDragValue, after: finalDragValue, for: photoID)
        history.endGroup(for: photoID, at: finalDragValue)

        #expect(history.canUndo(for: photoID))
        #expect(!history.canRedo(for: photoID))
        #expect(history.undo(for: photoID, current: finalDragValue) == neutral)
        #expect(history.canRedo(for: photoID))
        #expect(history.redo(for: photoID, current: neutral) == finalDragValue)
    }

    @Test func photoHistoriesStaySeparateAndANewEditClearsRedo() {
        let firstPhotoID = "/photos/one.jpg"
        let secondPhotoID = "/photos/two.jpg"
        let neutral = PhotoEditSnapshot.neutral
        var history = PerPhotoEditHistory()

        var firstEdit = neutral
        firstEdit.settings.exposure = 1
        history.record(before: neutral, after: firstEdit, for: firstPhotoID)
        var secondEdit = neutral
        secondEdit.settings.saturation = 20
        history.record(before: neutral, after: secondEdit, for: secondPhotoID)

        #expect(history.undo(for: secondPhotoID, current: secondEdit) == neutral)
        #expect(history.canRedo(for: secondPhotoID))
        #expect(history.canUndo(for: firstPhotoID))

        var newSecondEdit = neutral
        newSecondEdit.settings.contrast = 15
        newSecondEdit.settings.relativeTint = 28
        history.record(before: neutral, after: newSecondEdit, for: secondPhotoID)
        #expect(!history.canRedo(for: secondPhotoID))
        #expect(history.undo(for: firstPhotoID, current: firstEdit) == neutral)
        #expect(history.redo(for: firstPhotoID, current: neutral) == firstEdit)
    }

    @Test func groupingAnUnchangedGestureDoesNotCreateHistory() {
        let photoID = "/photos/one.jpg"
        let neutral = PhotoEditSnapshot.neutral
        var history = PerPhotoEditHistory()
        history.beginGroup(for: photoID, startingAt: neutral)
        history.endGroup(for: photoID, at: neutral)

        #expect(!history.canUndo(for: photoID))
        #expect(history.undo(for: photoID, current: neutral) == nil)
    }
}
