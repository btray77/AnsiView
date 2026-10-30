import AnsiCore
import Foundation

/// One piece to export in a batch.
struct BatchItem {
    let name: String
    let load: () throws -> Data
}

/// What happened to one piece.
struct BatchResult {
    let name: String
    /// The file written; nil when the piece failed.
    let output: URL?
    let error: String?
    /// A byte limit could not be met; the smallest result was kept.
    let overLimit: Bool
    let bytes: Int
}

/// Exports many pieces with the same settings. A piece that fails is recorded and the batch
/// goes on; a cancel stops after the current frame and keeps the files already written.
enum BatchExporter {
    /// At most this many problems are listed in a summary.
    static let listedProblems = 20

    static func run(
        _ items: [BatchItem], settings: ExportSettings, to folder: URL, overwrite: Bool,
        progress: @escaping (_ index: Int, _ name: String, _ fraction: Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> [BatchResult] {
        let existing = overwrite ? [] : Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var naming = BatchNaming(existing: existing)
        var results: [BatchResult] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return items.map { BatchResult(name: $0.name, output: nil, error: error.localizedDescription, overLimit: false, bytes: 0) }
        }
        for (index, item) in items.enumerated() {
            if isCancelled() { break }
            progress(index, item.name, 0)
            let url = folder.appendingPathComponent(naming.name(for: item.name, fileExtension: settings.kind.fileExtension))
            do {
                let data = try item.load()
                let source = ArtFile(data: data, fileExtension: (item.name as NSString).pathExtension)
                let outcome = try AnsiExporter.export(source, settings: settings, to: url,
                                                      progress: { progress(index, item.name, min(0.99, $0)) },
                                                      isCancelled: isCancelled)
                results.append(BatchResult(name: item.name, output: url, error: nil, overLimit: outcome.overLimit,
                                           bytes: outcome.bytes))
            } catch AnsiExportError.cancelled {
                try? FileManager.default.removeItem(at: url)
                break
            } catch {
                try? FileManager.default.removeItem(at: url)
                results.append(BatchResult(name: item.name, output: nil, error: error.localizedDescription,
                                           overLimit: false, bytes: 0))
            }
            progress(index, item.name, 1)
        }
        return results
    }

    /// The alert text for a finished batch: "Exported X of N files", then the failures and the
    /// files over the size limit.
    static func summary(_ results: [BatchResult], total: Int) -> (title: String, detail: String) {
        let written = results.filter { $0.output != nil }.count
        let noun = total == 1 ? "file" : "files"
        let title = results.count < total
            ? "Cancelled: exported \(written) of \(total) \(noun)"
            : "Exported \(written) of \(total) \(noun)"
        var problems: [String] = []
        for result in results {
            if let error = result.error {
                problems.append("\(result.name): \(error)")
            } else if result.overLimit {
                let size = ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
                problems.append("\(result.name): over the size limit (\(size))")
            }
        }
        var lines = Array(problems.prefix(listedProblems))
        if problems.count > listedProblems { lines.append("and \(problems.count - listedProblems) more") }
        return (title, lines.joined(separator: "\n"))
    }
}
