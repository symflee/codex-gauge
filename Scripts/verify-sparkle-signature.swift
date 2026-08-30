import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    fputs("Sparkle signature verification failed: \(message)\n", stderr)
    exit(1)
}

func canonicalBase64(_ value: String, byteCount: Int) -> Data? {
    guard let data = Data(base64Encoded: value),
          data.count == byteCount,
          data.base64EncodedString() == value else {
        return nil
    }
    return data
}

func signedData(at path: String, byteCount: Int?) -> Data? {
    guard let data = try? Data(
        contentsOf: URL(fileURLWithPath: path),
        options: .mappedIfSafe
    ) else {
        return nil
    }
    guard let byteCount else {
        return data
    }
    guard byteCount > 0, byteCount <= data.count else {
        return nil
    }
    return Data(data.prefix(byteCount))
}

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 5 else {
    fail("usage: verify-sparkle-signature <file> <signature> <public-key> [length]")
}

let signedByteCount = arguments.count == 5 ? Int(arguments[4]) : nil
guard arguments.count == 4 || signedByteCount != nil,
      let signature = canonicalBase64(arguments[2], byteCount: 64),
      let publicKeyData = canonicalBase64(arguments[3], byteCount: 32),
      let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyData
      ),
      let data = signedData(at: arguments[1], byteCount: signedByteCount),
      publicKey.isValidSignature(signature, for: data) else {
    fail("signature is invalid")
}
