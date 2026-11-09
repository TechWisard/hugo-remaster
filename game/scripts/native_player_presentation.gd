class_name NativePlayerPresentation
extends Node3D
## Source render event 0x22020005: Hugo and his auxiliary ground shadow share
## the 300-Hz invulnerability bit. The shadow has its own static phase zero;
## it never inherits the primary action's normalization or animation phase.
## Godot support queries adapt the recovered floor cache, not the whole native
## terrain/step/contact solver. See docs/animation.md for that boundary.

const MaterialsScript = preload("res://scripts/native_materials.gd")
const NATIVE_TIMER_HZ: float = 300.0
const BLINK_MASK: int = 0x20
const SUPPORT_HALF_SIZE: float = 0.5
const SUPPORT_START_MARGIN: float = 0.05

var using_source_shadow: bool = false
var support_valid: bool = false
var support_height: float = 0.0
var height_scale: float = 1.0
var remaining_ticks: int = 0
var hidden_by_blink: bool = false
var shadow: Node3D

var _player: CharacterBody3D
var _body: Node3D
var _visual: Node3D
var _animation: HugoOriginalAnimation
var _height_coefficient: float = 0.44999998062849045


func configure(player: CharacterBody3D, body: Node3D, visual: Node3D,
		animation: HugoOriginalAnimation, info: Dictionary, base_directory: String) -> void:
	_player = player
	_body = body
	_visual = visual
	_animation = animation
	top_level = true
	# Read the physical pose after the player and moving world have advanced.
	process_physics_priority = 50
	var path: String = str(info.get("path", ""))
	if str(info.get("role", "")) != "ground_shadow" or path.is_empty() \
			or path.is_absolute_path() or ".." in path.split("/"):
		return
	var policy: Dictionary = info.get("render_policy", {}) as Dictionary
	var coefficient: float = float(policy.get("height_scale_coefficient_world", 0.0))
	if not is_finite(coefficient) or coefficient <= 0.0:
		return
	var resource_path: String = base_directory.path_join(path)
	if not ResourceLoader.exists(resource_path, "PackedScene"):
		return
	var packed: PackedScene = ResourceLoader.load(resource_path, "PackedScene") as PackedScene
	if packed == null:
		return
	var instance: Node = packed.instantiate()
	shadow = instance as Node3D
	if shadow == null:
		instance.free()
		return
	_height_coefficient = coefficient
	shadow.name = "SourceGroundShadow"
	add_child(shadow)
	MaterialsScript.apply_recursive(shadow)
	using_source_shadow = true
	# Do not display an unpositioned quad before the first physics support query.
	shadow.visible = false


func _physics_process(_delta: float) -> void:
	refresh()


func refresh() -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_body) \
			or not is_instance_valid(_visual) or not _player.is_inside_tree():
		return
	# The controller decrements this timer before this render-state update.
	# Rounding preserves integer source ticks despite floating-point seconds.
	remaining_ticks = maxi(0, roundi(float(_player.get("_invulnerability_remaining")) * NATIVE_TIMER_HZ))
	var death: bool = bool(_player.get("_death_state_active")) or bool(_player.get("pending_fatal"))
	var level: Node = _player.get_parent()
	if level != null and level.get("health") is int:
		death = death or int(level.get("health")) <= 0
	# Native +0x4C4 keeps a lethally knocked-back body visible throughout state5.
	hidden_by_blink = not death and (remaining_ticks & BLINK_MASK) != 0
	_body.visible = not hidden_by_blink
	if not using_source_shadow or not is_instance_valid(shadow):
		return
	var surface_replacement: bool = is_instance_valid(_animation) \
		and (_animation.current_action.begins_with("surface_death_") or _animation.current_action.begins_with("contact_death_"))
	support_valid = _update_support()
	shadow.visible = support_valid and not hidden_by_blink and not surface_replacement
	if not support_valid:
		return
	var height: float = _player.global_position.y - support_height
	# The original branch has no height/scale clamp and no added surface offset.
	var denominator: float = 1.0 + _height_coefficient * height
	if not is_finite(denominator) or denominator <= 0.0:
		shadow.visible = false
		return
	height_scale = 1.0 / denominator
	var pose: Transform3D = _visual.global_transform
	pose.origin.y = support_height
	pose.basis = pose.basis.scaled(Vector3.ONE * height_scale)
	global_transform = pose


func _update_support() -> bool:
	var feet: Vector3 = _player.global_position
	var lower_bound: float = minf(float(_player.get("fall_reset_height")) - 1.0, feet.y - 1.0)
	var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
	var found: bool = false
	var highest: float = -INF
	# Native 0x4211E0 samples the four axis-aligned XY corners at +/-50 source
	# units. Here the actual Godot collision world supplies support below feet;
	# source terrain lookup also has other fallbacks and no input-Z ray limit.
	for x: float in [-SUPPORT_HALF_SIZE, SUPPORT_HALF_SIZE]:
		for z: float in [-SUPPORT_HALF_SIZE, SUPPORT_HALF_SIZE]:
			var start: Vector3 = feet + Vector3(x, SUPPORT_START_MARGIN, z)
			var end: Vector3 = Vector3(start.x, lower_bound, start.z)
			var query := PhysicsRayQueryParameters3D.create(start, end, 1, [_player.get_rid()])
			# Imported native terrain uses backface_collision for its source winding.
			query.hit_back_faces = true
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty():
				highest = maxf(highest, (hit.position as Vector3).y)
				found = true
	if found:
		support_height = highest
	return found
