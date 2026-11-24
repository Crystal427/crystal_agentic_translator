import Foundation

public struct JobModelOutput: Equatable, Sendable {
    public var activity: String
    public var controllerReasoning: String
    public var controllerOutput: String
    public var isControllerOutputInProgress: Bool
    public var translator: String

    public init(activity: String = "", controllerReasoning: String = "", controllerOutput: String = "", isControllerOutputInProgress: Bool = false, translator: String = "") {
        self.activity = activity
        self.controllerReasoning = controllerReasoning
        self.controllerOutput = controllerOutput
        self.isControllerOutputInProgress = isControllerOutputInProgress
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
        if isController(role) {
            output.controllerReasoning = ""
            output.controllerOutput = ""
            output.isControllerOutputInProgress = true
        } else {
            output.translator = ""
        }
        outputs[jobID] = output
    }

    public mutating func append(jobID: UUID, role: String, kind: String, text: String) {
        var output = outputs[jobID] ?? JobModelOutput()
        if isController(role) {
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

    public mutating func completeController(jobID: UUID) {
        var output = outputs[jobID] ?? JobModelOutput()
        output.isControllerOutputInProgress = false
        outputs[jobID] = output
    }

    public mutating func remove(jobID: UUID) {
        outputs.removeValue(forKey: jobID)
    }

    private func isController(_ role: String) -> Bool {
        ["主控", "预读", "审校"].contains(role)
    }
}
