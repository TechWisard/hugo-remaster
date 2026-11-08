class_name RemasterInput
extends RefCounted


static func configure() -> void:
	var keys: Dictionary = {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN],
		"jump": [KEY_SPACE], "sprint": [KEY_SHIFT], "crouch": [KEY_CTRL],
		"attack": [KEY_E], "reset": [KEY_R], "pause": [KEY_ESCAPE],
		"interact": [KEY_F], "camera_toggle": [KEY_C]}
	for action: String in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.18)
		for key: int in keys[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)
	var axes: Array[String] = ["move_left", "move_right", "move_forward", "move_back"]
	for i: int in range(axes.size()):
		var event := InputEventJoypadMotion.new()
		event.axis = JOY_AXIS_LEFT_X if i < 2 else JOY_AXIS_LEFT_Y
		event.axis_value = -1.0 if i % 2 == 0 else 1.0
		if not InputMap.action_has_event(axes[i], event):
			InputMap.action_add_event(axes[i], event)
	for pair: Array in [["jump", JOY_BUTTON_A], ["ui_accept", JOY_BUTTON_A],
		["ui_cancel", JOY_BUTTON_B], ["crouch", JOY_BUTTON_B], ["attack", JOY_BUTTON_X],
		["interact", JOY_BUTTON_Y], ["sprint", JOY_BUTTON_RIGHT_SHOULDER], ["pause", JOY_BUTTON_START]]:
		var event := InputEventJoypadButton.new()
		event.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], event):
			InputMap.action_add_event(pair[0], event)
	var attack_mouse := InputEventMouseButton.new()
	attack_mouse.button_index = MOUSE_BUTTON_LEFT
	if not InputMap.action_has_event("attack", attack_mouse):
		InputMap.action_add_event("attack", attack_mouse)
