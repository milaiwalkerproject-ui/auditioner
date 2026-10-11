import Foundation
import CryptoKit

/// The nonce that ties one Sign in with Apple request to the token Apple returns.
/// The app sends Apple `sha256Hex(raw)`; Apple puts that in the identity token; the app sends the
/// raw nonce to our server, which hashes it the same way and compares (see backend/app/accounts.py).
enum AccountNonce {
    /// A fresh random nonce: 32 random bytes as 64 lowercase hex characters.
    static func random(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return hex(bytes)
    }

    /// SHA-256 of the UTF-8 bytes of `text`, as 64 lowercase hex characters.
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return hex(Array(digest))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        var out: String = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out += String(format: "%02x", byte)
        }
        return out
    }
}
