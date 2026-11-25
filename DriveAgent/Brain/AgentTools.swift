import Foundation

/// Claude tool definitions. Tools that act on the outside world confirm by voice inside the app
/// before doing anything; Claude cannot skip that.
enum AgentTools {
    static let definitions: [JSON] = [
        tool(
            "get_calendar",
            "Read the user's calendar. Call this for anything about their schedule, meetings, appointments or plans for a day, week or month.",
            [("period", enumProp(["today", "tomorrow", "week", "month"]))]
        ),
        tool(
            "add_calendar_event",
            "Put something in the user's calendar: a meeting, appointment, call, errand or task at a day/time. Work out the exact date and time from the current date in your context. The app reads it back and asks for a quick yes before adding.",
            [
                ("title", str("Short title in Hebrew.")),
                ("start", str("Local start date-time, ISO format: 'YYYY-MM-DDTHH:MM' (or 'YYYY-MM-DD' for an all-day item).")),
                ("duration_minutes", ["type": "integer", "description": "Length in minutes (default 60; 0 for all-day)."]),
                ("location", str("Place, or empty.")),
            ]
        ),
        tool(
            "send_whatsapp",
            "Prepare a WhatsApp message to one of the user's contacts. Use exactly the words the user said, minus the instruction to you. Never add greetings, closings, names, emojis, details or anything else they didn't say, unless they explicitly asked you to compose it. The app reads it to the user and, after a yes, opens the chat with the text typed. The message is NOT sent until the user taps send in WhatsApp.",
            [
                ("contact", str("The contact as the user said it, without a 'ל' prefix.")),
                ("message", str("The full message text, in Hebrew unless the user asked otherwise.")),
            ]
        ),
        tool(
            "call_contact",
            "Phone one of the user's contacts. The app confirms with the user before dialing, and iOS then asks for one tap to place the call.",
            [("contact", str("The contact as the user said it, without a 'ל' prefix."))]
        ),
        tool(
            "ask_user",
            "Ask the user one short question out loud and get their spoken answer. Use when a necessary detail is missing. Don't use it to ask permission to send: the tools already confirm.",
            [("question", str("The question, short, in Hebrew."))]
        ),
        tool(
            "stop_drive_mode",
            "Turn off drive mode when the user asks to stop / finish / turn off the assistant.",
            []
        ),
    ]

    private static func str(_ description: String) -> JSON {
        ["type": "string", "description": description]
    }

    private static func enumProp(_ values: [String]) -> JSON {
        ["type": "string", "enum": values]
    }

    private static func tool(_ name: String, _ description: String, _ props: [(String, JSON)]) -> JSON {
        var properties: JSON = [:]
        for (key, value) in props { properties[key] = value }
        let schema: JSON = [
            "type": "object",
            "properties": properties,
            "required": props.map { $0.0 },
            "additionalProperties": false,
        ]
        return ["name": name, "description": description, "input_schema": schema]
    }
}
