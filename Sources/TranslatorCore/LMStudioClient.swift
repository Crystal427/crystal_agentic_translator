import Foundation

public struct HTTPPayload: Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol LMStudioTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPPayload
    func stream(_ request: URLRequest) -> AsyncThrowingStream<String, Error>
}

public struct URLSessionTransport: LMStudioTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            return HTTPPayload(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        throw LMStudioError.http(status: code, message: "LM Studio returned HTTP \(code).")
                    }
                    var lineBytes: [UInt8] = []
                    var dataLines: [String] = []
                    func processLine() {
                        if lineBytes.last == 0x0D { lineBytes.removeLast() }
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(dataLines.joined(separator: "\n"))
                                dataLines.removeAll(keepingCapacity: true)
                            }
                        } else if line.hasPrefix("data:") {
                            var value = String(line.dropFirst(5))
                            if value.first == " " { value.removeFirst() }
                            dataLines.append(value)
                        }
                    }
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 0x0A { processLine() }
                        else { lineBytes.append(byte) }
                    }
                    try Task.checkCancellation()
                    if !lineBytes.isEmpty { processLine() }
                    if !dataLines.isEmpty { continuation.yield(dataLines.joined(separator: "\n")) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

public enum LMStudioError: Error, LocalizedError, Sendable {
    case invalidBaseURL
    case http(status: Int, message: String)
    case emptyCompletion
    case insufficientContext(required: Int, available: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Enter a valid LM Studio server URL."
        case .http(let status, let message): return "LM Studio HTTP \(status): \(message)"
        case .emptyCompletion: return "The model returned no text."
        case .insufficientContext(let required, let available): return "The prompt requires about \(required) tokens, but the context budget is \(available). Reduce the chunk size or increase the context length."
        case .invalidResponse: return "LM Studio returned an unreadable response."
        }
    }
}

public struct LoadedModelInstance: Decodable, Sendable {
    public var id: String
    public var config: ModelConfiguration
}

public struct ModelConfiguration: Decodable, Sendable {
    public var contextLength: Int?
    enum CodingKeys: String, CodingKey { case contextLength = "context_length" }
}

public struct LMStudioModel: Decodable, Identifiable, Sendable {
    public var key: String
    public var displayName: String
    public var type: String
    public var loadedInstances: [LoadedModelInstance]
    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, type
        case displayName = "display_name"
        case loadedInstances = "loaded_instances"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? key
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "llm"
        loadedInstances = try container.decodeIfPresent([LoadedModelInstance].self, forKey: .loadedInstances) ?? []
    }
}

public struct ChatResult: Sendable {
    public var content: String
    public var reasoning: String
    public var finishReason: String?
    public var promptTokens: Int
    public var completionTokens: Int

    public init(content: String, reasoning: String, finishReason: String?, promptTokens: Int = 0, completionTokens: Int = 0) {
        self.content = content
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct LMStudioClient: Sendable {
    public var baseURL: String
    public var apiToken: String
    private let transport: any LMStudioTransport

    public init(baseURL: String, apiToken: String = "", transport: any LMStudioTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.transport = transport
    }

    public func models() async throws -> [LMStudioModel] {
        let response = try await request(path: "/api/v1/models", method: "GET")
        struct ModelList: Decodable { var models: [LMStudioModel] }
        return try JSONDecoder().decode(ModelList.self, from: response.data).models
    }

    @discardableResult
    public func load(model: String, contextLength: Int) async throws -> String {
        let response = try await request(path: "/api/v1/models/load", method: "POST", body: ["model": model, "context_length": contextLength])
        struct LoadResult: Decodable { var instanceID: String; enum CodingKeys: String, CodingKey { case instanceID = "instance_id" } }
        return try JSONDecoder().decode(LoadResult.self, from: response.data).instanceID
    }

    public func unload(instanceID: String) async throws {
        _ = try await request(path: "/api/v1/models/unload", method: "POST", body: ["instance_id": instanceID])
    }

    public func chat(
        model: String,
        prompt: ChatPrompt,
        temperature: Double,
        maxTokens: Int,
        contextLength: Int,
        reasoningEffort: String? = nil,
        responseSchema: [String: Any]? = nil,
        onDelta: (@Sendable (String, String) -> Void)? = nil
    ) async throws -> ChatResult {
        let promptEstimate = estimateTokens(prompt.system + "\n" + prompt.user)
        let available = contextLength - promptEstimate - 256
        guard available >= 512 else { throw LMStudioError.insufficientContext(required: promptEstimate + 512, available: contextLength) }
        let boundedTokens = min(maxTokens, available)
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user]
            ],
            "temperature": temperature,
            "max_tokens": boundedTokens,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        if let responseSchema { body["response_format"] = ["type": "json_schema", "json_schema": responseSchema] }
        let request = try makeRequest(path: "/v1/chat/completions", method: "POST", body: body)
        var content = ""
        var reasoning = ""
        var finishReason: String?
        var promptTokens = 0
        var completionTokens = 0
        for try await event in transport.stream(request) {
            try Task.checkCancellation()
            if event == "[DONE]" { break }
            guard let data = event.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let usage = object["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
            }
            guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { continue }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let value = delta["content"] as? String, !value.isEmpty {
                content += value
                onDelta?("content", value)
            }
            let thinking = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            if let thinking, !thinking.isEmpty {
                reasoning += thinking
                onDelta?("reasoning", thinking)
            }
        }
        try Task.checkCancellation()
        if content.isEmpty { throw LMStudioError.emptyCompletion }
        return ChatResult(content: content, reasoning: reasoning, finishReason: finishReason, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    public func testConnection() async throws -> [LMStudioModel] { try await models() }

    private func request(path: String, method: String, body: [String: Any]? = nil) async throws -> HTTPPayload {
        let request = try makeRequest(path: path, method: method, body: body)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: response.data, encoding: .utf8) ?? "Request failed"
            throw LMStudioError.http(status: response.statusCode, message: message)
        }
        return response
    }

    private func makeRequest(path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let root = URL(string: baseURL), let url = URL(string: path, relativeTo: root)?.absoluteURL else { throw LMStudioError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiToken.isEmpty { request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func estimateTokens(_ text: String) -> Int {
        TranslationTextMetrics.estimatedTokens(text)
    }
}

public enum ModelScheduler {
    public static func prepare(role: String, settings: AppSettings, client: LMStudioClient) async throws {
        let isController = role == "controller"
        let requestedModel = isController ? settings.controllerModel : settings.translatorModel
        let contextLength = isController ? settings.controllerContext : settings.translatorContext
        let models = try await client.models()
        if settings.modelStrategy == .swap {
            let otherModel = isController ? settings.translatorModel : settings.controllerModel
            if otherModel != requestedModel {
                let otherInstances = models.first(where: { $0.key == otherModel })?.loadedInstances ?? []
                for instance in otherInstances { try await client.unload(instanceID: instance.id) }
            }
        }
        let instances = models.first(where: { $0.key == requestedModel })?.loadedInstances ?? []
        if instances.contains(where: { ($0.config.contextLength ?? 0) >= contextLength }) { return }
        for instance in instances { try await client.unload(instanceID: instance.id) }
        try await client.load(model: requestedModel, contextLength: contextLength)
    }
}
