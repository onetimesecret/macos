import Foundation

/// The name a source language shows in menus and labels.
///
/// Language ids are the detector's slugs (`CodeInk.detectorLanguageRenderers`)
/// and are lower case; `capitalized` turns them into Javascript, Sql
/// and Objectivec. The table names every slug the registry can emit
/// as its community writes it, and `CodeLanguageNameTests` walks the
/// registry so a Betlang upgrade's new slug is a decision here, not a
/// capitalised accident. An id outside the registry falls back to the
/// capitalised form.
public enum CodeLanguageName {
    static let names: [String: String] = [
        "asm": "Assembly",
        "batch": "Batch",
        "c": "C",
        "clojure": "Clojure",
        "cmake": "CMake",
        "cobol": "COBOL",
        "cpp": "C++",
        "cs": "C#",
        "css": "CSS",
        "dart": "Dart",
        "dockerfile": "Dockerfile",
        "elixir": "Elixir",
        "erlang": "Erlang",
        "gemfile": "Gemfile",
        "gemspec": "Gemspec",
        "go": "Go",
        "gradle": "Gradle",
        "groovy": "Groovy",
        "haskell": "Haskell",
        "html": "HTML",
        "ini": "INI",
        "java": "Java",
        "javascript": "JavaScript",
        "json": "JSON",
        "julia": "Julia",
        "kotlin": "Kotlin",
        "lisp": "Lisp",
        "lua": "Lua",
        "markdown": "Markdown",
        "objectivec": "Objective-C",
        "ocaml": "OCaml",
        "perl": "Perl",
        "php": "PHP",
        "powershell": "PowerShell",
        "python": "Python",
        "r": "R",
        "ruby": "Ruby",
        "rust": "Rust",
        "scala": "Scala",
        "shell": "Shell",
        "sql": "SQL",
        "swift": "Swift",
        "toml": "TOML",
        "typescript": "TypeScript",
        "vba": "VBA",
        "verilog": "Verilog",
        "xml": "XML",
        "yaml": "YAML",
    ]

    /// Fence spellings of the registry's uncoloured languages, which
    /// `CodeInk.aliases` cannot carry since every alias there names a
    /// token scanner.
    static let fenceSpellings: [String: String] = [
        "objc": "objectivec",
        "objective-c": "objectivec",
        "csharp": "cs",
        "c#": "cs",
    ]

    /// A fence's own spelling (`yml`, `js`, `objc`) reaches the registry
    /// through the fences' aliases and the table above, so the banner
    /// for a ```` ```yml ```` reads YAML. Only a spelling none of them
    /// knows is capitalised.
    public static func display(_ language: String) -> String {
        let id = language.lowercased()
        let slug = CodeInk.aliases[id] ?? fenceSpellings[id] ?? id
        return names[slug] ?? language.capitalized
    }
}
