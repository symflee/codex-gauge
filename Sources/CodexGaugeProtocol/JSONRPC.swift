import Foundation

public enum JSONRPCIdentifier: Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)
    case null
}

public struct JSONRPCFailure: Equatable, Sendable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }
}

public enum JSONRPCResponsePayload: Equatable, Sendable {
    case result(JSONValue)
    case failure(JSONRPCFailure)
}

public struct JSONRPCResponse: Equatable, Sendable {
    public let id: JSONRPCIdentifier
    public let payload: JSONRPCResponsePayload

    public init(id: JSONRPCIdentifier, payload: JSONRPCResponsePayload) {
        self.id = id
        self.payload = payload
    }
}

public struct JSONRPCNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

public struct JSONRPCRequest: Equatable, Sendable {
    public let id: JSONRPCIdentifier
    public let method: String
    public let params: JSONValue?

    public init(
        id: JSONRPCIdentifier,
        method: String,
        params: JSONValue?
    ) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONRPCMessage: Equatable, Sendable {
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)
    case request(JSONRPCRequest)
}

public enum JSONRPCDecodingError: Error, Equatable, Sendable {
    case malformedJSON
    case invalidEnvelope
}

public struct JSONRPCMessageDecoder: Sendable {
    public init() {}

    public func decode(_ line: Data) throws -> JSONRPCMessage {
        let value = try decodeJSON(line)
        guard let object = value.objectValue else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        return try classify(object)
    }

    private func decodeJSON(_ line: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw JSONRPCDecodingError.malformedJSON
        }
    }

    private func classify(
        _ object: [String: JSONValue]
    ) throws -> JSONRPCMessage {
        guard let methodValue = object["method"] else {
            return try response(from: object)
        }
        guard let method = methodValue.stringValue else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        return try methodMessage(method: method, object: object)
    }

    private func methodMessage(
        method: String,
        object: [String: JSONValue]
    ) throws -> JSONRPCMessage {
        guard object["result"] == nil, object["error"] == nil else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        guard let identifierValue = object["id"] else {
            return .notification(
                JSONRPCNotification(method: method, params: object["params"])
            )
        }
        let identifier = try identifier(from: identifierValue)
        return .request(
            JSONRPCRequest(
                id: identifier,
                method: method,
                params: object["params"]
            )
        )
    }

    private func response(
        from object: [String: JSONValue]
    ) throws -> JSONRPCMessage {
        guard let identifierValue = object["id"] else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        let identifier = try identifier(from: identifierValue)
        let payload = try responsePayload(from: object)
        return .response(JSONRPCResponse(id: identifier, payload: payload))
    }

    private func responsePayload(
        from object: [String: JSONValue]
    ) throws -> JSONRPCResponsePayload {
        let result = object["result"]
        let error = object["error"]
        guard (result == nil) != (error == nil) else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        if let result {
            return .result(result)
        }
        guard let error else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        return .failure(try failure(from: error))
    }

    private func failure(from value: JSONValue) throws -> JSONRPCFailure {
        guard
            let object = value.objectValue,
            let codeValue = object["code"],
            let code = integer(from: codeValue)
        else {
            throw JSONRPCDecodingError.invalidEnvelope
        }
        return JSONRPCFailure(code: code)
    }

    private func identifier(
        from value: JSONValue
    ) throws -> JSONRPCIdentifier {
        switch value {
        case let .integer(identifier):
            .integer(identifier)
        case let .string(identifier):
            .string(identifier)
        case .null:
            .null
        default:
            throw JSONRPCDecodingError.invalidEnvelope
        }
    }

    private func integer(from value: JSONValue) -> Int? {
        guard let rawValue = value.integerValue else {
            return nil
        }
        return Int(exactly: rawValue)
    }
}
