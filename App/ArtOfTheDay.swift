import AnsiCore
import AppKit
import SwiftUI

/// Settings for the menu bar art of the day (plan 10 ruling 10). Both are off by default.
enum ArtOfTheDaySettings {
    static let showKey = "artOfTheDayInMenuBar"
    static let sixteenColorsKey = "artOfTheDayFrom16colors"
}

/// One piece shown in the menu bar window.
struct DailyPiece {
    var title: String
    var detail: String
    var image: NSImage?
    var open: () -> Void
}

/// Finds today's pieces: one from the library (or the bundled samples), and with the 16colo.rs
/// setting on, one from 16colo.rs through the client's single request lane.
@MainActor
final class ArtOfTheDayModel: ObservableObject {
    @Published private(set) var local: DailyPiece?
    @Published private(set) var remote: DailyPiece?
    @Published private(set) var remoteStatus = ""
    private var loadedDay = ""
    private var remoteDay = ""
    private var remoteTask: Task<Void, Never>?

    /// The library to draw from; the app's own one by default (a harness passes its own records).
    var records: () -> [IndexRecord] = { LibraryStore.shared.records }
    var notes: () -> [String: PieceNotes] = { LibraryStore.shared.data.notes }
    var samples: () -> [SampleArt.Sample] = { SampleArt.all() }

    func refresh(now: Date = Date(), includeSixteenColors: Bool) {
        let day = ArtOfTheDay.dayKey(now)
        if day != loadedDay {
            loadedDay = day
            local = libraryPiece(day: day) ?? samplePiece(day: day)
        }
        if includeSixteenColors {
            if remoteDay != day { loadRemote(day: day) }
        } else {
            remoteTask?.cancel()
            remoteTask = nil
            remoteDay = ""
            remote = nil
            remoteStatus = ""
        }
    }

    private func libraryPiece(day: String) -> DailyPiece? {
        guard let record = ArtOfTheDay.pick(records(), notes: notes(), day: day) else { return nil }
        let file = LibraryStore.shared.artFile(record)
        let byline = [record.author, record.group].filter { !$0.isEmpty }.joined(separator: " / ")
        return DailyPiece(title: record.title.isEmpty ? record.name : record.title,
                          detail: byline.isEmpty ? record.name : "\(byline), \(record.name)",
                          image: file.flatMap(Self.picture),
                          open: { LibraryStore.shared.open(record) })
    }

    private func samplePiece(day: String) -> DailyPiece? {
        guard let sample = ArtOfTheDay.choose(from: samples(), day: day, salt: "sample"),
              let data = try? Data(contentsOf: sample.url) else { return nil }
        return DailyPiece(title: sample.title, detail: "An AnsiView sample (your library is empty)",
                          image: Self.picture(ArtFile(data: data, fileExtension: sample.url.pathExtension)),
                          open: { SampleArt.open(sample) })
    }

    /// Year list, the first page of that year's packs, the pack, the file: at most four requests a
    /// day, each cached, all through `SixteenColorsClient`'s one at a time lane.
    private func loadRemote(day: String) {
        remoteTask?.cancel()
        remoteDay = day
        remote = nil
        remoteStatus = "Asking 16colo.rs..."
        remoteTask = Task { [weak self] in
            let client = SixteenColorsClient.shared
            do {
                let years = try await client.years().filter { $0.packs > 0 }
                guard let year = ArtOfTheDay.choose(from: years, day: day, salt: "year") else { throw SixteenColors.DecodeError.unreadable }
                let page = try await client.packPage(year: year.year, page: 1)
                guard let pack = ArtOfTheDay.choose(from: page.packs, day: day, salt: "pack") else { throw SixteenColors.DecodeError.unreadable }
                let detail = try await client.pack(named: pack.name)
                guard let file = ArtOfTheDay.choose(from: detail.files.filter(\.isViewable), day: day, salt: "file")
                else { throw SixteenColors.DecodeError.unreadable }
                let url = try await client.downloadFile(file, in: pack.name)
                let data = try Data(contentsOf: url)
                let art = ArtFile(data: data, fileExtension: (file.name as NSString).pathExtension)
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    let artists = file.artists.joined(separator: ", ")
                    self.remote = DailyPiece(
                        title: file.name, detail: (artists.isEmpty ? "" : artists + ", ") + "\(pack.name) (\(year.year))",
                        image: Self.picture(art),
                        open: {
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                                if let error { NSAlert(error: error).runModal() }
                            }
                        })
                    self.remoteStatus = ""
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.remoteStatus = "16colo.rs: " + SixteenColorsClient.describe(error).message
                    self.remoteDay = ""
                }
            }
        }
    }

    /// The finished art's top (at most 50 rows) as a picture.
    static func picture(_ file: ArtFile) -> NSImage? {
        var screen = AnsiAnalysis(file).finalScreen
        if screen.rows.count > 50 { screen.rows = Array(screen.rows.prefix(50)) }
        guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: 1)) else { return nil }
        return NSImage(cgImage: rendered.image, size: NSSize(width: rendered.image.width, height: rendered.image.height))
    }
}

/// The window the menu bar item opens.
struct ArtOfTheDayView: View {
    @ObservedObject var model: ArtOfTheDayModel
    @AppStorage(ArtOfTheDaySettings.sixteenColorsKey) private var fromSixteenColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Art of the Day").font(.headline)
            if let local = model.local {
                PieceView(piece: local)
            } else {
                Text("Add folders to the Library (Window > Library) to see your own art here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Also show a piece from 16colo.rs", isOn: $fromSixteenColors)
                .help("Off by default. When on, AnsiView asks 16colo.rs for one piece a day: at most four requests, a second apart, cached.")
            if fromSixteenColors {
                if let remote = model.remote {
                    PieceView(piece: remote)
                } else if !model.remoteStatus.isEmpty {
                    Text(model.remoteStatus).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh(includeSixteenColors: fromSixteenColors) }
        .onChange(of: fromSixteenColors) { _, on in model.refresh(includeSixteenColors: on) }
    }
}

private struct PieceView: View {
    let piece: DailyPiece

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = piece.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 312, maxHeight: 240, alignment: .topLeading)
            }
            Text(piece.title).font(.body.weight(.semibold)).lineLimit(1)
            Text(piece.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Button("Open") { piece.open() }
                .help("Opens this piece in a viewer window")
        }
    }
}
