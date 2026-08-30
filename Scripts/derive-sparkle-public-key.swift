import CryptoKit
import Darwin
import Foundation

func fail() -> Never {
    fputs("invalid Sparkle EdDSA private seed\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 1 else {
    fail()
}

let encodedData = FileHandle.standardInput.readDataToEndOfFile()
guard let encodedSeed = String(data: encodedData, encoding: .utf8),
      let seed = Data(base64Encoded: encodedSeed),
      seed.count == 32,
      seed.base64EncodedString() == encodedSeed,
      let privateKey = try? Curve25519.Signing.PrivateKey(
        rawRepresentation: seed
      ) else {
    fail()
}

let encodedPublicKey = privateKey.publicKey.rawRepresentation.base64EncodedData()
FileHandle.standardOutput.write(encodedPublicKey)
