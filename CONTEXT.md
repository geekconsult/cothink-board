# CoThink Board

A native macOS board app with a shared web twin. An agent reaches the same boards as the app through an MCP server.

## Language

**Reminder**:
An Apple Reminders record. A board never owns a Reminder, it only links to one.
_Avoid_: Task, board reminder, reminder item

**Reminder Box**:
A canvas object on a board that shows one or more linked Reminders.
_Avoid_: Reminder card, reminder note

**Shared Reminder Box**:
A checklist that lives in the board itself and syncs to the web. Nothing in Apple Reminders stands behind it.
_Avoid_: Board reminder box, board-managed box, board reminder
