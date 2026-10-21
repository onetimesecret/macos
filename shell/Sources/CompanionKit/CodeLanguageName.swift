import Foundation

/// The name a source language shows in menus and labels.
///
/// Language ids are lower case (`javascript`, `sql`); `capitalized`
/// turns them into Javascript and Sql. The table carries the names
/// their communities write, and an id it does not know falls back to
/// the capitalised form.
public enum CodeLanguageName {
    private static let names: [String: String] = [
        "javascript": "JavaScript",
        "typescript": "TypeScript",
        "sql": "SQL",
        "json": "JSON",
        "yaml": "YAML",
        "toml": "TOML",
        "html": "HTML",
        "css": "CSS",
        "php": "PHP",
        "csharp": "C#",
        "cpp": "C++",
        "objc": "Objective-C",
        "objective-c": "Objective-C",
        "graphql": "GraphQL",
        "xml": "XML",
        "yml": "YAML",
    ]

    public static func display(_ language: String) -> String {
        names[language.lowercased()] ?? language.capitalized
    }
}
