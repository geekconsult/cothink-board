# Implementation decisions

- Scope: a local native macOS board, a stdio MCP server, and JSON import/export. No network server or cloud sync.
- Data: a versioned Board contains notes, connections and visual groups. The store validates geometry and connection endpoints at its boundary.
- Concurrency: both processes use a file lock for transactions and revisions for optimistic conflict detection. Mutations are atomic board replacements, so an agent batch is one undo step.
- History: the local store retains snapshots for undo and redo and records actor and revision. A board export contains current state only.
- Access: a read-only MCP process is configured with an environment variable. Local process access is not an authentication system.
- Delivery: Swift Package Manager builds the application and server. A script assembles an unsigned app bundle for local use.
- Verification: `swift test` checks persistence, JSON round-trip, conflicts, undo, redo and validation. `scripts/test-mcp.py` exercises the server over real stdio with an isolated store. Native UI validation is reported separately.
- Architect evaluation: the requested cross-family design arena is unavailable with the current model access. This design is a single-team decision, not a cross-family verdict.

- Appearance: the supplied transparent mascot is bundled as the app icon and sidebar logo. The toolbar offers system, light, and dark appearances. Native Liquid Glass is used on supported macOS releases and system materials provide the fallback. Note text is chosen against its fill color for contrast.
