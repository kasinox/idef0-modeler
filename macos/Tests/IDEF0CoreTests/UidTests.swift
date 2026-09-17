// `uid()` — the identifier shape shared with src/util.js.
//
// An id is what the ontology toolkit joins on, so its random tail is fixed
// width and 64 bits wide: ids minted in separate processes in the same
// millisecond do not collide, and no two (part, part) pairs can spell one
// string. The literal ids are not golden-pinned — every regeneration re-rolls
// the sample's — so only the shape is checked here.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("Identifiers")
struct UidTests {
    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    @Test("An id is prefix_, the base-36 milliseconds, then exactly 16 lower-case hex digits")
    func shape() throws {
        let before = Self.nowMs()
        let id = uid("gl")
        let after = Self.nowMs()
        #expect(id.hasPrefix("gl_"))
        let body = id.dropFirst(3)
        #expect(body.count > 16)
        let tail = body.suffix(16)
        #expect(tail.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let ms = try #require(Int64(body.dropLast(16), radix: 36))
        #expect(ms >= before && ms <= after)
        #expect(uid().hasPrefix("id_"))
    }

    @Test("The tail is zero-padded, so ids of one prefix share a length; ten thousand in a burst are distinct")
    func fixedWidthAndDistinct() {
        var seen = Set<String>()
        var lengths = Set<Int>()
        for _ in 0..<10_000 {
            let id = uid("bx")
            seen.insert(id)
            lengths.insert(id.count)
        }
        #expect(seen.count == 10_000)
        // With 10 000 draws, a tail beginning in "0" is a near certainty; padding
        // keeps it 16 digits wide all the same.
        #expect(lengths.count == 1, "\(lengths)")
    }
}
