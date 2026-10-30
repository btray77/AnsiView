import Foundation

/// The kinds of BBS screen the designer makes; each export profile maps a slot to the file name
/// its BBS package shows for it.
public enum ScreenSlot: String, Codable, CaseIterable, Equatable {
    case matrix, welcome, newUser, mainMenu, goodbye, bulletinList, messageHeader, fileHeader, doorMenu, ad, loading, custom

    public var label: String {
        switch self {
        case .matrix: return "Matrix / login"
        case .welcome: return "Welcome (after login)"
        case .newUser: return "New user"
        case .mainMenu: return "Main menu"
        case .goodbye: return "Goodbye / logoff"
        case .bulletinList: return "Bulletin list"
        case .messageHeader: return "Message area header"
        case .fileHeader: return "File area header and list"
        case .doorMenu: return "Door games menu"
        case .ad: return "ANSI ad"
        case .loading: return "Loading / transition"
        case .custom: return "Other (your own file name)"
        }
    }
}
