import Foundation

public enum DictionarySQLiteError: Error {
    case databaseNotFound(name: String)
    case openDatabase(message: String)
    case prepareStatement(sql: String, message: String)
    case bindParameter(message: String)
    case step(message: String)
}
