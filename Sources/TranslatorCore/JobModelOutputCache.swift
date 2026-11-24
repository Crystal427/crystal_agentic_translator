import Foundation

public struct JobModelOutput: Equatable, Sendable {
    public var activity: String
    public var controllerReasoning: String
    public var controllerOutput: String
    public var translator: String

    public init(activity: String = "", controllerReasoning: String = "", controllerOutput: String = "", translator: String = "") {
        self.activity = activity
        self.controllerReasoning = controllerReasoning
        self.controllerOutput = controllerOutput
        self.translator = translator
    }
}

public struct JobModelOutputCache: Sendable {
    private var outputs: [UUID: JobModelOutput] = [:]

    public init() {}

    public func output(for jobID: UUID?) -> JobModelOutput {
        jobID.flatMap { outputs[$0] } ?? JobModelOutput()
    }

    public func activity(for jobID: UUID, fallback: String) -> String {
        let activity = outputs[jobID]?.activity ?? ""
        return activity.isEmpty ? fallback : activity
    }

    public mutating func setActivity(jobID: UUID, text: String) {
        var output = outputs[jobID] ?? JobModelOutput()
        output.activity = text
        outputs[jobID] = output
    }

    public mutating func begin(jobID: UUID, role: String) {
        var output = outputs[jobID] ?? JobModelOutput()
        if role == "主控" {
            output.controllerReasoning = ""
            output.controllerOutput = ""
        } else {
            output.translator = ""
        }
        outputs[jobID] = output
    }

    public mutating func append(jobID: UUID, role: String, kind: String, text: String) {
        var output = outputs[jobID] ?? JobModelOutput()
        if role == "主控" {
            if kind == "reasoning" {
                output.controllerReasoning += text
            } else {
                output.controllerOutput += text
            }
        } else {
            output.translator += text
        }
        outputs[jobID] = output
    }

    public mutating func remove(jobID: UUID) {
        outputs.removeValue(forKey: jobID)
    }
}
