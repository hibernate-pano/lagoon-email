import XCTest
@testable import LagoonServer

/// The parser is the only place IMAP wire text (untrusted) becomes structure:
/// every later layer trusts these atoms, so the edge cases here are the
/// contract.
final class IMAPResponseParserTests: XCTestCase {
    // MARK: - Line kinds

    func test_taggedOk_capturesTagAndStatus() {
        let r = IMAPResponseParser.parse(line: "A0004 OK FETCH completed")
        XCTAssertEqual(r?.kind, .tagged("A0004", .ok))
        XCTAssertEqual(r?.atoms, ["A0004", "OK", "FETCH", "completed"])
        XCTAssertEqual(r?.raw, "A0004 OK FETCH completed")
    }

    func test_taggedNo_capturesTagAndStatus() {
        let r = IMAPResponseParser.parse(line: "A1 NO [AUTHENTICATIONFAILED] Authentication failed")
        XCTAssertEqual(r?.kind, .tagged("A1", .no))
    }

    func test_taggedBad_isCaseInsensitive() {
        let r = IMAPResponseParser.parse(line: "a2 bad command error")
        XCTAssertEqual(r?.kind, .tagged("a2", .bad))
    }

    func test_untaggedExists() {
        let r = IMAPResponseParser.parse(line: "* 12 EXISTS")
        XCTAssertEqual(r?.kind, .untagged)
        XCTAssertEqual(r?.atoms, ["*", "12", "EXISTS"])
    }

    func test_continuation() {
        let r = IMAPResponseParser.parse(line: "+ Ready for literal data")
        XCTAssertEqual(r?.kind, .continuation)
    }

    func test_emptyAndWhitespaceOnly_returnNil() {
        XCTAssertNil(IMAPResponseParser.parse(line: ""))
        XCTAssertNil(IMAPResponseParser.parse(line: "   "))
        XCTAssertNil(IMAPResponseParser.parse(line: "\t"))
    }

    // MARK: - Literals

    func test_literal_isAttachedVerbatim() {
        let body = Data("hello 世界".utf8)
        let r = IMAPResponseParser.parse(
            line: "* 1 FETCH (BODY[TEXT] {12}",
            literal: body
        )
        XCTAssertEqual(r?.literal, body)
        XCTAssertEqual(r?.kind, .untagged)
    }

    func test_literalLength_synchronizingForm() {
        XCTAssertEqual(
            IMAPResponseParser.literalLength(in: "* 1 FETCH (BODY[TEXT] {256}"),
            256
        )
    }

    func test_literalLength_acceptsNonSynchronizingForm() {
        XCTAssertEqual(
            IMAPResponseParser.literalLength(in: "* 1 FETCH (BODY[TEXT] {256+}"),
            256
        )
        XCTAssertEqual(IMAPResponseParser.literalLength(in: "A2 NO"), nil)
    }

    func test_literalLength_zeroAndNonNumeric() {
        XCTAssertEqual(IMAPResponseParser.literalLength(in: "A1 OK {0}"), 0)
        XCTAssertEqual(IMAPResponseParser.literalLength(in: "A1 OK {abc}"), nil)
        XCTAssertEqual(IMAPResponseParser.literalLength(in: "A1 OK {12} trailing"), nil)
    }

    // MARK: - Atoms

    func test_quotedString_unescapesBackslashAndQuote() {
        let r = IMAPResponseParser.parse(line: #"* LIST (\HasNoChildren) "/" "Sent \"Box\"""#)
        XCTAssertEqual(
            r?.atoms,
            ["*", "LIST", #"(\HasNoChildren)"#, "/", #"Sent "Box""#]
        )
    }

    func test_backslashEscape_keepsFollowingChar() {
        let r = IMAPResponseParser.parse(line: #"A1 OK "back\\slash""#)
        XCTAssertEqual(r?.atoms.last, #"back\slash"#)
    }

    func test_unterminatedQuote_consumesRestOfLine() {
        let r = IMAPResponseParser.parse(line: #"A1 OK "never closed"#)
        XCTAssertEqual(r?.atoms.last, "never closed")
    }

    func test_nonASCII_passesThroughUntouched() {
        let r = IMAPResponseParser.parse(line: #"* LIST () "/" "收件箱""#)
        XCTAssertEqual(r?.atoms.last, "收件箱")
        XCTAssertEqual(r?.raw, #"* LIST () "/" "收件箱""#)
    }

    // MARK: - Parenthesized lists

    func test_parenthesized_flagsList() {
        XCTAssertEqual(
            IMAPResponseParser.parenthesized(#"* FLAGS (\Answered \Flagged)"#),
            [#"\Answered"#, #"\Flagged"#]
        )
    }

    func test_parenthesized_noParens_isNil() {
        XCTAssertNil(IMAPResponseParser.parenthesized(#"* OK \HasNoChildren"#))
        XCTAssertNil(IMAPResponseParser.parenthesized("A1 OK done"))
    }

    func test_parenthesized_nestedGroupStaysOneAtom() {
        XCTAssertEqual(
            IMAPResponseParser.parenthesized(#"* 1 FETCH (UID 42 FLAGS (\Seen))"#),
            ["UID", "42", "FLAGS", #"(\Seen)"#]
        )
    }

    func test_parenthesized_quotedAndNestedSection() {
        XCTAssertEqual(
            IMAPResponseParser.parenthesized(#"* 1 FETCH (BODY[HEADER.FIELDS (SUBJECT)] "收件箱")"#),
            ["BODY[HEADER.FIELDS (SUBJECT)]", "收件箱"]
        )
    }

    func test_parenthesized_emptyGroup() {
        XCTAssertEqual(IMAPResponseParser.parenthesized("* LIST ()"), [])
    }
}
