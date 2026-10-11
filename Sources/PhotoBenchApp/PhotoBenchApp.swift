import AppKit
import Foundation
import PhotoCore
import SwiftUI

@MainActor
final class PhotoBenchApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var editorModel: EditorModel?

    func attach(model: EditorModel) {
        editorModel = model
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editorModel else { return .terminateNow }
        let unsavedCount = editorModel.flushPendingChanges()
        guard unsavedCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未保存の編集が\(unsavedCount)枚あります。"
        alert.informativeText = "終了前の再保存に失敗しました。終了を中止して再試行するか、未保存のまま終了してください。"
        alert.addButton(withTitle: "終了を中止")
        alert.addButton(withTitle: "未保存のまま終了")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

@main
struct PhotoBenchApp: App {
    @NSApplicationDelegateAdaptor(PhotoBenchApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model: EditorModel

    init() {
        let defaultPath = "/Users/takuyatakahama/Documents/app/NIHO/others/photo"
        let initialPath = CommandLine.arguments.dropFirst().first ?? defaultPath
        _model = StateObject(
            wrappedValue: EditorModel(
                initialDirectoryHint: URL(fileURLWithPath: initialPath, isDirectory: true)
            )
        )
    }

    var body: some Scene {
        WindowGroup("NIHO camera") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_140, minHeight: 720)
                .onAppear { applicationDelegate.attach(model: model) }
        }
        .defaultSize(width: 1_440, height: 900)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("戻す") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!model.canUndo || !model.canEdit)
                Button("やり直す") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo || !model.canEdit)
            }
            CommandGroup(replacing: .newItem) {
                Button("写真を開く…", action: model.choosePhoto)
                    .keyboardShortcut("o")
                Button("写真フォルダを開く…", action: model.chooseFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("XMPプリセットを読み込む…", action: model.importPreset)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("JPEGを書き出す…", action: model.exportFromPanel)
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!model.canExport)
                Button("PNGを書き出す…", action: model.exportPNGFromPanel)
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.canExport || !model.isShowingCutout)
            }
        }
    }
}
