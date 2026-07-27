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

var server : TCPServer
# Array of { peer: StreamPeerTCP, buffer: String }
var clients : Array = []
var actions : Dictionary = {}

var menu_button : MenuButton
var status_item_id : int = -1


func _ready() -> void:
	_register_actions()
	start_server(get_port())
	_inject_menu()


func _exit_tree() -> void:
	stop_server()


func get_port() -> int:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--mcp-port="):
			return int(arg.trim_prefix("--mcp-port="))
	return DEFAULT_PORT


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


func _action_ping(_args : Dictionary) -> Dictionary:
	return { pong = true }


func _action_version(_args : Dictionary) -> Dictionary:
	return {
		app = "Material Maker",
		app_version = ProjectSettings.get_setting("application/config/actual_release", ""),
		godot_version = Engine.get_version_info().string,
		bridge_version = BRIDGE_VERSION,
	}


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
		var result = actions[action_name].handler.call(args)
		if result is GDScriptFunctionState:
			result = await result
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
# Adds an "MCP" menu to the main window menu bar at runtime, without touching
# main_window.tscn / main_window.gd.

func _inject_menu() -> void:
	while mm_globals.main_window == null:
		await get_tree().process_frame
	var menu_container : Control = mm_globals.main_window.get_node_or_null("VBoxContainer/TopBar/Menu")
	if menu_container == null:
		return
	menu_button = MenuButton.new()
	menu_button.text = "MCP"
	menu_button.flat = false
	var popup : PopupMenu = menu_button.get_popup()
	popup.add_item("Start server", 0)
	popup.add_item("Stop server", 1)
	popup.add_separator()
	popup.add_item("", 100)
	popup.set_item_disabled(popup.get_item_index(100), true)
	status_item_id = 100
	popup.id_pressed.connect(_on_menu_id_pressed)
	menu_container.add_child(menu_button)
	_update_menu_status()


func _on_menu_id_pressed(id : int) -> void:
	match id:
		0:
			start_server(get_port())
		1:
			stop_server()
	_update_menu_status()


func _update_menu_status() -> void:
	if menu_button == null or status_item_id == -1:
		return
	var popup : PopupMenu = menu_button.get_popup()
	var idx : int = popup.get_item_index(status_item_id)
	if idx == -1:
		return
	if is_running():
		popup.set_item_text(idx, "Server running on %s:%d" % [HOST, get_port()])
	else:
		popup.set_item_text(idx, "Server stopped")
