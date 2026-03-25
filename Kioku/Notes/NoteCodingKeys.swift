import Foundation
import Combine

enum NoteCodingKeys: String, CodingKey {
    case id
    case title
    case content
    case segments
    case createdAt
    case modifiedAt
    case audioAttachmentID
}
