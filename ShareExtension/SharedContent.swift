import Foundation

// What the host app handed to the share sheet: selected text, a link, or nothing readable. Pure data.
struct SharedContent {
    let text: String?
    let url: String?
}
