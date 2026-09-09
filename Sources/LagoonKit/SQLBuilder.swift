import PostgresNIO

public struct ParameterizedQuery {
    public let sql: String
    public let parameters: [PostgresNIO.PostgresData]
}

public enum SQLBuilder {
    public static func select(
        _ columns: String,
        from table: String,
        where clause: String,
        orderBy: String? = nil,
        limit: Int? = nil,
        parameters: [PostgresNIO.PostgresData]
    ) -> ParameterizedQuery {
        var sql = "SELECT \(columns) FROM \(table) WHERE \(clause)"
        if let orderBy { sql += " ORDER BY \(orderBy)" }
        if let limit { sql += " LIMIT \(limit)" }
        return ParameterizedQuery(sql: sql, parameters: parameters)
    }
}