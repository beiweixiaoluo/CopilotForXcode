import CopilotModel
import Foundation
import XcodeKit

extension XCSourceEditorCommandInvocation {
    func mutateCompleteBuffer(content: String, restoringSelections restore: Bool) {
        if restore {
            let selectionsRangesToRestore = buffer.selections.compactMap { $0 as? XCSourceTextRange }
            buffer.selections.removeAllObjects()
            buffer.completeBuffer = content
            for range in selectionsRangesToRestore {
                buffer.selections.add(range)
            }
        } else {
            buffer.completeBuffer = content
        }
    }

    func accept(_ updatedContent: UpdatedContent) {
        if let newCursor = updatedContent.newCursor {
            mutateCompleteBuffer(content: updatedContent.content, restoringSelections: false)
            buffer.selections.removeAllObjects()
            buffer.selections.add(XCSourceTextRange(
                start: .init(line: newCursor.line, column: newCursor.character),
                end: .init(line: newCursor.line, column: newCursor.character)
            ))
        } else {
            mutateCompleteBuffer(
                content: updatedContent.content,
                restoringSelections: true
            )
        }
    }
}

extension EditorContent {
    init(_ invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        content = buffer.completeBuffer
        lines = buffer.lines as! [String]
        uti = buffer.contentUTI
        cursorPosition = ((buffer.selections.lastObject as? XCSourceTextRange)?.start).map {
            CursorPosition(line: $0.line, character: $0.column)
        } ?? CursorPosition(line: 0, character: 0)
        tabSize = buffer.tabWidth
        indentSize = buffer.indentationWidth
        usesTabsForIndentation = buffer.usesTabsForIndentation
    }
}