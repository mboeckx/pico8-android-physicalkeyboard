extends RefCounted
class_name PhysKeyboard

# =============================================================================
# Physical (hardware) keyboard support — self-contained add-on.
#
# Devices such as the Unihertz Titan 2 ship with a BlackBerry-style QWERTY that
# has no arrow keys, no number row, no ESC and no F-keys. That breaks PICO-8 in
# two separate ways, and this module fixes both without touching the rest of the
# frontend:
#
#   1. Splore / running carts. PICO-8 wants arrows + Z/X there, and the device
#      simply has none of those keys, so the keyboard is dead weight whenever
#      text input is not what you are doing. GAME actions below translate plain
#      key presses (WASD / O / P / Q by default) into the PICO-8 keys, and they
#      are only live while PICO-8 is *not* taking text input (see _game_active).
#
#   2. The code editor. PICO-8's shortcuts are hard-coded and several of them
#      need keys the device does not have. SHORTCUT actions can be re-bound to
#      any chord (we replay PICO-8's original chord for it) or disabled
#      outright, and KEY actions expose the missing keys themselves.
#
# Everything lives here and in physical_keyboard_dialog.gd. The rest of the
# frontend only calls:
#     PhysKeyboard.handle_key_event(...)   -> video_streamer.gd
#     PhysKeyboard.install_options_row(...) / style_options_row(...)
#                                          -> options_menu.gd
#
# Shortcut reference: https://pico-8.fandom.com/wiki/Keyboard_Shortcuts
# =============================================================================

const SDL_KEYMAP: Dictionary = preload("res://sdl_keymap.json").data

const SETTINGS_SECTION := "physical_keyboard"
const SETTINGS_KEY := "config"

# Godot spells a few keys differently from sdl_keymap.json.
const KEY_ALIASES := {
	"PageUp": "SDL_PAGEUP",
	"PageDown": "SDL_PAGEDOWN",
	"KpEnter": "SDL_KP_ENTER",
}

# SDL scancodes / modifier masks for the chords we replay ourselves.
const SDL_SC_CTRL := 224
const SDL_SC_SHIFT := 225
const SDL_SC_ALT := 226
const KMOD_SHIFT := 0x0001
const KMOD_CTRL := 0x0040
const KMOD_ALT := 0x0100

# navstate bits, mirroring shim.c / video_streamer.gd.
const NAV_EDITOR := 0x01
const NAV_GAME := 0x02
const NAV_SPLORE := 0x08
const NAV_CONSOLE := 0x10

enum GameMode { OFF = 0, AUTO = 1, ALWAYS = 2 }

# Action kinds:
#   MODE_GAME     plain key -> PICO-8 key, held for as long as you hold it,
#                 only while PICO-8 is not taking text input.
#   MODE_SHORTCUT a PICO-8 chord. Re-bindable (we replay the original chord)
#                 and disable-able (we swallow the original chord).
#   MODE_KEY      a plain key the device may not have. Re-bindable only.
#   MODE_APP      handled here in the frontend, never forwarded to PICO-8.
const MODE_GAME := "game"
const MODE_SHORTCUT := "shortcut"
const MODE_KEY := "key"
const MODE_APP := "app"

# "native" is what PICO-8 itself listens for; "default" is our suggested
# re-binding for a keyboard that cannot produce "native".
const ACTIONS: Array = [
	{"section": "Game / Splore (D-pad)"},
	{"id": "g_up", "name": "Up", "mode": MODE_GAME, "native": "Up", "default": "W"},
	{"id": "g_left", "name": "Left", "mode": MODE_GAME, "native": "Left", "default": "A"},
	{"id": "g_down", "name": "Down", "mode": MODE_GAME, "native": "Down", "default": "S"},
	{"id": "g_right", "name": "Right", "mode": MODE_GAME, "native": "Right", "default": "D"},
	{"id": "g_o", "name": "Button O", "mode": MODE_GAME, "native": "Z", "default": "O"},
	{"id": "g_x", "name": "Button X", "mode": MODE_GAME, "native": "X", "default": "P"},
	{"id": "g_esc", "name": "Menu / Escape", "mode": MODE_GAME, "native": "Escape", "default": "Q"},
	{"id": "g_pause", "name": "Pause", "mode": MODE_GAME, "native": "Enter"},

	{"section": "PICO-8 shortcuts"},
	{"id": "run", "name": "Run cart", "mode": MODE_SHORTCUT, "native": "Ctrl+R"},
	{"id": "save", "name": "Save cart", "mode": MODE_SHORTCUT, "native": "Ctrl+S"},
	{"id": "quit", "name": "Quit PICO-8", "mode": MODE_SHORTCUT, "native": "Ctrl+Q", "block_default": true},
	{"id": "mute", "name": "Mute / unmute", "mode": MODE_SHORTCUT, "native": "Ctrl+M"},
	{"id": "fullscreen", "name": "Toggle fullscreen", "mode": MODE_SHORTCUT, "native": "Alt+Enter"},
	{"id": "cut", "name": "Cut", "mode": MODE_SHORTCUT, "native": "Ctrl+X"},
	{"id": "copy", "name": "Copy", "mode": MODE_SHORTCUT, "native": "Ctrl+C"},
	{"id": "paste", "name": "Paste", "mode": MODE_SHORTCUT, "native": "Ctrl+V"},
	{"id": "undo", "name": "Undo", "mode": MODE_SHORTCUT, "native": "Ctrl+Z"},
	{"id": "redo", "name": "Redo", "mode": MODE_SHORTCUT, "native": "Ctrl+Y"},
	{"id": "select_all", "name": "Select all", "mode": MODE_SHORTCUT, "native": "Ctrl+A"},
	{"id": "find", "name": "Find", "mode": MODE_SHORTCUT, "native": "Ctrl+F"},
	{"id": "find_next", "name": "Find next", "mode": MODE_SHORTCUT, "native": "Ctrl+G"},
	{"id": "screenshot", "name": "Screenshot", "mode": MODE_SHORTCUT, "native": "F6"},
	{"id": "cart_label", "name": "Set cart label", "mode": MODE_SHORTCUT, "native": "F7"},
	{"id": "gif_start", "name": "Start GIF capture", "mode": MODE_SHORTCUT, "native": "F8"},
	{"id": "gif_save", "name": "Save GIF", "mode": MODE_SHORTCUT, "native": "F9"},
	{"id": "prev_editor", "name": "Previous editor tab", "mode": MODE_SHORTCUT, "native": "Alt+Left"},
	{"id": "next_editor", "name": "Next editor tab", "mode": MODE_SHORTCUT, "native": "Alt+Right"},

	{"section": "Misc keys"},
	{"id": "k_escape", "name": "Escape", "mode": MODE_KEY, "native": "Escape", "default": "Ctrl+Q"},
	{"id": "k_tab", "name": "Tab", "mode": MODE_KEY, "native": "Tab"},
	{"id": "k_up", "name": "Arrow Up", "mode": MODE_KEY, "native": "Up"},
	{"id": "k_down", "name": "Arrow Down", "mode": MODE_KEY, "native": "Down"},
	{"id": "k_left", "name": "Arrow Left", "mode": MODE_KEY, "native": "Left"},
	{"id": "k_right", "name": "Arrow Right", "mode": MODE_KEY, "native": "Right"},
	{"id": "k_home", "name": "Home", "mode": MODE_KEY, "native": "Home"},
	{"id": "k_end", "name": "End", "mode": MODE_KEY, "native": "End"},
	{"id": "k_pageup", "name": "Page Up", "mode": MODE_KEY, "native": "PageUp"},
	{"id": "k_pagedown", "name": "Page Down", "mode": MODE_KEY, "native": "PageDown"},
	{"id": "k_delete", "name": "Delete", "mode": MODE_KEY, "native": "Delete"},
	{"id": "k_insert", "name": "Insert", "mode": MODE_KEY, "native": "Insert"},

	{"section": "Number row"},
	{"id": "k_1", "name": "Type 1", "mode": MODE_KEY, "native": "1", "char": "1"},
	{"id": "k_2", "name": "Type 2", "mode": MODE_KEY, "native": "2", "char": "2"},
	{"id": "k_3", "name": "Type 3", "mode": MODE_KEY, "native": "3", "char": "3"},
	{"id": "k_4", "name": "Type 4", "mode": MODE_KEY, "native": "4", "char": "4"},
	{"id": "k_5", "name": "Type 5", "mode": MODE_KEY, "native": "5", "char": "5"},
	{"id": "k_6", "name": "Type 6", "mode": MODE_KEY, "native": "6", "char": "6"},
	{"id": "k_7", "name": "Type 7", "mode": MODE_KEY, "native": "7", "char": "7"},
	{"id": "k_8", "name": "Type 8", "mode": MODE_KEY, "native": "8", "char": "8"},
	{"id": "k_9", "name": "Type 9", "mode": MODE_KEY, "native": "9", "char": "9"},
	{"id": "k_0", "name": "Type 0", "mode": MODE_KEY, "native": "0", "char": "0"},

	{"section": "This app"},
	{"id": "app_cursor", "name": "Hide cursor", "mode": MODE_APP,
		"hint": "toggles Options > Controls > Hide Cursor"},

	{"section": "Symbols"},
	{"id": "s_lparen", "name": "Type (", "mode": MODE_KEY, "native": "Shift+9", "char": "("},
	{"id": "s_rparen", "name": "Type )", "mode": MODE_KEY, "native": "Shift+0", "char": ")"},
	{"id": "s_lbracket", "name": "Type [", "mode": MODE_KEY, "native": "BracketLeft", "char": "["},
	{"id": "s_rbracket", "name": "Type ]", "mode": MODE_KEY, "native": "BracketRight", "char": "]"},
	{"id": "s_lbrace", "name": "Type {", "mode": MODE_KEY, "native": "Shift+BracketLeft", "char": "{"},
	{"id": "s_rbrace", "name": "Type }", "mode": MODE_KEY, "native": "Shift+BracketRight", "char": "}"},
	{"id": "s_lt", "name": "Type <", "mode": MODE_KEY, "native": "Shift+Comma", "char": "<"},
	{"id": "s_gt", "name": "Type >", "mode": MODE_KEY, "native": "Shift+Period", "char": ">"},
	{"id": "s_semicolon", "name": "Type ;", "mode": MODE_KEY, "native": "Semicolon", "char": ";"},
	{"id": "s_colon", "name": "Type :", "mode": MODE_KEY, "native": "Shift+Semicolon", "char": ":"},
	{"id": "s_equal", "name": "Type =", "mode": MODE_KEY, "native": "Equal", "char": "="},
	{"id": "s_plus", "name": "Type +", "mode": MODE_KEY, "native": "Shift+Equal", "char": "+"},
	{"id": "s_minus", "name": "Type -", "mode": MODE_KEY, "native": "Minus", "char": "-"},
	{"id": "s_underscore", "name": "Type _", "mode": MODE_KEY, "native": "Shift+Minus", "char": "_"},
	{"id": "s_slash", "name": "Type /", "mode": MODE_KEY, "native": "Slash", "char": "/"},
	{"id": "s_backslash", "name": "Type \\", "mode": MODE_KEY, "native": "BackSlash", "char": "\\"},
	{"id": "s_pipe", "name": "Type |", "mode": MODE_KEY, "native": "Shift+BackSlash", "char": "|"},
	{"id": "s_percent", "name": "Type %", "mode": MODE_KEY, "native": "Shift+5", "char": "%"},
	{"id": "s_hash", "name": "Type #", "mode": MODE_KEY, "native": "Shift+3", "char": "#"},
	{"id": "s_at", "name": "Type @", "mode": MODE_KEY, "native": "Shift+2", "char": "@"},
	{"id": "s_dollar", "name": "Type $", "mode": MODE_KEY, "native": "Shift+4", "char": "$"},
	{"id": "s_caret", "name": "Type ^", "mode": MODE_KEY, "native": "Shift+6", "char": "^"},
	{"id": "s_amp", "name": "Type &", "mode": MODE_KEY, "native": "Shift+7", "char": "&"},
	{"id": "s_star", "name": "Type *", "mode": MODE_KEY, "native": "Shift+8", "char": "*"},
	{"id": "s_bang", "name": "Type !", "mode": MODE_KEY, "native": "Shift+1", "char": "!"},
	{"id": "s_question", "name": "Type ?", "mode": MODE_KEY, "native": "Shift+Slash", "char": "?"},
	{"id": "s_tilde", "name": "Type ~", "mode": MODE_KEY, "native": "Shift+QuoteLeft", "char": "~"},
	{"id": "s_quote", "name": "Type \"", "mode": MODE_KEY, "native": "Shift+Apostrophe", "char": "\""},
]

# --- Persisted state -------------------------------------------------------

static var enabled: bool = false
static var game_mode: int = GameMode.AUTO
static var hide_cursor: bool = false
static var binds: Dictionary = {}    # action id -> chord string ("" = unbound)
static var blocked: Dictionary = {}  # action id -> bool (MODE_SHORTCUT only)

static var _loaded: bool = false
static var _by_id: Dictionary = {}
static var _bind_lookup: Dictionary = {}    # keycode+mods -> action id (chords)
static var _game_lookup: Dictionary = {}    # keycode+mods -> action id (game)
static var _blocked_lookup: Dictionary = {} # keycode+mods -> true


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	for act in ACTIONS:
		if act.has("id"):
			_by_id[act["id"]] = act

	var cfg = PicoBootManager.get_setting(SETTINGS_SECTION, SETTINGS_KEY, null)
	if cfg is Dictionary:
		enabled = bool(cfg.get("enabled", false))
		game_mode = int(cfg.get("game_mode", GameMode.AUTO))
		hide_cursor = bool(cfg.get("hide_cursor", false))
		for k in cfg.get("binds", {}):
			binds[str(k)] = str(cfg["binds"][k])
		for k in cfg.get("blocked", {}):
			blocked[str(k)] = bool(cfg["blocked"][k])
	else:
		# First run: the defaults below are only interesting on a device that
		# actually has a hardware keyboard, so only switch ourselves on there.
		reset_to_defaults()
		enabled = has_hardware_keyboard()
	_rebuild()


static func save() -> void:
	PicoBootManager.set_setting(SETTINGS_SECTION, SETTINGS_KEY, {
		"enabled": enabled,
		"game_mode": game_mode,
		"hide_cursor": hide_cursor,
		"binds": binds,
		"blocked": blocked,
	})


static func reset_to_defaults() -> void:
	binds.clear()
	blocked.clear()
	game_mode = GameMode.AUTO
	for act in ACTIONS:
		if not act.has("id"):
			continue
		binds[act["id"]] = str(act.get("default", ""))
		if act.get("block_default", false):
			blocked[act["id"]] = true
	_rebuild()


static func has_hardware_keyboard() -> bool:
	# Applinks is an autoload; look it up defensively so this stays callable
	# from anywhere (and on desktop, where the plugin does not exist).
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	var node = tree.root.get_node_or_null("Applinks")
	if node and node.has_method("has_physical_keyboard"):
		return node.has_physical_keyboard()
	return false


# --- Binding helpers -------------------------------------------------------

static func get_bind(action_id: String) -> String:
	ensure_loaded()
	return str(binds.get(action_id, ""))


static func set_bind(action_id: String, chord: String) -> void:
	ensure_loaded()
	binds[action_id] = chord
	_rebuild()
	save()


static func is_blocked(action_id: String) -> bool:
	ensure_loaded()
	return bool(blocked.get(action_id, false))


static func set_blocked(action_id: String, value: bool) -> void:
	ensure_loaded()
	blocked[action_id] = value
	_rebuild()
	save()


static func set_enabled(value: bool) -> void:
	ensure_loaded()
	enabled = value
	save()


static func set_hide_cursor(value: bool) -> void:
	ensure_loaded()
	hide_cursor = value
	# The bindable shortcut can flip this while the menu is closed.
	if is_instance_valid(_cursor_toggle):
		_cursor_toggle.set_pressed_no_signal(value)
	save()


static func set_game_mode(value: int) -> void:
	ensure_loaded()
	game_mode = value
	save()


static func chord_to_code(chord: String) -> int:
	if chord.is_empty():
		return 0
	return int(OS.find_keycode_from_string(chord))


static func code_to_chord(code: int) -> String:
	if code == 0:
		return ""
	return OS.get_keycode_string(code)


static func _rebuild() -> void:
	_bind_lookup.clear()
	_game_lookup.clear()
	_blocked_lookup.clear()

	for act in ACTIONS:
		if not act.has("id"):
			continue
		var id: String = act["id"]
		var mode: String = act.get("mode", MODE_SHORTCUT)
		var code := chord_to_code(str(binds.get(id, "")))

		if mode == MODE_GAME:
			if code != 0 and not _game_lookup.has(code):
				_game_lookup[code] = id
		else:
			if code != 0 and not _bind_lookup.has(code):
				_bind_lookup[code] = id
			if mode == MODE_SHORTCUT and bool(blocked.get(id, false)):
				var native := chord_to_code(str(act.get("native", "")))
				if native != 0:
					_blocked_lookup[native] = true


# Actions sharing a chord, so the editor can warn about it.
# Returns { action_id: [names of the other things on that chord] }.
static func get_conflicts() -> Dictionary:
	ensure_loaded()
	var owners := {}  # "mode|code" -> Array of display names

	for act in ACTIONS:
		if not act.has("id"):
			continue
		var id: String = act["id"]
		var mode: String = act.get("mode", MODE_SHORTCUT)
		var space := MODE_GAME if mode == MODE_GAME else "chord"
		var bind_code := chord_to_code(str(binds.get(id, "")))

		if bind_code != 0:
			var k := "%s|%d" % [space, bind_code]
			if not owners.has(k):
				owners[k] = []
			owners[k].append(act["name"])

		# A PICO-8 shortcut we have not disabled is still reachable on its own
		# chord, so it competes with anything the user binds to that chord.
		if mode == MODE_SHORTCUT and not bool(blocked.get(id, false)):
			var native := chord_to_code(str(act.get("native", "")))
			if native != 0 and native != bind_code:
				var kn := "chord|%d" % native
				if not owners.has(kn):
					owners[kn] = []
				owners[kn].append(act["name"])

	var result := {}
	for act in ACTIONS:
		if not act.has("id"):
			continue
		var id: String = act["id"]
		var mode: String = act.get("mode", MODE_SHORTCUT)
		var space := MODE_GAME if mode == MODE_GAME else "chord"
		var bind_code := chord_to_code(str(binds.get(id, "")))
		if bind_code == 0:
			continue
		var others: Array = []
		for other_name in owners.get("%s|%d" % [space, bind_code], []):
			if other_name != act["name"]:
				others.append(other_name)
		if not others.is_empty():
			result[id] = others
	return result


# --- Runtime ---------------------------------------------------------------

static func _game_active(navstate: int) -> bool:
	match game_mode:
		GameMode.OFF:
			return false
		GameMode.ALWAYS:
			return true
		_:
			# Auto needs the navstate telemetry (PICO-8 0.2.7 + advanced
			# features). Without it we stay out of the way so typing keeps
			# working; "Always" is there for that case.
			if navstate == 0:
				return false
			return (navstate & (NAV_GAME | NAV_SPLORE)) != 0


# Called from video_streamer._unhandled_input. Returns true when the event has
# been fully dealt with here and must not follow the normal path.
static func handle_key_event(streamer, event: InputEventKey, navstate: int) -> bool:
	ensure_loaded()
	if not enabled:
		return false

	var code := int(event.get_keycode_with_modifiers())
	var base := code & KEY_CODE_MASK
	# A modifier on its own is never a chord — let it through so PICO-8 keeps
	# tracking the real Ctrl/Shift/Alt state.
	if base == KEY_CTRL or base == KEY_SHIFT or base == KEY_ALT or base == KEY_META:
		return false

	# 1. User re-bindings (live everywhere, including the editor).
	if _bind_lookup.has(code):
		if event.pressed:
			var hit: String = _bind_lookup[code]
			if str(_by_id.get(hit, {}).get("mode", "")) == MODE_APP:
				# Ours to act on, and only once per press.
				if not event.echo:
					_run_app_action(hit)
			else:
				_emit_action(streamer, hit, event)
		return true

	# 2. PICO-8 shortcuts the user switched off.
	if _blocked_lookup.has(code):
		return true

	# 3. D-pad style mapping, only where PICO-8 is not taking text input.
	if _game_lookup.has(code) and _game_active(navstate):
		var act: Dictionary = _by_id[_game_lookup[code]]
		var target := _sdl_id(chord_to_code(str(act.get("native", ""))) & KEY_CODE_MASK)
		if target != "":
			streamer.vkb_setstate(target, event.pressed, 0, event.echo)
		return true

	return false


static func _run_app_action(action_id: String) -> void:
	match action_id:
		"app_cursor":
			set_hide_cursor(not hide_cursor)


static func _sdl_id(keycode: int) -> String:
	if keycode == 0:
		return ""
	var key_name := OS.get_keycode_string(keycode)
	if KEY_ALIASES.has(key_name):
		key_name = KEY_ALIASES[key_name]
	return key_name if SDL_KEYMAP.has(key_name) else ""


# Replays an action's native chord. The physical modifiers the user is actually
# holding have already been forwarded to PICO-8, so we line them up with the
# chord we want, fire it, and put them back.
static func _emit_action(streamer, action_id: String, event: InputEventKey) -> void:
	var act: Dictionary = _by_id.get(action_id, {})
	if act.is_empty():
		return
	var native := chord_to_code(str(act.get("native", "")))
	var id := _sdl_id(native & KEY_CODE_MASK)
	if id == "":
		return

	var want_ctrl := (native & KEY_MASK_CTRL) != 0
	var want_shift := (native & KEY_MASK_SHIFT) != 0
	var want_alt := (native & KEY_MASK_ALT) != 0
	var have_ctrl := event.ctrl_pressed
	var have_shift := event.shift_pressed
	var have_alt := event.alt_pressed

	var want_mod := 0
	if want_ctrl: want_mod |= KMOD_CTRL
	if want_shift: want_mod |= KMOD_SHIFT
	if want_alt: want_mod |= KMOD_ALT

	var have_mod := 0
	if have_ctrl: have_mod |= KMOD_CTRL
	if have_shift: have_mod |= KMOD_SHIFT
	if have_alt: have_mod |= KMOD_ALT

	# Drop the modifiers the chord does not want, add the ones it does.
	if have_ctrl and not want_ctrl: streamer.send_key(SDL_SC_CTRL, false, false, want_mod)
	if have_shift and not want_shift: streamer.send_key(SDL_SC_SHIFT, false, false, want_mod)
	if have_alt and not want_alt: streamer.send_key(SDL_SC_ALT, false, false, want_mod)
	if want_ctrl and not have_ctrl: streamer.send_key(SDL_SC_CTRL, true, false, want_mod)
	if want_shift and not have_shift: streamer.send_key(SDL_SC_SHIFT, true, false, want_mod)
	if want_alt and not have_alt: streamer.send_key(SDL_SC_ALT, true, false, want_mod)

	streamer.send_key(SDL_KEYMAP[id], true, event.echo, want_mod)
	# Printable keys also need the text event PICO-8's editors actually read.
	var printable := str(act.get("char", ""))
	if printable != "" and not want_ctrl and not want_alt:
		streamer.send_input(printable.unicode_at(0))
	streamer.send_key(SDL_KEYMAP[id], false, false, want_mod)

	# Put the real modifier state back.
	if want_ctrl and not have_ctrl: streamer.send_key(SDL_SC_CTRL, false, false, have_mod)
	if want_shift and not have_shift: streamer.send_key(SDL_SC_SHIFT, false, false, have_mod)
	if want_alt and not have_alt: streamer.send_key(SDL_SC_ALT, false, false, have_mod)
	if have_ctrl and not want_ctrl: streamer.send_key(SDL_SC_CTRL, true, false, have_mod)
	if have_shift and not want_shift: streamer.send_key(SDL_SC_SHIFT, true, false, have_mod)
	if have_alt and not want_alt: streamer.send_key(SDL_SC_ALT, true, false, have_mod)


# --- Options menu integration ----------------------------------------------

static var _options_button: Button = null
static var _options_row: Control = null
static var _options_menu: Node = null
static var _cursor_row: Control = null
static var _cursor_label: Button = null
static var _cursor_wrapper: Control = null
static var _cursor_toggle: CheckButton = null


# Adds a "Keyboard Mapping" row underneath "Manage Controllers".
static func install_options_row(menu: Node) -> void:
	ensure_loaded()
	var template: Button = menu.get_node_or_null("%ButtonConnectedControllers")
	if template == null or not is_instance_valid(template.get_parent()):
		return
	var anchor: Node = template.get_parent()
	var container: Node = anchor.get_parent()
	if container == null or container.has_node("PhysicalKeyboardRow"):
		return

	var row := HBoxContainer.new()
	row.name = "PhysicalKeyboardRow"
	# No DUPLICATE_SIGNALS: we only want the row's look, not its handler.
	var button: Button = template.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	button.name = "ButtonPhysicalKeyboard"
	button.unique_name_in_owner = false
	button.text = "Keyboard Mapping"
	button.tooltip_text = "Map a physical/bluetooth keyboard and re-bind PICO-8's editor shortcuts"
	row.add_child(button)
	container.add_child(row)
	container.move_child(row, anchor.get_index() + 1)

	_options_button = button
	_options_row = row
	_options_menu = menu
	button.pressed.connect(func(): PhysKeyboard.open_dialog(menu))

	_install_cursor_row(container, row)


# "Hide cursor" toggle, cloned from an existing toggle row so it inherits the
# scene's styling for free. options_menu._style_option_row only touches its own
# unique-named nodes, so the sizing is done in style_options_row() below.
static func _install_cursor_row(container: Node, after: Node) -> void:
	var template: Control = container.get_node_or_null("KeyboardRow")
	if template == null or container.has_node("HideCursorRow"):
		return

	var crow: Control = template.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	crow.name = "HideCursorRow"
	var label: Button = crow.get_node_or_null("ButtonKeyboard")
	var wrapper: Control = crow.get_node_or_null("WrapperKeyboard")
	if label == null or wrapper == null:
		crow.queue_free()
		return
	var toggle: CheckButton = wrapper.get_node_or_null("ToggleKeyboard")
	if toggle == null:
		crow.queue_free()
		return

	label.unique_name_in_owner = false
	toggle.unique_name_in_owner = false
	label.name = "ButtonHideCursor"
	wrapper.name = "WrapperHideCursor"
	toggle.name = "ToggleHideCursor"

	label.text = "Hide Cursor"
	label.tooltip_text = "Park PICO-8's mouse pointer in the corner and stop reporting clicks"
	toggle.button_pressed = hide_cursor
	toggle.toggled.connect(func(on): PhysKeyboard.set_hide_cursor(on))
	label.pressed.connect(func(): toggle.button_pressed = not toggle.button_pressed)

	container.add_child(crow)
	container.move_child(crow, after.get_index() + 1)

	_cursor_row = crow
	_cursor_label = label
	_cursor_wrapper = wrapper
	_cursor_toggle = toggle


static func style_options_row(font_size: int) -> void:
	if not is_instance_valid(_options_button):
		return
	_options_button.add_theme_font_size_override("font_size", font_size)

	# A row holding nothing but a button is shorter than the toggle rows, whose
	# wrapper reserves extra height, so it reads as cramped between them. Copy a
	# styled wrapper's reserved height onto this row — and onto the equally bare
	# "Manage Controllers" row above it — so the section spaces evenly.
	var reserved := 30.0 * clampf(font_size / 10.0, 1.2, 3.0)
	if is_instance_valid(_options_menu):
		var probe: Node = _options_menu.get_node_or_null("%ToggleKeyboard")
		if probe != null and probe.get_parent() is Control:
			var wrapper: Control = probe.get_parent()
			if wrapper.custom_minimum_size.y > 0.0:
				reserved = wrapper.custom_minimum_size.y
	if is_instance_valid(_options_row):
		_options_row.custom_minimum_size.y = reserved
		var neighbour = _options_row.get_parent().get_node_or_null("ConnectedControllersRow")
		if neighbour is Control:
			neighbour.custom_minimum_size.y = reserved

	# Same maths as options_menu._style_option_row, which does not know about
	# this row because its nodes are not unique-named in the scene.
	if is_instance_valid(_cursor_label) and is_instance_valid(_cursor_toggle) \
			and is_instance_valid(_cursor_wrapper):
		var scale_factor := clampf(font_size / 10.0, 1.2, 3.0)
		_cursor_label.add_theme_font_size_override("font_size", font_size)
		_cursor_toggle.text = ""
		_cursor_toggle.remove_theme_font_size_override("font_size")
		_cursor_toggle.scale = Vector2(scale_factor, scale_factor)
		_cursor_toggle.custom_minimum_size = Vector2.ZERO
		_cursor_toggle.size = Vector2.ZERO
		var natural := _cursor_toggle.get_combined_minimum_size()
		_cursor_toggle.size = natural
		var reserved_h := max(30.0, natural.y) * scale_factor
		_cursor_wrapper.custom_minimum_size = Vector2(70.0 * scale_factor, reserved_h)
		_cursor_toggle.position.y = (reserved_h - natural.y * scale_factor) / 2.0
		_cursor_label.focus_mode = Control.FOCUS_ALL
		_cursor_toggle.focus_mode = Control.FOCUS_ALL
		_cursor_label.focus_neighbor_right = _cursor_toggle.get_path()
		_cursor_toggle.focus_neighbor_left = _cursor_label.get_path()
		_cursor_toggle.set_pressed_no_signal(hide_cursor)


static var _dialog: Node = null

# Loaded at call time rather than preloaded: the dialog script refers back to
# this one, and a preload here would make that a cyclic dependency.
const DIALOG_SCRIPT_PATH := "res://physical_keyboard_dialog.gd"


static func open_dialog(menu: Node) -> void:
	if is_instance_valid(_dialog):
		return
	var script: GDScript = load(DIALOG_SCRIPT_PATH)
	if script == null:
		return
	_dialog = script.new()
	menu.get_tree().root.add_child(_dialog)
	if menu.has_method("close_menu"):
		menu.close_menu()
