import Foundation
import CryptoKit

/// Blowfish в объёме, нужном `bcrypt_pbkdf` (OpenBSD): им OpenSSH выводит ключ из фразы-пароля SSH-ключа.
/// Системных реализаций нет — код повторяет bcrypt_pbkdf.c/blowfish.c, проверяется ключами от `ssh-keygen`.
struct Blowfish {
    private var p = Blowfish.initialP
    private var s0 = Blowfish.initialS[0]
    private var s1 = Blowfish.initialS[1]
    private var s2 = Blowfish.initialS[2]
    private var s3 = Blowfish.initialS[3]

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        ((s0[Int(x >> 24)] &+ s1[Int(x >> 16 & 0xff)]) ^ s2[Int(x >> 8 & 0xff)]) &+ s3[Int(x & 0xff)]
    }

    func encipher(_ l: inout UInt32, _ r: inout UInt32) {
        var xl = l ^ p[0]
        var xr = r
        var i = 1
        while i <= 16 {
            xr ^= f(xl) ^ p[i]
            xl ^= f(xr) ^ p[i + 1]
            i += 2
        }
        l = xr ^ p[17]
        r = xl
    }

    /// Слово из 4 байт по кругу — как Blowfish_stream2word.
    static func streamWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            word = word << 8 | UInt32(data[position])
            position += 1
        }
        return word
    }

    /// Blowfish_expandstate: ключ и соль вместе.
    mutating func expand(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamWord(key, &j) }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        func next() {
            l ^= Self.streamWord(data, &j)
            r ^= Self.streamWord(data, &j)
            encipher(&l, &r)
        }
        for i in stride(from: 0, to: 18, by: 2) {
            next()
            p[i] = l
            p[i + 1] = r
        }
        for k in stride(from: 0, to: 256, by: 2) { next(); s0[k] = l; s0[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { next(); s1[k] = l; s1[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { next(); s2[k] = l; s2[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { next(); s3[k] = l; s3[k + 1] = r }
    }

    /// Blowfish_expand0state: только ключ.
    mutating func expand0(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamWord(key, &j) }
        var l: UInt32 = 0, r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            encipher(&l, &r)
            p[i] = l
            p[i + 1] = r
        }
        for k in stride(from: 0, to: 256, by: 2) { encipher(&l, &r); s0[k] = l; s0[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { encipher(&l, &r); s1[k] = l; s1[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { encipher(&l, &r); s2[k] = l; s2[k + 1] = r }
        for k in stride(from: 0, to: 256, by: 2) { encipher(&l, &r); s3[k] = l; s3[k + 1] = r }
    }
}

enum BcryptPBKDF {
    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    /// bcrypt_hash: 32 байта из SHA-512 пароля и соли.
    static func hash(_ sha2pass: [UInt8], _ sha2salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expand(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0(key: sha2salt)
            state.expand0(key: sha2pass)
        }
        var j = 0
        var cdata = (0..<8).map { _ in Blowfish.streamWord(magic, &j) }
        for _ in 0..<64 {
            for block in 0..<4 {
                var l = cdata[2 * block], r = cdata[2 * block + 1]
                state.encipher(&l, &r)
                cdata[2 * block] = l
                cdata[2 * block + 1] = r
            }
        }
        // Слова выводятся младшим байтом вперёд — особенность оригинала, без неё ключи не совпадут.
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(cdata[i] >> 24 & 0xff)
            out[4 * i + 2] = UInt8(cdata[i] >> 16 & 0xff)
            out[4 * i + 1] = UInt8(cdata[i] >> 8 & 0xff)
            out[4 * i] = UInt8(cdata[i] & 0xff)
        }
        return out
    }

    static func derive(password: [UInt8], salt: [UInt8], length: Int, rounds: Int) -> [UInt8]? {
        guard rounds >= 1, length >= 1, length <= 1024, !salt.isEmpty, salt.count <= 1 << 20 else { return nil }
        let stride = (length + 32 - 1) / 32
        var amount = (length + stride - 1) / stride
        let sha2pass = Array(SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            let countSalt = salt + [UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)]
            var tmp = hash(sha2pass, Array(SHA512.hash(data: countSalt)))
            var out = tmp
            for _ in 1..<max(rounds, 1) {
                // До 65 536 раундов — это минуты: проверку ключа, которую уже не ждут, не доводим до конца.
                if Task.isCancelled { return nil }
                tmp = hash(sha2pass, Array(SHA512.hash(data: tmp)))
                for i in 0..<out.count { out[i] ^= tmp[i] }
            }
            amount = min(amount, remaining)
            var i = 0
            while i < amount {
                let dest = i * stride + Int(count - 1)
                if dest >= length { break }
                key[dest] = out[i]
                i += 1
            }
            remaining -= i
            count += 1
        }
        return key
    }
}
