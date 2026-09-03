extends Control
class_name PhysKeyboardDialog

# Editor for PhysKeyboard. Built entirely in code so the feature stays in two
# files and needs no .tscn of its own — see physical_keyboard.gd for the model.

const COLOR_DIM := Color(0.62, 0.62, 0.62)
const COLOR_WARN := Color(1.0, 0.72, 0.2)
const COLOR_UNBOUND := Color(0.5, 0.5, 0.5)

var _font_size: int = 20
var _rows: Array = []          # [{ id, bind_btn, sub_label, block_box }]
var _capture_id: String = ""
var _enable_btn: CheckButton = null
var _mode_opt: OptionButton = null


func _init() -> void:
	name = "PhysicalKeyboardDialog"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 200
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	PhysKeyboard.ensure_loaded()

	var viewport := get_viewport_rect().size
	_font_size = int(max(16, min(viewport.x, viewport.y) * 0.030))

	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.75)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	var pad := int(max(8, viewport.x * 0.03))
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, pad)
	add_child(margin)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 1.0)
	style.set_border_width_all(2)
	style.border_color = Color(0.3, 0.3, 0.3, 1.0)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(int(_font_size * 0.6))
	panel.add_theme_stylebox_override("panel", style)
	margin.add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", int(_font_size * 0.4))
	panel.add_child(root)

	root.add_child(_make_label("Physical Keyboard", _font_size + 4, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER))

	# Master switch.
	var enable_row := HBoxContainer.new()
	enable_row.add_child(_make_label("Enable mapping", _font_size, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true))
	_enable_btn = CheckButton.new()
	_enable_btn.button_pressed = PhysKeyboard.enabled
	_enable_btn.toggled.connect(func(on): PhysKeyboard.set_enabled(on))
	enable_row.add_child(_enable_btn)
	root.add_child(enable_row)

	# D-pad mode.
	var mode_row := HBoxContainer.new()
	mode_row.add_child(_make_label("D-pad mapping", _font_size, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true))
	_mode_opt = OptionButton.new()
	_mode_opt.add_theme_font_size_override("font_size", _font_size)
	_mode_opt.add_item("Off", PhysKeyboard.GameMode.OFF)
	_mode_opt.add_item("Auto", PhysKeyboard.GameMode.AUTO)
	_mode_opt.add_item("Always", PhysKeyboard.GameMode.ALWAYS)
	_mode_opt.selected = clampi(PhysKeyboard.game_mode, 0, 2)
	_mode_opt.item_selected.connect(func(idx): PhysKeyboard.set_game_mode(idx))
	mode_row.add_child(_mode_opt)
	root.add_child(mode_row)

	var hint := _make_label(
		"Auto turns the D-pad keys on in Splore and in games, and off wherever "
		+ "PICO-8 takes text (console/editor); it needs PICO-8 0.2.7 with "
		+ "Advanced Features on, otherwise use Always.\n"
		+ "Tap a binding to record a new one. While recording: Backspace clears "
		+ "it, tapping the button again cancels.",
		int(_font_size * 0.72), COLOR_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", int(_font_size * 0.35))
	scroll.add_child(list)

	for action in PhysKeyboard.ACTIONS:
		if action.has("section"):
			list.add_child(_make_label(action["section"], _font_size, Color(0.55, 0.8, 1.0)))
		else:
			list.add_child(_make_action_row(action))

	root.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", int(_font_size * 0.5))
	var reset_btn := _make_button("Reset defaults")
	reset_btn.pressed.connect(func():
		PhysKeyboard.reset_to_defaults()
		PhysKeyboard.save()
		_refresh())
	footer.add_child(reset_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var close_btn := _make_button("Close")
	close_btn.pressed.connect(_close)
	footer.add_child(close_btn)
	root.add_child(footer)

	# Keep PICO-8 from seeing anything while we are open (also what the
	# controller dialog does).
	if PicoVideoStreamer.instance:
		PicoVideoStreamer.instance.set_input_blocked(true)

	_refresh()
	close_btn.call_deferred("grab_focus")


func _exit_tree() -> void:
	if PicoVideoStreamer.instance:
		PicoVideoStreamer.instance.set_input_blocked(false)


func _close() -> void:
	queue_free()


# --- Row construction ------------------------------------------------------

func _make_label(text: String, size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT, expand: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if expand:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", _font_size)
	return button


func _make_action_row(action: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_font_size * 0.5))

	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 0)
	names.add_child(_make_label(str(action["name"]), _font_size, Color.WHITE))
	var sub := _make_label("", int(_font_size * 0.72), COLOR_DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	names.add_child(sub)
	row.add_child(names)

	var bind_btn := _make_button("")
	bind_btn.custom_minimum_size.x = _font_size * 6
	bind_btn.pressed.connect(_on_bind_pressed.bind(str(action["id"])))
	row.add_child(bind_btn)

	var block_box: CheckBox = null
	if action.get("mode", "") == PhysKeyboard.MODE_SHORTCUT:
		block_box = CheckBox.new()
		block_box.tooltip_text = "Stop PICO-8's own %s from doing anything" % action["native"]
		block_box.button_pressed = PhysKeyboard.is_blocked(str(action["id"]))
		block_box.toggled.connect(func(on):
			PhysKeyboard.set_blocked(str(action["id"]), on)
			_refresh())
		row.add_child(block_box)
	else:
		# Keep the bind buttons lined up with the ones that have a checkbox.
		var filler := Control.new()
		filler.custom_minimum_size.x = _font_size * 1.5
		row.add_child(filler)

	_rows.append({
		"id": str(action["id"]),
		"action": action,
		"bind_btn": bind_btn,
		"sub": sub,
		"block": block_box,
	})
	return row


# --- State ------------------------------------------------------------------

func _refresh() -> void:
	var conflicts := PhysKeyboard.get_conflicts()

	if _enable_btn:
		_enable_btn.set_pressed_no_signal(PhysKeyboard.enabled)
	if _mode_opt:
		_mode_opt.selected = clampi(PhysKeyboard.game_mode, 0, 2)

	for row in _rows:
		var action: Dictionary = row["action"]
		var id: String = row["id"]
		var bind: String = PhysKeyboard.get_bind(id)
		var button: Button = row["bind_btn"]

		if _capture_id == id:
			button.text = "press key..."
			button.add_theme_color_override("font_color", COLOR_WARN)
		elif bind.is_empty():
			button.text = "(none)"
			button.add_theme_color_override("font_color", COLOR_UNBOUND)
		else:
			button.text = bind
			button.add_theme_color_override("font_color",
				COLOR_WARN if conflicts.has(id) else Color.WHITE)

		var is_blocked := PhysKeyboard.is_blocked(id)
		if row["block"] != null:
			row["block"].set_pressed_no_signal(is_blocked)

		var sub_parts: Array = []
		if action.get("mode", "") == PhysKeyboard.MODE_SHORTCUT:
			sub_parts.append("PICO-8: %s" % action["native"])
		else:
			sub_parts.append("sends %s" % action["native"])
		if is_blocked:
			sub_parts.append("original disabled")
		if conflicts.has(id):
			sub_parts.append("also bound to: %s" % ", ".join(conflicts[id]))

		var sub: Label = row["sub"]
		sub.text = "   -   ".join(sub_parts)
		sub.add_theme_color_override("font_color", COLOR_WARN if conflicts.has(id) else COLOR_DIM)


func _on_bind_pressed(id: String) -> void:
	if _capture_id == id:
		_end_capture()
	else:
		_capture_id = id
	_refresh()


func _end_capture() -> void:
	_capture_id = ""


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if _capture_id == "":
			return
		# Swallow everything while recording so we do not also trigger the UI.
		get_viewport().set_input_as_handled()
		if not event.pressed or event.echo:
			return
		var code: int = event.keycode
		if code == KEY_CTRL or code == KEY_SHIFT or code == KEY_ALT or code == KEY_META:
			return  # wait for the key the modifier goes with
		if code == KEY_BACKSPACE:
			PhysKeyboard.set_bind(_capture_id, "")
		else:
			PhysKeyboard.set_bind(_capture_id, OS.get_keycode_string(event.get_keycode_with_modifiers()))
		_end_capture()
		_refresh()
		return

	# Close on the controller's cancel button, like the other dialogs.
	if event is InputEventJoypadButton and event.pressed:
		event = PicoVideoStreamer.swap_event_button_AB(event)
		if event.button_index == PicoVideoStreamer.get_cancel_button():
			get_viewport().set_input_as_handled()
			_close()
