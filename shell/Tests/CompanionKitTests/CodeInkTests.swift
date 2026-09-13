import Foundation
import XCTest

@testable import CompanionKit

/// The fenced block's four colors, read the way a person reads them.
///
/// Pure, no view: the tokenizer is UI-adjacent logic extracted into a
/// value, which is the shell's pattern for anything a test would
/// otherwise have to mock AppKit to reach. Every golden below is a
/// block of source and the spans it colors, written out so a reader
/// can check the claim by eye.
final class CodeInkTests: XCTestCase {
    /// A whole block's tokens, rendered as `kind:text` per line. The
    /// text is pulled back out through the token's own range, so a
    /// golden that reads right is also proof the offsets landed on the
    /// characters they name.
    private func ink(_ language: String?, _ source: String) -> [[String]] {
        let lines = source.components(separatedBy: "\n")
        let tokens = CodeInk.tokens(language: language, lines: lines)
        return zip(lines, tokens).map { line, tokens in
            let text = line as NSString
            return tokens.map { "\($0.kind.rawValue):\(text.substring(with: $0.range))" }
        }
    }

    private func ink(_ tokens: [CodeInk.Token], of line: String) -> [String] {
        let text = line as NSString
        return tokens.map { "\($0.kind.rawValue):\(text.substring(with: $0.range))" }
    }

    // MARK: - The table

    /// The v1 twelve, asserted as a golden so that adding a language is
    /// a deliberate line in two places rather than a quiet one.
    func testTheTableIsTheTwelveLanguagesOfVersionOne() {
        XCTAssertEqual(
            Set(CodeInk.specs.keys),
            [
                "swift", "rust", "python", "ruby", "javascript", "typescript",
                "go", "shell", "sql", "json", "yaml", "toml",
            ]
        )
    }

    /// An alias is a promise that a nickname resolves to a spec. A
    /// nickname pointing at a language nobody wrote is a fence that
    /// silently loses its color, so the promise is checked here rather
    /// than discovered on a page.
    func testEveryAliasNamesALanguageInTheTable() {
        for (nickname, language) in CodeInk.aliases {
            XCTAssertNotNil(CodeInk.specs[language], "\(nickname) points at nothing")
        }
    }

    /// Betlang 0.1.1 can return exactly these 48 labels. Each must have
    /// an explicit rendering decision: the existing twelve select their
    /// scanner; every other label remains itself and renders as uncolored
    /// fixed-width code.
    func testEveryBetlangLabelHasAnExplicitRendererMapping() {
        let expected: [String: String] = [
            "asm": "asm", "batch": "batch", "c": "c", "clojure": "clojure",
            "cmake": "cmake", "cobol": "cobol", "cpp": "cpp", "cs": "cs",
            "css": "css", "dart": "dart", "dockerfile": "dockerfile", "elixir": "elixir",
            "erlang": "erlang", "gemfile": "gemfile", "gemspec": "gemspec", "go": "go",
            "gradle": "gradle", "groovy": "groovy", "haskell": "haskell", "html": "html",
            "ini": "ini", "java": "java", "javascript": "javascript", "json": "json",
            "julia": "julia", "kotlin": "kotlin", "lisp": "lisp", "lua": "lua",
            "markdown": "markdown", "objectivec": "objectivec", "ocaml": "ocaml", "perl": "perl",
            "php": "php", "powershell": "powershell", "python": "python", "r": "r",
            "ruby": "ruby", "rust": "rust", "scala": "scala", "shell": "shell",
            "sql": "sql", "swift": "swift", "toml": "toml", "typescript": "typescript",
            "vba": "vba", "verilog": "verilog", "xml": "xml", "yaml": "yaml",
        ]
        XCTAssertEqual(expected.count, 48)
        XCTAssertEqual(CodeInk.detectorLanguageRenderers, expected)

        for (label, renderer) in expected {
            XCTAssertEqual(CodeInk.renderingLanguage(ofInfoString: label), renderer, label)
            XCTAssertEqual(CodeInk.spec(forInfoString: label) != nil, CodeInk.specs[renderer] != nil, label)
        }
        XCTAssertNil(CodeInk.renderingLanguage(ofInfoString: "brainfuck"))
    }

    func testNicknamesResolveToTheirLanguage() {
        let expected = [
            "js": "javascript", "jsx": "javascript", "node": "javascript",
            "ts": "typescript", "tsx": "typescript",
            "py": "python", "rb": "ruby", "rs": "rust",
            "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell",
            "yml": "yaml", "golang": "go", "psql": "sql", "sqlite": "sql",
        ]
        for (nickname, language) in expected {
            XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: nickname), language, nickname)
        }
        // A canonical name is its own nickname.
        for language in CodeInk.specs.keys {
            XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: language), language)
        }
    }

    /// An info string is whatever follows the backticks, and people put
    /// more than a language there. Only the first token is read, and it
    /// is lowercased first, because a fence saying `Swift` means swift.
    func testOnlyTheFirstTokenOfTheInfoStringNamesTheLanguage() {
        XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: "js title=main.js"), "javascript")
        XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: "Swift"), "swift")
        XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: "YAML"), "yaml")
        XCTAssertEqual(CodeInk.canonicalLanguage(ofInfoString: "   py   "), "python")
        XCTAssertNil(CodeInk.canonicalLanguage(ofInfoString: "   "))
        XCTAssertNil(CodeInk.canonicalLanguage(ofInfoString: ""))
        XCTAssertNil(CodeInk.canonicalLanguage(ofInfoString: nil))
        XCTAssertEqual(CodeInk.renderingLanguage(ofInfoString: "Kotlin"), "kotlin")
    }

    /// The whole position on guessing, in one test. A bare fence, a
    /// language nobody listed and an info string that is a filename all
    /// render exactly as they did before this file existed.
    func testAnUnknownLanguageYieldsNoTokensAtAll() {
        let source = """
            // a comment
            let count = 42
            """
        for language in [nil, "", "text", "brainfuck", "main.swift", "  "] {
            XCTAssertEqual(ink(language, source), [[], []], "\(language ?? "nil") guessed")
            XCTAssertFalse(CodeInk.Tokenizer(language: language).recognizesLanguage)
        }
        XCTAssertTrue(CodeInk.Tokenizer(language: "swift").recognizesLanguage)
    }

    // MARK: - Goldens, one language at a time

    func testSwiftReadsAsKeywordsCommentsStringsAndNumbers() {
        XCTAssertEqual(
            ink(
                "swift",
                """
                // build the sheet
                let count = 42
                guard let name = title else { return }
                """
            ),
            [
                ["comment:// build the sheet"],
                ["keyword:let", "number:42"],
                ["keyword:guard", "keyword:let", "keyword:else", "keyword:return"],
            ]
        )
    }

    /// Rust's single quote spells a lifetime, not a string. Taking it
    /// as a delimiter would paint the rest of every line that holds a
    /// borrow, so the table gives Rust the double quote alone and this
    /// is the line that proves it.
    func testRustLifetimesAreNotStrings() {
        XCTAssertEqual(
            ink(
                "rust",
                """
                fn label<'a>(name: &'a str) -> u8 {
                    let mask = 0xff;
                    "done".len() as u8
                }
                """
            ),
            [
                ["keyword:fn"],
                ["keyword:let", "number:0xff"],
                ["string:\"done\"", "keyword:as"],
                [],
            ]
        )
    }

    func testPythonReadsItsHashComments() {
        XCTAssertEqual(
            ink(
                "python",
                """
                def halve(x):  # by two
                    return x / 2
                """
            ),
            [
                ["keyword:def", "comment:# by two"],
                ["keyword:return", "number:2"],
            ]
        )
    }

    func testRubyReadsItsWordsAndQuotes() {
        XCTAssertEqual(
            ink(
                "ruby",
                """
                def call
                  puts 'hi' unless done?
                end
                """
            ),
            [
                ["keyword:def"],
                ["string:'hi'", "keyword:unless"],
                ["keyword:end"],
            ]
        )
    }

    /// A template literal is JavaScript's multiline string, so the
    /// backtick is in the table as one. Inside a markdown fence it is
    /// safe: a fence rule is three or more backticks at the head of a
    /// line, and this is one in the middle of an expression.
    func testJavaScriptTemplateLiteralsAreStrings() {
        XCTAssertEqual(
            ink(
                "javascript",
                """
                const url = `/sheet/${id}`; // one
                """
            ),
            [["keyword:const", "string:`/sheet/${id}`", "comment:// one"]]
        )
    }

    func testTypeScriptAddsItsOwnReservedWords() {
        XCTAssertEqual(
            ink(
                "typescript",
                """
                export interface Row { id: number }
                const first: Row = { id: 1 }
                """
            ),
            [
                ["keyword:export", "keyword:interface"],
                ["keyword:const", "number:1"],
            ]
        )
    }

    func testGoReadsItsDeclarations() {
        XCTAssertEqual(
            ink(
                "go",
                """
                package main // entry
                var ratio = 3.5
                """
            ),
            [
                ["keyword:package", "comment:// entry"],
                ["keyword:var", "number:3.5"],
            ]
        )
    }

    func testShellReadsItsControlWords() {
        XCTAssertEqual(
            ink(
                "shell",
                """
                if [ -n "$HOME" ]; then
                  export PORT=8080  # listen here
                fi
                """
            ),
            [
                ["keyword:if", "string:\"$HOME\"", "keyword:then"],
                ["keyword:export", "number:8080", "comment:# listen here"],
                ["keyword:fi"],
            ]
        )
    }

    /// SQL is the one language in the table whose reserved words are
    /// case-blind, and uppercase is how most people write them. The
    /// doubled quote is SQL's escape rather than a backslash, so
    /// `'o''brien'` reads as two string spans; they sit flush against
    /// each other, so the literal is one unbroken run of color and the
    /// difference never reaches the eye.
    func testSqlKeywordsAreCaseBlind() {
        XCTAssertEqual(
            ink(
                "sql",
                """
                SELECT * FROM sheets -- all of them
                where name = 'o''brien' AND id > 10;
                """
            ),
            [
                ["keyword:SELECT", "keyword:FROM", "comment:-- all of them"],
                ["keyword:where", "string:'o'", "string:'brien'", "keyword:AND", "number:10"],
            ]
        )
    }

    func testJsonColorsItsKeysValuesAndLiterals() {
        XCTAssertEqual(
            ink("json", #"{"port": 8080, "debug": true, "note": null}"#),
            [[
                "string:\"port\"", "number:8080",
                "string:\"debug\"", "keyword:true",
                "string:\"note\"", "keyword:null",
            ]]
        )
    }

    /// YAML gets three keywords and no more. A plain scalar is unquoted
    /// prose, so a wider list would color words in the middle of
    /// somebody's sentence.
    func testYamlKeepsItsKeywordListShort() {
        XCTAssertEqual(
            ink(
                "yaml",
                """
                # config
                name: onetimepad   # trailing
                debug: true
                port: 8080
                """
            ),
            [
                ["comment:# config"],
                ["comment:# trailing"],
                ["keyword:true"],
                ["number:8080"],
            ]
        )
    }

    func testTomlReadsItsSeparatedNumbers() {
        XCTAssertEqual(
            ink(
                "toml",
                """
                [server]
                port = 8_080  # listen
                name = "pad"
                """
            ),
            [
                [],
                ["number:8_080", "comment:# listen"],
                ["string:\"pad\""],
            ]
        )
    }

    // MARK: - Comments

    /// A `#` is one character wide and turns up inside URLs, colors and
    /// anchors, so it opens a comment only at the head of a line or
    /// after whitespace, which is the rule shell and YAML both keep.
    /// A two-character opener is distinctive enough to stand anywhere.
    func testAOneCharacterCommentOpenerNeedsWhitespaceBeforeIt() {
        XCTAssertEqual(ink("yaml", "docs: https://example.com#anchor"), [[]])
        XCTAssertEqual(ink("yaml", "docs: value #anchor"), [["comment:#anchor"]])
        XCTAssertEqual(ink("shell", "#!/bin/sh"), [["comment:#!/bin/sh"]])
        XCTAssertEqual(
            ink("swift", "let a = 1//half"),
            [["keyword:let", "number:1", "comment://half"]]
        )
    }

    /// The reason this scans line by line with state rather than line
    /// by line alone: an open `/*` means the next line is not what it
    /// locally looks like, and the line after that one is not either.
    func testABlockCommentSpansLinesUntilItCloses() {
        XCTAssertEqual(
            ink(
                "swift",
                """
                let a = 1 /* opens here
                "not a string" and let is not a keyword

                */ let b = 2
                """
            ),
            [
                ["keyword:let", "number:1", "comment:/* opens here"],
                ["comment:\"not a string\" and let is not a keyword"],
                [],
                ["comment:*/", "keyword:let", "number:2"],
            ]
        )
    }

    /// A block comment that never closes holds to the last line of the
    /// region, the same reading `FenceScanner` gives an unterminated
    /// fence: a page mid-paste is not second-guessed back into code.
    func testAnUnclosedBlockCommentHoldsToTheEndOfTheBlock() {
        XCTAssertEqual(
            ink(
                "rust",
                """
                /* opens
                let x = 1;
                let y = 2;
                """
            ),
            [["comment:/* opens"], ["comment:let x = 1;"], ["comment:let y = 2;"]]
        )
    }

    // MARK: - Strings

    /// A backslash hides the character after it, including the quote
    /// that would otherwise close the string. Written as a raw literal
    /// so the source under test reads exactly as it would on the page.
    func testAnEscapedQuoteDoesNotCloseAString() {
        XCTAssertEqual(
            ink("swift", #"let s = "a \" b" + "c""#),
            [["keyword:let", #"string:"a \" b""#, "string:\"c\""]]
        )
    }

    /// A quote left open at end of line closes there. It is nearly
    /// always a typo mid-edit, and carrying it would paint the rest of
    /// the block red for the length of one keystroke.
    func testAnUnterminatedSingleLineStringDoesNotLeakToTheNextLine() {
        XCTAssertEqual(
            ink(
                "swift",
                """
                let a = "oops
                let b = 2
                """
            ),
            [
                ["keyword:let", "string:\"oops"],
                ["keyword:let", "number:2"],
            ]
        )
    }

    /// The other half of the carried state: a `"""` is meant to run
    /// past end of line, so everything until its close is string, and
    /// a `#` inside it is text rather than a comment.
    func testAMultilineStringSpansLinesUntilItCloses() {
        XCTAssertEqual(
            ink(
                "python",
                """
                doc = \"\"\"line one
                still inside # not a comment
                \"\"\"
                x = 1
                """
            ),
            [
                ["string:\"\"\"line one"],
                ["string:still inside # not a comment"],
                ["string:\"\"\""],
                ["number:1"],
            ]
        )
    }

    // MARK: - Numbers and words

    func testNumberLiteralsTakeTheirWholeSelfAndNothingElse() {
        XCTAssertEqual(
            ink("rust", "let v = [0xff, 0b1010, 1_000, 3.14, 1e9, 2.5e-3, 42];"),
            [[
                "keyword:let", "number:0xff", "number:0b1010", "number:1_000",
                "number:3.14", "number:1e9", "number:2.5e-3", "number:42",
            ]]
        )
    }

    /// Half a colored word reads as a bug in the editor, so a run of
    /// characters that begins with a digit and ends in letters is a
    /// word rather than a number, and a digit inside an identifier was
    /// never a literal to begin with.
    func testADigitInsideAWordIsNotANumber() {
        XCTAssertEqual(ink("swift", "let row1 = 1px + v2 + 0xzz"), [["keyword:let"]])
    }

    /// The radix prefix is the one number rule the table varies, so a
    /// shell script counts `0xff` as a word: nothing in a shell writes
    /// hexadecimal, and coloring it would be a claim about a language
    /// this file does not make.
    func testOnlyCStyleLanguagesReadARadixPrefix() {
        XCTAssertEqual(ink("shell", "n=0xff"), [[]])
        XCTAssertEqual(ink("shell", "n=8080"), [["number:8080"]])
    }

    /// The keyword rule in one test: a word is taken whole and then
    /// asked, never scanned for a prefix. Otherwise `format` would
    /// carry the color of `for` and every camel-cased name would too.
    func testKeywordsMatchWholeWordsOnly() {
        XCTAssertEqual(
            ink(
                "swift",
                """
                format
                forEach
                for_each
                myfor
                $for
                for
                """
            ),
            [[], [], [], [], [], ["keyword:for"]]
        )
    }

    // MARK: - State

    /// A tokenizer belongs to one fence region. It is made at the
    /// opening rule and reset there, so a comment or a quote left open
    /// at the end of one block can never color the block below it,
    /// which is the same discipline `FenceScanner` keeps about fences.
    func testStateDoesNotLeakPastAReset() {
        let opener = "/* opens and never closes"
        var tokenizer = CodeInk.Tokenizer(language: "swift")
        XCTAssertEqual(
            ink(tokenizer.tokens(in: opener), of: opener),
            ["comment:/* opens and never closes"]
        )
        // Without the reset the next line belongs to the comment above.
        var leaked = tokenizer
        XCTAssertEqual(
            ink(leaked.tokens(in: "let x = 1"), of: "let x = 1"),
            ["comment:let x = 1"]
        )

        tokenizer.reset()
        XCTAssertEqual(
            ink(tokenizer.tokens(in: "let x = 1"), of: "let x = 1"),
            ["keyword:let", "number:1"]
        )
    }

    func testAnOpenMultilineStringIsForgottenAtAReset() {
        var tokenizer = CodeInk.Tokenizer(language: "python")
        _ = tokenizer.tokens(in: "doc = \"\"\"opens")
        tokenizer.reset()
        XCTAssertEqual(ink(tokenizer.tokens(in: "x = 1"), of: "x = 1"), ["number:1"])
    }

    /// Every region gets its own tokenizer, so two blocks in the same
    /// page are read independently even when the first one is left
    /// mid-comment.
    func testTwoBlocksAreReadIndependently() {
        XCTAssertEqual(ink("swift", "/* opens"), [["comment:/* opens"]])
        XCTAssertEqual(ink("swift", "let x = 1"), [["keyword:let", "number:1"]])
    }

    // MARK: - Offsets

    /// Ranges are UTF-16 offsets because `NSTextStorage` counts that
    /// way. An accented letter is one character and one unit, an emoji
    /// is one character and two, and a scan that counted characters
    /// would put the color a unit or two to the left of the word it
    /// belongs to. The line is written with escapes so the expected
    /// numbers cannot drift on a composed-versus-decomposed accent.
    func testRangesAreUtf16OffsetsOnALineWithNonAsciiCharacters() {
        let line = "let caf\u{e9} = \"na\u{ef}ve \u{1F642}\""
        var tokenizer = CodeInk.Tokenizer(language: "swift")
        let tokens = tokenizer.tokens(in: line)

        // Twenty characters, twenty-one units: the emoji is one
        // character and two units, so a character-counting scan would
        // stop the string a unit short of its closing quote.
        XCTAssertEqual(line.count, 20)
        XCTAssertEqual((line as NSString).length, 21)

        XCTAssertEqual(
            tokens,
            [
                CodeInk.Token(range: NSRange(location: 0, length: 3), kind: .keyword),
                CodeInk.Token(range: NSRange(location: 11, length: 10), kind: .string),
            ]
        )
        XCTAssertEqual(
            ink(tokens, of: line),
            ["keyword:let", "string:\"na\u{ef}ve \u{1F642}\""]
        )
    }

    /// The other side of the same coin: a word carrying an accent is
    /// one word, so a keyword-shaped prefix of it colors nothing.
    func testAnAccentedWordIsOneWord() {
        XCTAssertEqual(ink("swift", "let caf\u{e9} = 1"), [["keyword:let", "number:1"]])
        // `forêt` opens with the keyword `for` and is not one.
        XCTAssertEqual(ink("swift", "for\u{ea}t"), [[]])
    }

    /// An emoji ahead of the code shifts every offset after it, which
    /// is exactly the case a character-counting scan gets wrong.
    func testAnEmojiShiftsTheOffsetsThatFollowIt() {
        let line = "\u{1F642} let x = 1"
        var tokenizer = CodeInk.Tokenizer(language: "swift")
        XCTAssertEqual(
            tokenizer.tokens(in: line),
            [
                CodeInk.Token(range: NSRange(location: 3, length: 3), kind: .keyword),
                CodeInk.Token(range: NSRange(location: 11, length: 1), kind: .number),
            ]
        )
    }
}
