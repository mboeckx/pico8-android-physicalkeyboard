extends Node

# =============================================================================
# Physical keyboard add-on — bootstrap.
#
# Registered as an autoload so the feature needs NO edits to any existing
# script. Nothing in video_streamer.gd, options_menu.gd or key.gd refers to
# this add-on; all the coupling points one way, from here into them. If these
# files are deleted and the autoload line is removed from project.godot, the
# project is byte-identical to upstream again.
#
# What it does:
#   * _input()   intercepts hardware-keyboard keys before the streamer's
#                _unhandled_input sees them, and marks them handled when the
#                mapping consumed them.
#   * _process() watches for keys left latched when input is taken away
#                mid-press (see _release_stuck_keys).
#   * installs one row in Options > Controls to open the mapping editor.
#
# Set INSTALL_OPTIONS_ROW to false to leave the options menu completely alone;
# the key mapping keeps working, only the editor becomes unreachable.
# =============================================================================

const INSTALL_OPTIONS_ROW := true

const MODULE_PATH := "res://physical_keyboard.gd"
const OPTIONS_MENU_PATH := "/root/Main/OptionsMenu"
const KEY_GROUP := "physkb_onscreen_keys"

var _module: GDScript = null
var _row_installed := false
var _keys_scanned := false


func _ready() -> void:
	# Loaded by path, not by class name: a failure here leaves _module null and
	# every use below no-ops, instead of taking the rest of the project with it.
	if ResourceLoader.exists(MODULE_PATH):
		_module = load(MODULE_PATH) as GDScript
	if _module == null:
		push_warning("physical keyboard add-on: module unavailable, staying inert")
		set_process(false)
		set_process_input(false)
		return
	# The row is installed from _process instead of here: autoloads are ready
	# before the main scene exists, so we retry until the menu shows up.


# --- Key mapping ------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _module == null or not (event is InputEventKey):
		return
	var streamer = PicoVideoStreamer.instance
	if streamer == null or streamer.input_blocked:
		return
	# Only while the streamer is actually feeding PICO-8; when a menu or dialog
	# has taken input away, keys are not ours to touch.
	if not streamer.is_processing_unhandled_input():
		return
	if _module.handle_key_event(streamer, event, streamer.current_navstate):
		get_viewport().set_input_as_handled()


# --- Stuck key watchdog -----------------------------------------------------

# Input can be taken away mid-press — the options menu opens on a left-edge
# swipe and switches the streamer's input processing off, dialogs block input —
# and whatever was down then never sees its release. It stays latched in
# PICO-8, and an on-screen key left in HELD re-sends itself every
# REPEAT_TIME_AFTER ms (key.gd), which with Escape flickers the screen.
func _process(_delta: float) -> void:
	if INSTALL_OPTIONS_ROW and not _row_installed:
		_try_install_row()

	var streamer = PicoVideoStreamer.instance
	if streamer == null or streamer.held_keys.is_empty():
		return
	if streamer.input_blocked or not streamer.is_processing_unhandled_input():
		_release_stuck_keys(streamer)


func _release_stuck_keys(streamer) -> void:
	# On-screen keys first: they own the repeat, and releasing them properly
	# also takes them out of held_keys.
	for node in _onscreen_keys():
		if not is_instance_valid(node):
			continue
		# key.gd: KeyState { RELEASED = 0, HELD, LOCKED }. Only HELD is a lost
		# release; LOCKED is a deliberate choice and does not repeat.
		if int(node.get("key_state")) != 1:
			continue
		node.set("key_state", 0)
		node.set("repeat_timer", INF)
		node.call("send_ev", false)
		if node.has_method("_update_visuals"):
			node.call("_update_visuals")

	# Anything else that reached held_keys (controller buttons, our own
	# mapping) and was not let go.
	_module.flush_held_keys(streamer)


# Finds the on-screen keys once by duck typing, then keeps them in our own
# group so key.gd needs no changes.
func _onscreen_keys() -> Array:
	if not _keys_scanned:
		_keys_scanned = true
		var main := get_node_or_null("/root/Main")
		if main != null:
			_collect_keys(main)
	return get_tree().get_nodes_in_group(KEY_GROUP)


func _collect_keys(node: Node) -> void:
	if node.has_method("send_ev") and "key_state" in node:
		node.add_to_group(KEY_GROUP)
	for child in node.get_children():
		_collect_keys(child)


# --- Options menu row -------------------------------------------------------

func _try_install_row() -> void:
	if _row_installed or _module == null:
		return
	var menu := get_node_or_null(OPTIONS_MENU_PATH)
	if menu == null:
		return
	_row_installed = _module.install_options_row(menu)
	if _row_installed:
		get_tree().root.size_changed.connect(_on_viewport_resized)
		_on_viewport_resized()


func _on_viewport_resized() -> void:
	if _module != null:
		_module.refresh_options_row(get_viewport().get_visible_rect().size)
