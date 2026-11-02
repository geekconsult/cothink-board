# CoThink Board

CoThink Board is a local macOS idea board with a native SwiftUI interface and a stdio MCP server. The app and MCP server use the same data store. Board changes carry a revision, so a stale edit is rejected rather than overwriting another change.

## Build and open

Requirements: macOS 14 or later and Xcode with the Swift toolchain.

```sh
./scripts/build-app.sh
open 'dist/CoThink Board.app'
```

The build is local and unsigned. macOS may ask for approval on first launch. The app stores its database and history in `~/Library/Application Support/CoThinkBoard/`. Export a board as JSON for backups or sharing. Import creates a separate board with a new board ID. Exported JSON contains the current board, not its undo or attribution history.

Use the appearance menu in the toolbar to choose System, Light, or Dark. macOS 26 and later use native Liquid Glass on primary controls; older supported macOS versions use translucent system material. Use the buttons at either end of the toolbar to show or hide the boards sidebar and inspector. Their states persist between launches. The keyboard shortcuts are Option-Command-1 and Option-Command-2. Double-click the canvas to add a note, or use the Note button. Double-click a note or group title to edit its text directly on the canvas; text saves automatically. Click another object or an empty canvas position to hide the inspector. Double-click a connection to edit its relationship label, direction, and appearance. Connections support one-way arrows, two-way arrows, or no arrows.

Each board has a **Files** library. Add images, PDFs, or other files and choose that board's storage folder; by default files go in `~/Library/Application Support/CoThinkBoard/Projects/<board-id>/`. From a note's inspector, choose **Attach from Project** to add file links to the note. Click a linked image, PDF, or document on the note to open it with the macOS default app. The library can change folders and carries its files to the new location. Board JSON stores file metadata and relative paths, not file contents; keep the project folder with the JSON when sharing or moving a board.

Drag notes or groups to move them. Select one and drag any corner handle to resize it. The inspector adjusts fill color, border or line color, width, and solid, dashed, or dotted style. Select a note and drag its arrow handle onto another note to connect them. You can also choose Connect, then select another note. Drag across empty canvas to select notes without creating a group. Choose Group to group the selection, or choose Group first and then drag a rectangle to create a group. Notes whose centers fall inside a group-drawing rectangle become locked members. Dragging the group or any member moves all members together. Select a member and choose Unlock from group in the inspector to move it independently. To lock notes in an existing group, select it and choose Lock notes inside group in the inspector. The board refreshes periodically when another process changes it. A rejected stale edit displays an error and reloads the current board.

## Connect an MCP client

Build the app first. The MCP button in the toolbar shows a copyable client configuration. Configure the client to start the bundled executable using an absolute path. This example points to a local build. Replace the path with the actual location of the application.

```json
{
  "mcpServers": {
    "cothink": {
      "command": "/absolute/path/CoThink Board.app/Contents/MacOS/cothink-mcp",
      "env": {
        "COTHINK_MCP_ACTOR": "my-agent"
      }
    }
  }
}
```

Set `COTHINK_MCP_READ_ONLY` to `1` to reject write tools for that MCP process. This is client configuration, not a security boundary against other local processes. `COTHINK_HOME` overrides the storage directory for both the app and server; they must use the same value to see the same boards.

Use `list_boards` or `get_board` to obtain the current board and revision. `get_board_context` returns a graph-oriented view linking every note to its groups, connections, labels, directions, positions, and attached files; this helps an agent reason over the board as a connected canvas. `read_project_file` accepts an asset ID from that board and returns image data, extracted PDF or text content, or an embedded resource for other file types. `read_note_image` returns an image attached directly to a note through the older image attachment field. PDF scans without selectable text are returned as page images (up to eight). Reads are limited to registered project assets inside the board's project folder and files up to 50 MB. Use `unlock_note` to remove a note from its groups without deleting the note. `edit_board` applies a list of note, group, connection, asset, or title edits as one undoable change. Notes reference board files by `assetIDs`; asset records contain an ID, display name, and path relative to the board's `projectFilesPath`. Use `add_project_file` with a local `source_path` to copy a file into the board library and optionally attach it to a note. The MCP process must have permission to read that path. Connection objects support `label` and `direction` (`oneWay`, `twoWay`, or `none`). The client supplies item IDs and complete item objects for additions. `replace_board` accepts a full board. Mutations against an existing board require `expected_revision`, including delete, undo and redo. Read the board again after a conflict. The server exposes schemas and operation details through `tools/list`.

## Verification

```sh
swift test
python3 scripts/test-mcp.py
```

## Current limitations

The canvas has a fixed extent. Groups created by dragging include notes whose centers fall inside the selection. Existing groups without member IDs remain visual background shapes until you choose Lock notes inside group in the inspector. There is no multi-selection, semantic search tool, or in-app agent permission management. Sidebar search filters boards by board title or note text but does not highlight matching notes. The MCP process can be configured read-only but the app does not authenticate local processes. Undo and redo operate on the board's shared history, not separate per-user histories. Change attribution is available in the inspector and through `board_history`. The app has not been notarized or packaged as a signed distribution.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New note | Command-N |
| New board | Shift-Command-N |
| New group | Shift-Command-G |
| Connect selected note, then click target | Command-L |
| Zoom in / out | Command-plus / Command-minus |
| Zoom with trackpad | Pinch in / out over the canvas |
| Actual size | Command-0 |
| Delete selected object (while the canvas has focus) | Delete |
| Delete selected object from the menu | Shift-Command-Delete |
| Undo / redo | Command-Z / Shift-Command-Z |
| Show or hide boards | Option-Command-1 |
| Show or hide inspector | Option-Command-2 |
| Export board | Shift-Command-E |
| Cancel connection | Escape |
