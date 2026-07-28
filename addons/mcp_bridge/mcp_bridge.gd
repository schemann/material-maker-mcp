extends Node
## MCP bridge for Material Maker.
##
## Runs a small JSON-lines TCP server on localhost so an external MCP host
## process (see mcp_bridge_host) can remote-control the app.
## Protocol: one JSON object per line, both directions.
##   Request:  { "action": "...", "args": {...}, "id": <optional> }
##   Response: { "ok": true, "result": ... } or { "ok": false, "error": "..." }
##
## This addon is intentionally self-contained: the only core change it needs
## is one autoload line in project.godot.

const DEFAULT_PORT : int = 8765
const HOST : String = "127.0.0.1"
const BRIDGE_VERSION : String = "0.1.0"
const LIBRARY_PATH : String = "res://material_maker/library/base.json"

var server : TCPServer
# Array of { peer: StreamPeerTCP, buffer: String }
var clients : Array = []
var actions : Dictionary = {}

var menu_button : MenuButton
var status_item_id : int = -1

# macOS global menu (DisplayServer) support
const GLOBAL_MENU : String = "_main/MCP"
var using_global_menu : bool = false
var global_menu_main_count : int = -1
var global_enabled_index : int = -1
var global_status_index : int = -1
var menu_guard_elapsed : float = 0.0

var current_port : int = 0


func _ready() -> void:
	_register_actions()
	if is_autostart_enabled():
		start_server(get_port())
	_inject_menu()


func _exit_tree() -> void:
	stop_server()


func get_port() -> int:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--mcp-port="):
			return int(arg.trim_prefix("--mcp-port="))
	if mm_globals.has_config("mcp_bridge_port"):
		return int(mm_globals.get_config("mcp_bridge_port"))
	return DEFAULT_PORT


func is_autostart_enabled() -> bool:
	if mm_globals.has_config("mcp_bridge_autostart"):
		return bool(mm_globals.get_config("mcp_bridge_autostart"))
	return true


# --- Action registry ---------------------------------------------------------

func register_action(action_name : String, handler : Callable, description : String = "", args_doc : Array = []) -> void:
	actions[action_name] = {
		handler = handler,
		description = description,
		args = args_doc,
	}


func _register_actions() -> void:
	register_action("ping", _action_ping, "Check that the bridge is alive.")
	register_action("version", _action_version, "Get Material Maker / Godot / bridge version info.")

	# --- Documentation interface -------------------------------------------------
	register_action("list_actions", _action_list_actions,
			"List all bridge actions with argument signatures, descriptions and implementation status.")
	register_action("describe", _action_describe,
			"Documentation entry point. topic: actions | action (name=...) | node_types (category=...) | node_type (name=...).",
			[ { name = "topic", type = "string", required = true }, { name = "name", type = "string" }, { name = "category", type = "string" } ])
	register_action("list_node_types", _action_list_node_types,
			"List material node types from the library, with category paths.",
			[ { name = "category", type = "string", description = "Optional category prefix filter, e.g. 'Noise'" } ])
	register_action("describe_node_type", _action_describe_node_type,
			"Full documentation of one node type: parameters (type, default, range, enum values), inputs, outputs, descriptions.",
			[ { name = "name", type = "string", required = true } ])

	# --- Material tools ------------------------------------------------------------
	# All of these operate on the current project's data layer via
	#   mm_globals.main_window.get_current_graph_edit() -> MMGraphEdit
	#     (material_maker/panels/graph_edit/graph_edit.gd)
	register_action("get_graph", _action_get_graph,
			"Serialize the current material graph (nodes, connections, parameters).")
	register_action("new_material", _action_new_material,
			"Open a new empty material project tab.")
	register_action("load_material", _action_load_material,
			"Load a .ptex material from disk into a project tab.",
			[ { name = "path", type = "string", required = true } ])
	register_action("save_material", _action_save_material,
			"Save the current material to disk.",
			[ { name = "path", type = "string" } ])
	register_action("add_node", _action_add_node,
			"Create a node of a given type in the current graph.",
			[ { name = "type", type = "string", required = true }, { name = "parameters", type = "object" }, { name = "position", type = "array" } ])
	register_action("remove_node", _action_remove_node,
			"Remove a node from the current graph.",
			[ { name = "node", type = "string", required = true } ])
	register_action("connect_nodes", _action_connect_nodes,
			"Connect an output port of one node to an input port of another.",
			[ { name = "from", type = "string", required = true }, { name = "from_port", type = "int", required = true },
			  { name = "to", type = "string", required = true }, { name = "to_port", type = "int", required = true } ])
	register_action("disconnect_nodes", _action_disconnect_nodes,
			"Remove a connection between two nodes.",
			[ { name = "from", type = "string", required = true }, { name = "from_port", type = "int" },
			  { name = "to", type = "string", required = true }, { name = "to_port", type = "int" } ])
	register_action("set_parameter", _action_set_parameter,
			"Set a parameter of a node (triggers re-render).",
			[ { name = "node", type = "string", required = true }, { name = "name", type = "string", required = true }, { name = "value", required = true } ])
	register_action("get_parameter", _action_get_parameter,
			"Get a parameter value of a node.",
			[ { name = "node", type = "string", required = true }, { name = "name", type = "string", required = true } ])
	register_action("render_node", _action_render_node,
			"Render one output of a node to an image file, return the file path.",
			[ { name = "node", type = "string", required = true }, { name = "output", type = "int" },
			  { name = "size", type = "array", description = "[width, height], default [512, 512]" },
			  { name = "path", type = "string", required = true } ])
	register_action("export_material", _action_export_material,
			"Export the current material with an export profile (textures for a target engine).",
			[ { name = "prefix", type = "string", required = true }, { name = "profile", type = "string", required = true }, { name = "size", type = "int" } ])

	# --- Skeletons (not implemented yet) -------------------------------------------
	register_action("render_variations", _action_not_implemented,
			"Batch-render variations of the current material: sweep parameter value lists and/or seeds, render/export each combination.",
			[ { name = "variations", type = "object", required = true, description = "{ node: { param: [v1, v2, ...] } }" },
			  { name = "seeds", type = "array", description = "Optional seed values to sweep" },
			  { name = "output_dir", type = "string", required = true }, { name = "size", type = "int" } ])
	# TODO: loop over parameter combinations -> set_parameter / gen.seed_int -> render_node or
	#       export_material; collect result paths. Anchors: gen_base.gd set_parameter/render_output,
	#       gen_material.gd export_material.


func _action_ping(_args : Dictionary) -> Dictionary:
	return { pong = true }


func _action_version(_args : Dictionary) -> Dictionary:
	return {
		app = "Material Maker",
		app_version = ProjectSettings.get_setting("application/config/actual_release", ""),
		godot_version = Engine.get_version_info().string,
		bridge_version = BRIDGE_VERSION,
	}


func _action_not_implemented(_args : Dictionary) -> Dictionary:
	return _error("not implemented yet (skeleton, see TODO in addons/mcp_bridge/mcp_bridge.gd)")


# --- Material tools ---------------------------------------------------------------
# Data layer anchors: MMGraphEdit (material_maker/panels/graph_edit/graph_edit.gd),
# MMGenGraph / MMGenBase (addons/material_maker/engine/nodes/), MMLoader (loader.gd).

func _get_graph_edit():
	if mm_globals.main_window == null:
		return null
	return mm_globals.main_window.get_current_graph_edit()


func _get_generator(graph_edit, node_name : String):
	if graph_edit == null or graph_edit.generator == null:
		return null
	return graph_edit.generator.get_node_or_null(NodePath(node_name))


func _action_get_graph(_args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null or graph_edit.top_generator == null:
		return _error("no material project open")
	return graph_edit.top_generator.serialize()


func _action_new_material(_args : Dictionary):
	if mm_globals.main_window == null:
		return _error("main window not ready")
	mm_globals.main_window.new_material()
	return { created = true }


func _action_load_material(args : Dictionary):
	if mm_globals.main_window == null:
		return _error("main window not ready")
	var path : String = str(args.get("path", ""))
	if path == "":
		return _error("missing 'path'")
	if not await mm_globals.main_window.do_load_material(path):
		return _error("failed to load '%s'" % path)
	return { loaded = path }


func _action_save_material(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	var path : String = str(args.get("path", ""))
	if path == "":
		path = graph_edit.save_path
	if path == "":
		return _error("no path given and the project has no save path")
	if not await graph_edit.save_file(path):
		return _error("save failed")
	return { saved = path }


func _action_add_node(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	var type_name : String = str(args.get("type", ""))
	if type_name == "":
		return _error("missing 'type'")
	var data : Dictionary = { type = type_name, parameters = args.get("parameters", {}) }
	var position := Vector2(0, 0)
	if args.get("position", []) is Array and args.position.size() == 2:
		position = Vector2(float(args.position[0]), float(args.position[1]))
	var nodes : Array = await graph_edit.create_nodes(data, position)
	if nodes.is_empty():
		return _error("failed to create node of type '%s'" % type_name)
	return { name = nodes[0].generator.name, type = type_name }


func _action_remove_node(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	var node_name : String = str(args.get("node", ""))
	var ui_node = graph_edit.get_node_or_null("node_"+node_name)
	if ui_node == null:
		return _error("unknown node '%s'" % node_name)
	graph_edit.remove_node(ui_node)
	return { removed = node_name }


func _action_connect_nodes(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	for k in [ "from", "from_port", "to", "to_port" ]:
		if not args.has(k):
			return _error("missing '%s'" % k)
	var from_ui : String = "node_"+str(args.from)
	var to_ui : String = "node_"+str(args.to)
	if graph_edit.get_node_or_null(from_ui) == null or graph_edit.get_node_or_null(to_ui) == null:
		return _error("unknown node '%s' or '%s'" % [str(args.from), str(args.to)])
	if graph_edit.do_connect_node(from_ui, int(args.from_port), to_ui, int(args.to_port)):
		return { connected = true }
	return _error("connection failed (check port indexes/types)")


func _action_disconnect_nodes(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	for k in [ "from", "from_port", "to", "to_port" ]:
		if not args.has(k):
			return _error("missing '%s'" % k)
	var from_ui : String = "node_"+str(args.from)
	var to_ui : String = "node_"+str(args.to)
	if graph_edit.get_node_or_null(from_ui) == null or graph_edit.get_node_or_null(to_ui) == null:
		return _error("unknown node '%s' or '%s'" % [str(args.from), str(args.to)])
	if graph_edit.do_disconnect_node(from_ui, int(args.from_port), to_ui, int(args.to_port)):
		return { disconnected = true }
	return _error("no such connection")


func _action_set_parameter(args : Dictionary):
	var graph_edit = _get_graph_edit()
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var parameter_name : String = str(args.get("name", ""))
	if parameter_name == "" or not args.has("value"):
		return _error("missing 'name' or 'value'")
	gen.set_parameter(parameter_name, MMType.deserialize_value(args.value))
	return { node = gen.name, name = parameter_name, value = MMType.serialize_value(gen.get_parameter(parameter_name)) }


func _action_get_parameter(args : Dictionary):
	var graph_edit = _get_graph_edit()
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var parameter_name : String = str(args.get("name", ""))
	return { node = gen.name, name = parameter_name, value = MMType.serialize_value(gen.get_parameter(parameter_name)) }


func _action_render_node(args : Dictionary):
	var graph_edit = _get_graph_edit()
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var size := Vector2i(512, 512)
	if args.get("size", []) is Array and args.size.size() == 2:
		size = Vector2i(int(args.size[0]), int(args.size[1]))
	var output : int = int(args.get("output", 0))
	var path : String = str(args.get("path", ""))
	if path == "":
		return _error("missing 'path'")
	var image : Image = await gen.render_output(output, size)
	if image == null:
		return _error("render failed")
	var err : Error = image.save_png(path)
	if err != OK:
		return _error("cannot save image to '%s' (error %d)" % [path, err])
	return { path = path, size = [size.x, size.y] }


func _action_export_material(args : Dictionary):
	var graph_edit = _get_graph_edit()
	if graph_edit == null:
		return _error("no material project open")
	var material_node : MMGenMaterial = graph_edit.get_material_node()
	if material_node == null:
		return _error("no material node in current project")
	var prefix : String = str(args.get("prefix", ""))
	var profile : String = str(args.get("profile", ""))
	if prefix == "" or profile == "":
		return _error("missing 'prefix' or 'profile'")
	var profiles : Array = material_node.get_export_profiles()
	if profiles.find(profile) == -1:
		return _error("unknown profile '%s' (available: %s)" % [profile, ", ".join(profiles)])
	await material_node.export_material(prefix, profile, int(args.get("size", 0)))
	return { exported = prefix, profile = profile }


# --- Documentation interface ---------------------------------------------------

func _action_list_actions(_args : Dictionary) -> Array:
	var rv : Array = []
	for action_name in actions.keys():
		var a : Dictionary = actions[action_name]
		rv.append({
			name = action_name,
			description = a.description,
			args = a.args,
			implemented = a.handler != _action_not_implemented,
		})
	return rv


func _action_describe(args : Dictionary):
	var topic : String = str(args.get("topic", ""))
	match topic:
		"actions":
			return _action_list_actions(args)
		"action":
			var action_name : String = str(args.get("name", ""))
			if not actions.has(action_name):
				return _error("unknown action '%s'" % action_name)
			var a : Dictionary = actions[action_name]
			return { name = action_name, description = a.description, args = a.args,
					implemented = a.handler != _action_not_implemented }
		"node_types":
			return _action_list_node_types(args)
		"node_type":
			return _action_describe_node_type(args)
		_:
			return _error("unknown topic '%s' (use actions|action|node_types|node_type)" % topic)


func _action_list_node_types(args : Dictionary):
	var file : FileAccess = FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if file == null:
		return _error("cannot read library %s" % LIBRARY_PATH)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		return _error("cannot parse library %s" % LIBRARY_PATH)
	var category_filter : String = str(args.get("category", "")).to_lower()
	var rv : Array = []
	for item in json.data.get("lib", []):
		if not item is Dictionary or not item.has("type"):
			continue
		var category : String = str(item.get("tree_item", ""))
		if category_filter != "" and not category.to_lower().begins_with(category_filter):
			continue
		# Deliberately compact (no icon_data / parameters) to keep responses small.
		rv.append({
			type = item.type,
			label = item.get("display_name", item.get("name", "")),
			category = category,
		})
	return rv


func _action_describe_node_type(args : Dictionary):
	var type_name : String = str(args.get("name", ""))
	if not mm_loader.predefined_generators.has(type_name):
		return _error("unknown node type '%s'" % type_name)
	var definition : Dictionary = mm_loader.predefined_generators[type_name]
	var rv : Dictionary = { type = type_name }
	var shader_model : Dictionary = definition.get("shader_model", {})
	for k in [ "name", "shortdesc", "longdesc" ]:
		if shader_model.has(k):
			rv[k] = shader_model[k]
	rv.parameters = _doc_entries(shader_model.get("parameters", []))
	rv.inputs = _doc_entries(shader_model.get("inputs", []))
	rv.outputs = _doc_entries(shader_model.get("outputs", []))
	return rv


# Extracts only the documentation-relevant keys from parameter/input/output
# definitions (drops GLSL code, widgets and other bulky fields).
func _doc_entries(entries : Array) -> Array:
	const KEEP : Array = [ "name", "label", "type", "default", "min", "max", "step", "values", "shortdesc" ]
	var rv : Array = []
	for e in entries:
		if not e is Dictionary:
			continue
		var d : Dictionary = {}
		for k in KEEP:
			if e.has(k):
				d[k] = e[k]
		rv.append(d)
	return rv


# --- TCP server ---------------------------------------------------------------

func start_server(port : int) -> bool:
	if server != null:
		return false
	server = TCPServer.new()
	var err : Error = server.listen(port, HOST)
	if err != OK:
		push_warning("mcp_bridge: cannot listen on %s:%d (error %d)" % [HOST, port, err])
		server = null
		_update_menu_status()
		return false
	current_port = port
	print("mcp_bridge: listening on %s:%d" % [HOST, port])
	_update_menu_status()
	return true


func stop_server() -> void:
	for client in clients:
		client.peer.disconnect_from_host()
	clients.clear()
	if server != null:
		server.stop()
		server = null
	_update_menu_status()


func is_running() -> bool:
	return server != null and server.is_listening()


func _process(_delta : float) -> void:
	# Once per second: re-add our global menu if the app rebuilt its menus
	# (which clears it), and inject our tab into a newly opened Preferences
	# dialog.
	menu_guard_elapsed += _delta
	if menu_guard_elapsed >= 1.0:
		menu_guard_elapsed = 0.0
		if using_global_menu:
			_ensure_global_menu()
		_check_preferences_dialog()
	if server == null:
		return
	while server.is_connection_available():
		var peer : StreamPeerTCP = server.take_connection()
		if peer != null:
			clients.append({ peer = peer, buffer = "" })
	for i in range(clients.size() - 1, -1, -1):
		var client : Dictionary = clients[i]
		var peer : StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.remove_at(i)
			continue
		var available : int = peer.get_available_bytes()
		if available <= 0:
			continue
		var data : Array = peer.get_partial_data(available)
		if data[0] != OK:
			continue
		client.buffer += data[1].get_string_from_utf8()
		var pos : int = client.buffer.find("\n")
		while pos != -1:
			var line : String = client.buffer.left(pos)
			client.buffer = client.buffer.substr(pos + 1)
			if not line.strip_edges().is_empty():
				_handle_line(client, line)
			pos = client.buffer.find("\n")


func _handle_line(client : Dictionary, line : String) -> void:
	var response : Dictionary = {}
	var json := JSON.new()
	if json.parse(line) != OK or not json.data is Dictionary:
		response.ok = false
		response.error = "invalid JSON request"
		_send(client, response)
		return
	var request : Dictionary = json.data
	if request.has("id"):
		response.id = request.id
	var action_name : String = str(request.get("action", ""))
	var args = request.get("args", {})
	if not args is Dictionary:
		args = {}
	if not actions.has(action_name):
		response.ok = false
		response.error = "unknown action '%s'" % action_name
	else:
		# Awaiting a non-coroutine value returns it immediately, so this
		# works for both synchronous and asynchronous handlers.
		var result = await actions[action_name].handler.call(args)
		if result is Dictionary and result.has("__error"):
			response.ok = false
			response.error = result.__error
		else:
			response.ok = true
			response.result = result
	_send(client, response)


func _send(client : Dictionary, response : Dictionary) -> void:
	var peer : StreamPeerTCP = client.peer
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())


func _error(message : String) -> Dictionary:
	return { __error = message }


# --- Menu injection -----------------------------------------------------------
# Adds an "MCP" menu at runtime, without touching main_window.tscn/.gd.
# On macOS the app menus live in the DisplayServer global menu bar, so the
# in-app MenuButton would be invisible there; use the global menu instead.

func _inject_menu() -> void:
	while mm_globals.main_window == null:
		await get_tree().process_frame
	if DisplayServer.has_feature(DisplayServer.FEATURE_GLOBAL_MENU):
		using_global_menu = true
		_rebuild_global_menu()
	else:
		var menu_container : Control = mm_globals.main_window.get_node_or_null("VBoxContainer/TopBar/Menu")
		if menu_container == null:
			return
		menu_button = MenuButton.new()
		menu_button.text = "MCP"
		menu_button.flat = false
		var popup : PopupMenu = menu_button.get_popup()
		popup.add_check_item("Server enabled", 0)
		popup.add_item("Settings...", 1)
		popup.add_separator()
		popup.add_item("", 100)
		popup.set_item_disabled(popup.get_item_index(100), true)
		status_item_id = 100
		popup.id_pressed.connect(_on_menu_id_pressed)
		menu_container.add_child(menu_button)
	print("mcp_bridge: menu injected (global_menu=%s)" % str(using_global_menu))
	_update_menu_status()


# --- macOS global menu (DisplayServer) -----------------------------------------

func _rebuild_global_menu() -> void:
	DisplayServer.global_menu_clear(GLOBAL_MENU)
	DisplayServer.global_menu_add_submenu_item("_main", "MCP", GLOBAL_MENU)
	var cb : Callable = _on_global_menu_item
	global_enabled_index = DisplayServer.global_menu_add_check_item(GLOBAL_MENU, "Server enabled", cb, cb, "enabled")
	DisplayServer.global_menu_add_item(GLOBAL_MENU, "Settings...", cb, cb, "settings")
	DisplayServer.global_menu_add_separator(GLOBAL_MENU)
	global_status_index = DisplayServer.global_menu_add_item(GLOBAL_MENU, "", Callable(), Callable(), "status")
	DisplayServer.global_menu_set_item_disabled(GLOBAL_MENU, global_status_index, true)
	global_menu_main_count = DisplayServer.global_menu_get_item_count("_main")


func _ensure_global_menu() -> void:
	# main_window.do_update_menus() clears "_main" whenever the app rebuilds
	# its menus; if our submenu vanished with it, add it back.
	var count : int = DisplayServer.global_menu_get_item_count("_main")
	if count < global_menu_main_count:
		_rebuild_global_menu()
		_update_menu_status()


func _on_global_menu_item(tag) -> void:
	match str(tag):
		"enabled":
			_toggle_server()
		"settings":
			_open_preferences()
	_update_menu_status()


# --- Shared menu logic -----------------------------------------------------------

func _on_menu_id_pressed(id : int) -> void:
	match id:
		0:
			_toggle_server()
		1:
			_open_preferences()
	_update_menu_status()


func _toggle_server() -> void:
	if is_running():
		stop_server()
	else:
		start_server(get_port())


func _update_menu_status() -> void:
	var status_text : String = "Server stopped"
	if is_running():
		status_text = "Server running on %s:%d" % [HOST, current_port]
	if using_global_menu:
		if global_status_index != -1:
			DisplayServer.global_menu_set_item_text(GLOBAL_MENU, global_status_index, status_text)
		if global_enabled_index != -1:
			DisplayServer.global_menu_set_item_checked(GLOBAL_MENU, global_enabled_index, is_running())
	elif menu_button != null:
		var popup : PopupMenu = menu_button.get_popup()
		var idx : int = popup.get_item_index(status_item_id)
		if idx != -1:
			popup.set_item_text(idx, status_text)
		idx = popup.get_item_index(0)
		if idx != -1:
			popup.set_item_checked(idx, is_running())


# --- Preferences integration ------------------------------------------------------
# Injects an "MCP" tab into the app's Preferences dialog at runtime. The
# preferences mechanism (preferences.gd) calls init_from_config() /
# update_config() on every control in the dialog, so our option controls
# integrate with Apply/OK/Cancel without any core changes.

class MCPAutostartOption:
	extends HBoxContainer
	var checkbox : CheckBox
	func _init() -> void:
		var label : Label = Label.new()
		label.text = "Start MCP server automatically"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(label)
		checkbox = CheckBox.new()
		add_child(checkbox)
	func init_from_config(c : ConfigFile) -> void:
		checkbox.button_pressed = c.get_value("config", "mcp_bridge_autostart", true)
	func update_config(c : ConfigFile) -> void:
		c.set_value("config", "mcp_bridge_autostart", checkbox.button_pressed)


class MCPPortOption:
	extends HBoxContainer
	var spinbox : SpinBox
	func _init() -> void:
		var label : Label = Label.new()
		label.text = "Port"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(label)
		spinbox = SpinBox.new()
		spinbox.min_value = 1024
		spinbox.max_value = 65535
		add_child(spinbox)
	func init_from_config(c : ConfigFile) -> void:
		spinbox.value = c.get_value("config", "mcp_bridge_port", 8765)
	func update_config(c : ConfigFile) -> void:
		c.set_value("config", "mcp_bridge_port", int(spinbox.value))


func _open_preferences() -> void:
	if mm_globals.main_window != null:
		mm_globals.main_window.edit_preferences()
		_check_preferences_dialog.call_deferred()


func _check_preferences_dialog() -> void:
	if mm_globals.main_window == null:
		return
	for w in mm_globals.main_window.get_children():
		if w is Window and w.has_method("edit_preferences") and not w.has_meta("mcp_bridge_injected"):
			_inject_preferences_tab(w)


func _inject_preferences_tab(dialog : Window) -> void:
	var tabs : TabContainer = dialog.get_node_or_null("HSplitContainer/PreferencesPanel/VBoxContainer/TabContainer")
	if tabs == null:
		return
	dialog.set_meta("mcp_bridge_injected", true)
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.name = "MCP"
	var vbox : VBoxContainer = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	var status : Label = Label.new()
	if is_running():
		status.text = "Status: server running on %s:%d" % [HOST, current_port]
	else:
		status.text = "Status: server stopped (toggle it in the MCP menu)"
	vbox.add_child(status)
	var version_label : Label = Label.new()
	version_label.text = "Bridge version: %s" % BRIDGE_VERSION
	vbox.add_child(version_label)
	vbox.add_child(HSeparator.new())
	vbox.add_child(MCPAutostartOption.new())
	vbox.add_child(MCPPortOption.new())
	var note : Label = Label.new()
	note.text = "The external MCP host (mcp_bridge_host) connects to this port.\nChanging the port restarts the server if it is running."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(note)
	tabs.add_child(scroll)
	# The Preferences dialog navigates via a category sidebar tree that is
	# built once from the TabContainer children (preferences_tree.gd), so
	# rebuild it to make our tab selectable.
	var tree : Tree = dialog.get_node_or_null("HSplitContainer/PreferenceCategory/Tree")
	if tree != null and tree.has_method("update_tree"):
		tree.update_tree()
	# Defer so the preferences dialog picks up our controls when it
	# initializes its own (edit_preferences() runs update_controls first).
	dialog.update_controls.call_deferred(scroll)
	if dialog.has_signal("config_changed"):
		dialog.config_changed.connect(_on_preferences_changed)


func _on_preferences_changed() -> void:
	var new_port : int = get_port()
	if is_running() and new_port != current_port:
		stop_server()
		start_server(new_port)
	_update_menu_status()
