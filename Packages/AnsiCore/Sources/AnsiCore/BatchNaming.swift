import Foundation

/// Output file names for a batch export: the piece's name with its extension replaced, never
/// reusing a name already taken in the batch or on disk (compared without case, as APFS does).
public struct BatchNaming {
    private var taken: Set<String>

    /// `existing` holds the names already in the output folder.
    public init(existing: Set<String>) {
        taken = Set(existing.map { $0.lowercased() })
    }

    public mutating func name(for itemName: String, fileExtension: String) -> String {
        var stem = (itemName as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if stem.hasPrefix(".") { stem = "_" + stem.dropFirst() }
        if stem.isEmpty { stem = "Untitled" }
        var candidate = stem + "." + fileExtension
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(stem) \(number).\(fileExtension)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
