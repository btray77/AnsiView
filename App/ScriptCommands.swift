import AnsiCore
import Foundation

/// What the AppleScript commands do (plan 10 ruling 7), apart from Cocoa scripting.
enum ScriptActions {
    enum Failure: LocalizedError {
        case unknownFormat(String, [String])

        var errorDescription: String? {
            switch self {
            case .unknownFormat(let name, let known):
                return "AnsiView does not know the format \"\(name)\". Use one of: \(known.joined(separator: ", "))."
            }
        }
    }

    /// `render <file> to <file> [in format png|jpeg|gif] [scale n]`; returns the output's path.
    static func render(file: URL, to output: URL, format: String?, scale: Int?) throws -> String {
        let name = (format ?? output.pathExtension).lowercased()
        let aliases = ["jpg": "jpeg", "": "png"]
        guard let chosen = ArtActions.ImageFormat(rawValue: aliases[name] ?? name) else {
            throw Failure.unknownFormat(name, ArtActions.ImageFormat.allCases.map(\.rawValue))
        }
        try ArtActions.render(file, to: output, format: chosen, scale: scale ?? 2)
        return output.path
    }

    /// `convert <file> [to <file>] [in format text|utf8|ansi|ansi256|html]`: writes the file when
    /// one is given (returning its path), otherwise returns the text.
    static func convert(file: URL, to output: URL?, format: String?) throws -> String {
        let name = (format ?? "utf8").lowercased()
        guard let chosen = TextFormat(rawValue: name) else {
            throw Failure.unknownFormat(name, TextFormat.allCases.map(\.rawValue))
        }
        let data = try ArtActions.convert(file, format: chosen)
        if let output {
            try data.write(to: output, options: .atomic)
            return output.path
        }
        if chosen == .text { return String(String.UnicodeScalarView(data.map { CP437.unicode[Int($0)] })) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A `file` parameter as Cocoa scripting hands it over.
    static func url(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let path = value as? String { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return nil
    }
}

/// `render` in AnsiView.sdef.
@objc(AnsiRenderScriptCommand)
final class AnsiRenderScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let input = ScriptActions.url(directParameter), let output = ScriptActions.url(evaluatedArguments?["Output"]) else {
            scriptErrorNumber = -50
            scriptErrorString = "render needs an art file and a file to write (to file ...)."
            return nil
        }
        do {
            return try ScriptActions.render(file: input, to: output, format: evaluatedArguments?["Format"] as? String,
                                            scale: evaluatedArguments?["Scale"] as? Int)
        } catch {
            scriptErrorNumber = -1
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}

/// `convert` in AnsiView.sdef.
@objc(AnsiConvertScriptCommand)
final class AnsiConvertScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let input = ScriptActions.url(directParameter) else {
            scriptErrorNumber = -50
            scriptErrorString = "convert needs an art file."
            return nil
        }
        do {
            return try ScriptActions.convert(file: input, to: ScriptActions.url(evaluatedArguments?["Output"]),
                                             format: evaluatedArguments?["Format"] as? String)
        } catch {
            scriptErrorNumber = -1
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
