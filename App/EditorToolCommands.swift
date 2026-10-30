import AppKit
import SwiftUI

/// The editor v2 Tools menu (editor tools plan). Items go to the focused editor through the
/// responder chain; the keys shown in tooltips and Editor Shortcuts are handled by the canvas
/// itself, so they stay configurable.
struct EditorToolCommands: Commands {
    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Draw (Half Blocks)") { send(#selector(EditorCanvasView.chooseDrawTool(_:))) }
            Button("Select") { send(#selector(EditorCanvasView.chooseSelectTool(_:))) }
            Button("Line") { send(#selector(EditorCanvasView.chooseLineTool(_:))) }
            Button("Box and Shapes") { send(#selector(EditorCanvasView.chooseBoxTool(_:))) }
            Button("Fill") { send(#selector(EditorCanvasView.chooseFillTool(_:))) }
            Button("Text") { send(#selector(EditorCanvasView.chooseTextTool(_:))) }
            Button("Brush") { send(#selector(EditorCanvasView.chooseBrushTool(_:))) }
            Button("Eyedropper") { send(#selector(EditorCanvasView.chooseEyedropperTool(_:))) }
            Divider()
            Button("Character Picker...") { send(#selector(EditorCanvasView.showCharacterPicker(_:))) }
            Button("Text Art...") { send(#selector(EditorCanvasView.showTextArt(_:))) }
            Button("Text to ASCII...") { TextToASCIIWindowController.show(editor: nil) }
            Button("Font Manager...") { FontManagerWindowController.show() }
            Button("Swap Foreground and Background") { send(#selector(EditorCanvasView.swapColours(_:))) }
            Button("Toggle Insert Mode") { send(#selector(EditorCanvasView.toggleInsertMode(_:))) }
            Divider()
            Button("Insert Line") { send(#selector(EditorCanvasView.insertLine(_:))) }
            Button("Delete Line") { send(#selector(EditorCanvasView.deleteLine(_:))) }
            Button("Insert Column") { send(#selector(EditorCanvasView.insertColumn(_:))) }
            Button("Delete Column") { send(#selector(EditorCanvasView.deleteColumn(_:))) }
            Divider()
            Button("Move Selection") { send(#selector(EditorCanvasView.liftSelection(_:))) }
            Button("Mirror Horizontally") { send(#selector(EditorCanvasView.mirrorHorizontally(_:))) }
            Button("Mirror Vertically") { send(#selector(EditorCanvasView.mirrorVertically(_:))) }
            Button("Rotate 180") { send(#selector(EditorCanvasView.rotate180(_:))) }
            Button("Rotate 90 Clockwise") { send(#selector(EditorCanvasView.rotateClockwise(_:))) }
            Button("Crop to Selection") { send(#selector(EditorCanvasView.cropToSelection(_:))) }
            Button("Swap Colours in Selection") { send(#selector(EditorCanvasView.swapSelectionColours(_:))) }
            Button("Replace...") { send(#selector(EditorCanvasView.showReplace(_:))) }
            Divider()
            Button("Add Layer") { send(#selector(EditorCanvasView.addLayer(_:))) }
            Button("Merge Layer Down") { send(#selector(EditorCanvasView.mergeLayerDown(_:))) }
            Button("Flatten Layers") { send(#selector(EditorCanvasView.flattenLayers(_:))) }
            Divider()
            Button("Toggle Grid") { send(#selector(EditorCanvasView.toggleGrid(_:))) }
            Button("Toggle Retro Theme") { send(#selector(EditorCanvasView.toggleRetroTheme(_:))) }
            Button("Full Screen Editing") { send(#selector(NSWindow.toggleFullScreen(_:))) }
            Button("Editor Shortcuts...") { ShortcutsWindowController.shared.showWindow(nil) }
            Divider()
            Button("Open Project...") { EditorWindowController.openProject() }
            Button("Save Project...") { send(#selector(EditorCanvasView.saveProject(_:))) }
        }
    }
}
