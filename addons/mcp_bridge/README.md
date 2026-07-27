# mcp_bridge

Self-contained addon that lets an external MCP host remote-control
Material Maker:

```
Material Maker (this addon)  <--JSON-lines/TCP-->  mcp_bridge_host (Python)  <--stdio-->  MCP client / LLM
```

The addon is loaded as an **autoload** (one line in `project.godot`) and
touches no other core files. At runtime it injects an "MCP" menu into the
main window's menu bar (start/stop server, status display).

## Protocol

TCP server on `127.0.0.1:8765` (override with `--mcp-port=<port>`).
One JSON object per line, both directions:

- Request:  `{ "action": "...", "args": {...}, "id": <optional> }`
- Response: `{ "ok": true, "result": ..., "id": ... }` or
            `{ "ok": false, "error": "...", "id": ... }`

Handlers may be async (`await`) — the dispatcher awaits
`GDScriptFunctionState` results before responding.

## Actions

Discovery is part of the protocol, so MCP clients can work with a small
fixed tool set (`mm_list_actions`, `mm_describe`, `mm_call` on the host
side) instead of one tool per feature:

- `ping`, `version` — connectivity / version info
- `list_actions` — all actions with signatures, descriptions and
  implementation status
- `describe` — topics: `actions`, `action` (name=...), `node_types`
  (category=...), `node_type` (name=...)
- `list_node_types` / `describe_node_type` — node type catalog from
  `material_maker/library/base.json` and `mm_loader.predefined_generators`
  (`.mmg` definitions, compacted to doc-relevant keys)

Material tool skeletons (registered, return "not implemented yet"; see
the TODO comments in `mcp_bridge.gd` for the exact engine anchors):
`get_graph`, `new_material`, `load_material`, `save_material`,
`add_node`, `remove_node`, `connect_nodes`, `disconnect_nodes`,
`set_parameter`, `get_parameter`, `render_node`, `export_material`,
`render_variations`.

## Adding a new action

```gdscript
register_action("my_action", _action_my_action, "Short description.",
    [ { name = "some_arg", type = "string", required = true } ])

func _action_my_action(args : Dictionary):
    if not args.has("some_arg"):
        return _error("missing argument 'some_arg'")
    return { result = ... }   # or: return _error("message")
```

Return `_error(...)` for failures; any other return value becomes
`result` in an `{ ok = true }` response. No change on the Python host
side is needed — the action is automatically visible via `list_actions`
and callable via `mm_call`.

## Host side

See the separate `mcp_bridge_host` project (not part of this repo) for
the Python MCP server that talks to this addon.
