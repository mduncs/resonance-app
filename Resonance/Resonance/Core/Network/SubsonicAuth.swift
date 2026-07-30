import Foundation
import CryptoKit

struct SubsonicAuth: Sendable {
    let username: String
    private let password: String

    /// Raw password access for native API authentication
    var rawPassword: String { password }

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func authParameters() -> [String: String] {
        let salt = randomSalt(length: 12)
        let token = md5(password + salt)

        return [
            "u": username,
            "t": token,
            "s": salt,
            "v": "1.16.1",
            "c": "Resonance",
            "f": "json"
        ]
    }

    private func randomSalt(length: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
