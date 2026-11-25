import Foundation

/// Decides whether a spoken answer to "לשלוח?" is a yes. Anything unclear is not a yes.
enum CommandMatcher {
    private static let exactYes = Set(["כן", "כן כן", "בטח", "שלח", "תשלח", "כן שלח", "כן תשלח", "בטח שלח"])
    private static let exactNo = Set([
        "לא", "לא לא", "עצור", "בטל", "תבטל", "אל תשלח", "לא לשלוח",
        "התעלם", "תתעלם", "דלג", "תדלג",
    ])
    private static let yesWords = Set([
        "כן", "יאפ", "יפ", "יס", "בטח", "ברור", "בוודאי", "בהחלט", "כמובן", "סבבה", "אחלה", "מעולה",
        "מושלם", "יופי", "נכון", "בדיוק", "טוב", "בסדר", "אוקיי", "אוקי", "או קיי", "יאללה", "קדימה",
        "סגור", "מאשר", "מאשרת", "מאושר", "אישור", "שלח", "תשלח", "שלחי", "תשלחי", "לשלוח", "שגר",
        "תשגר", "חייג", "תחייג", "תתקשר", "תסגור", "תרשום", "תשמור", "לך על זה", "תעשה את זה",
        "ok", "okay", "yes", "yep", "yeah", "sure",
    ])
    private static let notYesWords = Set([
        "לא", "אל", "אסור", "עזוב", "די", "בטל", "תבטל", "ביטול", "עצור", "תעצור", "רגע", "חכה",
        "תחכה", "אולי", "תשנה", "שנה", "no", "wait",
    ])
    private static let cancelPhrases = [
        "אל תשלח", "אל תשלחי", "לא לשלוח", "לא תשלח", "לא לענות", "אל תענה", "לא תענה", "לא צריך",
        "אין צורך", "לא עכשיו", "שכח מזה", "תשכח מזה", "תתעלם", "התעלם", "תעזוב", "עזוב את זה",
        "בטל את זה", "תבטל את זה", "אל תעשה", "תעצור",
    ]
    private static let cancelStarters = Set([
        "עצור", "תעצור", "די", "עזוב", "תעזוב", "בטל", "תבטל", "ביטול", "התעלם", "תתעלם", "דלג",
        "תדלג", "שכח", "תשכח", "סטופ", "stop",
    ])
    /// Requests to hear or change the text, even when they contain a word like "בסדר".
    private static let otherCommands = [
        "תקריא שוב", "תקריא עוד פעם", "עוד פעם", "שוב", "תחזור", "תקריא בשפת המקור", "בשפת המקור",
        "שפת המקור", "תקריא במקור", "נסח מחדש", "תנסח מחדש", "נסח שוב", "תנסח שוב", "מחדש",
    ]

    private static let maxCancelWords = 5
    private static let maxLooseWords = 4
    private static let maxYesWords = 6

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[\\p{P}\\p{S}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func confirm(_ utterance: String) -> Bool {
        let text = normalize(utterance)
        if text.isEmpty { return false }
        if exactYes.contains(text) { return true }
        if exactNo.contains(text) || isCancel(text) { return false }
        let words = text.split(separator: " ").map(String.init)
        let padded = " \(text) "
        if words.count <= maxLooseWords, otherCommands.contains(where: { padded.contains(" \($0) ") }) {
            return false
        }
        return isAffirmative(words)
    }

    private static func isCancel(_ text: String) -> Bool {
        let padded = " \(text) "
        if cancelPhrases.contains(where: { padded.contains(" \($0) ") }) { return true }
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        if first == "לא" && words.count <= 2 { return true }
        return words.count <= maxCancelWords && cancelStarters.contains(first)
    }

    private static func isAffirmative(_ words: [String]) -> Bool {
        guard !words.isEmpty, words.count <= maxYesWords else { return false }
        // "ולא", "שלא": a Hebrew prefix letter on a no-word still counts as no.
        let stripped = words.map { word -> String in
            if word.count > 2, let first = word.first, "ושבלה".contains(first) { return String(word.dropFirst()) }
            return word
        }
        if words.contains(where: notYesWords.contains) || stripped.contains(where: notYesWords.contains) {
            return false
        }
        let padded = " " + words.joined(separator: " ") + " "
        return yesWords.contains { yes in
            yes.contains(" ") ? padded.contains(" \(yes) ") : words.contains(yes)
        }
    }
}

enum WakeWord {
    /// What was said after the wake word: nil if it wasn't said, empty if nothing followed it.
    static func request(in utterance: String, wake: String) -> String? {
        let words = CommandMatcher.normalize(utterance).split(separator: " ").map(String.init)
        let target = CommandMatcher.normalize(wake).split(separator: " ").map(String.init)
        guard !target.isEmpty, words.count >= target.count else { return nil }
        for start in 0...(words.count - target.count) {
            let window = Array(words[start..<(start + target.count)])
            guard matches(window[0], target[0]), Array(window.dropFirst()) == Array(target.dropFirst()) else {
                continue
            }
            return words[(start + target.count)...].joined(separator: " ")
        }
        return nil
    }

    /// The first wake word may carry one Hebrew prefix letter, as in "ושלומי" or "השלומי".
    private static func matches(_ word: String, _ target: String) -> Bool {
        if word == target { return true }
        guard word.count == target.count + 1, let first = word.first, "ושהלבמכ".contains(first) else {
            return false
        }
        return String(word.dropFirst()) == target
    }
}
