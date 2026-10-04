import Foundation

// A parameter CustomWordApplier binds into its SQL statements.
nonisolated enum CustomWordSQLValue {
    case int(Int64)
    case text(String)
}
