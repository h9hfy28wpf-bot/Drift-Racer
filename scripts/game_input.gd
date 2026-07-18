extends Node

# Autoloaded input configuration (GameInput, from scenes/game_input.tscn).
# Owns everything input-related:
# - Installs an SDL mapping so the CY-1121 cabinet's two unrecognized
#   "Twin USB Gamepad" banks present as standard gamepads (panel buttons
#   1-6 = A/B/X/Y/LB/RB, Start = start, Select = back). The GUID is read
#   from the connected device because SDL GUIDs differ between Windows
#   (dev) and Linux (cabinet).
# - map_all_inputs_to_p1: single-player convenience — every control drives p1_*.
# - Quits immediately on ui_exit, as GD_ArcadeLauncher's GAME_SPEC.md
#   requires (Select on the cabinet, Back/View on a pad, F10 on keyboard).

const CABINET_PAD_NAME := "Twin USB Gamepad"
const CABINET_LAYOUT := "a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,back:b8,start:b9,leftx:a0,lefty:a1"

## Map All Inputs to P1 — when enabled, the joypad bindings of every p1_*
## action match any device, and every p2_* binding (keyboard and joypad) is
## rerouted onto the matching p1_* action, so all controls drive Player 1
## and the p2_* actions go silent.
## Can also be toggled at runtime via GameInput.map_all_inputs_to_p1.
@export var map_all_inputs_to_p1 := false: set = set_map_all_inputs_to_p1

var _p1_original_devices: Dictionary = {}  # joypad InputEvent -> original device id
var _p2_moved_events: Dictionary = {}      # p2 action StringName -> its InputEvents, now living on the p1 twin

func _ready() -> void:
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	for device in Input.get_connected_joypads():
		_map_if_cabinet_pad(device)
	if map_all_inputs_to_p1:
		_apply_pooling()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_exit"):
		get_tree().quit()

func set_map_all_inputs_to_p1(value: bool) -> void:
	if map_all_inputs_to_p1 == value:
		return
	map_all_inputs_to_p1 = value
	if not is_node_ready():
		return  # _ready applies the initial value
	if value:
		_apply_pooling()
	else:
		_revert_pooling()

func _apply_pooling() -> void:
	for action in InputMap.get_actions():
		if String(action).begins_with("p1_"):
			for event in InputMap.action_get_events(action):
				if _is_joypad_event(event):
					_p1_original_devices[event] = event.device
					event.device = -1
	for action in InputMap.get_actions():
		var action_name := String(action)
		if not action_name.begins_with("p2_"):
			continue
		var target := StringName("p1_" + action_name.substr(3))
		if not InputMap.has_action(target):
			continue
		var moved: Array[InputEvent] = []
		moved.assign(InputMap.action_get_events(action))
		for event in moved:
			InputMap.action_erase_event(action, event)
			InputMap.action_add_event(target, event)
		if not moved.is_empty():
			_p2_moved_events[action] = moved
	_release_player_actions()

func _revert_pooling() -> void:
	for action in _p2_moved_events:
		var target := StringName("p1_" + String(action).substr(3))
		for event in _p2_moved_events[action]:
			InputMap.action_erase_event(target, event)
			InputMap.action_add_event(action, event)
	_p2_moved_events.clear()
	for event in _p1_original_devices:
		event.device = _p1_original_devices[event]
	_p1_original_devices.clear()
	_release_player_actions()

func _release_player_actions() -> void:
	# The bindings just changed, so pressed state captured under the old
	# bindings can never see its matching release event — without this, a
	# control held across the toggle stays stuck pressed forever.
	for action in InputMap.get_actions():
		var action_name := String(action)
		if action_name.begins_with("p1_") or action_name.begins_with("p2_"):
			Input.action_release(action)

func _is_joypad_event(event: InputEvent) -> bool:
	return event is InputEventJoypadButton or event is InputEventJoypadMotion

func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		_map_if_cabinet_pad(device)

func _map_if_cabinet_pad(device: int) -> void:
	if Input.get_joy_name(device) != CABINET_PAD_NAME:
		return
	var guid := Input.get_joy_guid(device)
	if guid.is_empty():
		return
	Input.add_joy_mapping("%s,%s,%s" % [guid, CABINET_PAD_NAME, CABINET_LAYOUT], true)
