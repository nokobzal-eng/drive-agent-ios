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
            "get_team_board",
            "Read the user's team board: employees with area, role, phone, weekly schedule, history and last review, and every task with id, kind, date, done or open, location, assignee, the recommended employee and why, and details. Call it for anything about the team, employees, the work schedule, daily tasks, who should do a task or who is closest to a place.",
            []
        ),
        tool(
            "update_team_task",
            "Mark a team task done or open again (e.g. 'דני סיים את ההתקנה בחיפה'). Daily tasks are marked for today, weekly ones for this week. Get the task id from get_team_board first.",
            [("task_id", str("The task id from get_team_board (e.g. 't3k9')")), ("status", enumProp(["done", "open"]))]
        ),
        tool(
            "save_employee",
            "Add an employee to the user's team, or update one. Use when the user describes an employee ('תוסיף עובד…', 'דני עובד גם בשישי', 'הטלפון של יוסי…'). Fill only what the user said; leave other fields empty, which keeps what's already saved. Schedule values: hours like '07:00-16:00', or 'חופש'.",
            [
                ("name", str("Employee's name as the user says it.")),
                ("role", str("Role / trade, or empty.")),
                ("area", str("Where they live or usually work (city / area), or empty.")),
                ("phone", str("Phone number, or empty.")),
                ("notes", str("Other important details (skills, car, certifications), or empty.")),
                ("schedule", scheduleProp),
            ]
        ),
        tool(
            "add_team_task",
            "Add a task to the team board and assign it. kind: 'daily' (every day), 'weekly' (once a week) or 'once' (a dated job). If the user didn't say who, recommend the best employee from get_team_board (area, load, role), assign them, and say why in one short sentence.",
            [
                ("title", str("What has to be done, short and clear, in Hebrew.")),
                ("assignee", str("Employee's name exactly as on the board; '*' for the whole team (everyone gets their own copy); or empty.")),
                ("kind", enumProp(["once", "daily", "weekly"])),
                ("date", str("For 'once': YYYY-MM-DD (empty = today). Empty for daily / weekly.")),
                ("location", str("Place, or empty.")),
                ("details", str("Extra details, or empty.")),
            ]
        ),
        tool(
            "remove_team_task",
            "Delete a task from the team board (the user asked to remove or cancel it). Get the id from get_team_board.",
            [("task_id", str("The task id."))]
        ),
        tool(
            "add_employee_record",
            "Record a bonus, an upgrade (raise, promotion, training) or a note on an employee's card.",
            [
                ("name", str("Employee's name as on the board.")),
                ("type", enumProp(["bonus", "upgrade", "note"])),
                ("text", str("What it is, e.g. 'בונוס 500 ש\"ח על פרויקט חיפה'.")),
            ]
        ),
        tool(
            "review_employee",
            "Write a professional review of an employee from their data (tasks, completion, history): summary, strengths, what to improve and a recommendation. Saved on their card. Takes about half a minute. Tell the user the gist only, in two or three short sentences.",
            [("name", str("Employee's name as on the board."))]
        ),
        tool(
            "open_team_dashboard",
            "Show the team page on the phone's screen (work schedule, tasks by employee, employee cards).",
            []
        ),
        tool(
            "stop_drive_mode",
            "Turn off drive mode when the user asks to stop / finish / turn off the assistant.",
            []
        ),
    ]

    private static let scheduleProp: JSON = {
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var properties: JSON = [:]
        for d in days { properties[d] = str("Hours or 'חופש', or empty.") }
        return [
            "type": "object",
            "description": "Work hours per day, Sunday first; empty string for days not mentioned.",
            "properties": properties,
            "required": days,
            "additionalProperties": false,
        ]
    }()

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
