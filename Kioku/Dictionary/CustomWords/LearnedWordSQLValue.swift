import Foundation

// A parameter LearnedWordApplier binds into its SQL statements.
nonisolated enum LearnedWordSQLValue {
    case int(Int64)
    case text(String)
}
