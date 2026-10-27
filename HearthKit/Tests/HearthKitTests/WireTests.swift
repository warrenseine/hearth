import Testing
import Foundation
@testable import HearthKit

@Suite("HTTP/1.1 and WebSocket wire format")
struct WireTests {
    @Test("waits for the full Content-Length body")
    func contentLength() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{\"a\":".utf8)
        #expect(try HTTPWire.parseResponse(partial, atEOF: false) == nil)
        let full = partial + Data("true}".utf8)
        let response = try #require(try HTTPWire.parseResponse(full, atEOF: false))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"a\":true}")
    }

    @Test("decodes a chunked body split across chunks")
    func chunked() throws {
        let raw = Data("HTTP/1.1 400 Bad Request\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let response = try #require(try HTTPWire.parseResponse(raw, atEOF: false))
        #expect(response.status == 400)
        #expect(String(decoding: response.body, as: UTF8.self) == "hello world")
        let truncated = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8)
        #expect(try HTTPWire.parseResponse(truncated, atEOF: false) == nil)
        #expect(throws: PCError.self) { try HTTPWire.parseResponse(truncated, atEOF: true) }
    }

    @Test("takes everything until EOF when there is no length")
    func untilEOF() throws {
        let raw = Data("HTTP/1.1 200 OK\r\n\r\nabc".utf8)
        #expect(try HTTPWire.parseResponse(raw, atEOF: false) == nil)
        #expect(try HTTPWire.parseResponse(raw, atEOF: true)?.body == Data("abc".utf8))
    }

    @Test("encodes the token header and a zero-length body for bodiless POSTs")
    func requestEncoding() {
        let text = String(decoding: HTTPWire.encodeRequest(method: "POST", path: "/process/start/web", token: "secret", body: nil), as: UTF8.self)
        #expect(text.hasPrefix("POST /process/start/web HTTP/1.1\r\n"))
        #expect(text.contains("X-PC-Token-Key: secret\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("parses server frames split and coalesced across reads, including 16-bit lengths")
    func frameParsing() throws {
        func serverFrame(_ opcode: UInt8, _ payload: Data, fin: Bool = true) -> Data {
            var d = Data([(fin ? 0x80 : 0) | opcode])
            if payload.count < 126 { d.append(UInt8(payload.count)) } else {
                d.append(126); d.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
            }
            return d + payload
        }
        let big = Data(repeating: 0x61, count: 300)
        let stream = serverFrame(1, Data("hi".utf8)) + serverFrame(1, big) + serverFrame(9, Data())
        var parser = WebSocketWire.Parser()
        var frames: [WebSocketWire.Frame] = []
        // Feed one byte at a time to exercise every partial-header path.
        for byte in stream {
            parser.append(Data([byte]))
            while let frame = try parser.next() { frames.append(frame) }
        }
        #expect(frames.count == 3)
        #expect(frames[0] == .init(fin: true, opcode: .text, payload: Data("hi".utf8)))
        #expect(frames[1].payload == big)
        #expect(frames[2].opcode == .ping)
    }

    @Test("masks client frames so the server can unmask them back")
    func clientMasking() throws {
        let payload = Data("pong-me".utf8)
        let frame = WebSocketWire.encodeClientFrame(opcode: .pong, payload: payload)
        #expect(frame[0] == 0x8A)
        #expect(frame[1] & 0x80 != 0)
        var parser = WebSocketWire.Parser()
        parser.append(frame)
        #expect(try parser.next()?.payload == payload)
    }
}
