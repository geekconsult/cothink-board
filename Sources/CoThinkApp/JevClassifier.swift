import Foundation

struct JevClassifier {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let commandThreshold = 0.4

    static let boardCommandInstructions = "The user is dictating to a whiteboard app whose microphone stays on. Use an inclusive interpretation: count as a board command any speech that is about working on this board, including direct instructions to create, edit, move, group, connect, restyle, or delete notes, groups, or connections, or reorganize the board, in any language. Also count brainstorming, planning, questions about what to put on a board or note, and details, background, ideas, requirements, examples, or constraints that could be used to create or improve a board or note. The user does not need to explicitly say create, add, or make, and the board or note does not need to exist yet. When unsure, count plausible board-related context as a command. Only classify speech as not a board command when it is clearly unrelated, such as greetings, general small talk, side conversations with other people, or questions and thinking aloud unrelated to board work."

    let apiKey: String

    static func isCommand(noul: Double) -> Bool {
        noul >= commandThreshold
    }

    static func requestBody(utterance: String) -> [String: Any] {
        [
            "state": utterance,
            "model": "jev-latest",
            "questions": [
                "is_board_command": [
                    "type": "noul",
                    "instructions": boardCommandInstructions,
                ],
            ],
        ]
    }

    static func parseNoul(_ data: Data) throws -> Double {
        struct Response: Decodable {
            struct Answers: Decodable {
                struct Answer: Decodable {
                    let noul: Double
                }
                let isBoardCommand: Answer
                enum CodingKeys: String, CodingKey { case isBoardCommand = "is_board_command" }
            }
            let answers: Answers
        }
        return try JSONDecoder().decode(Response.self, from: data).answers.isBoardCommand.noul
    }

    func classify(utterance: String) async -> (isCommand: Bool, filterActive: Bool, error: String?) {
        guard !apiKey.isEmpty else { return (isCommand: true, filterActive: false, error: nil) }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.requestBody(utterance: utterance))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return (isCommand: true, filterActive: true, error: "Jev HTTP \(http.statusCode)")
            }
            let noul = try Self.parseNoul(data)
            return (isCommand: Self.isCommand(noul: noul), filterActive: true, error: nil)
        } catch {
            return (isCommand: true, filterActive: true, error: error.localizedDescription)
        }
    }
}
