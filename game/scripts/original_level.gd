class_name OriginalLevel
extends Node3D
## Reconstructed source scene. Geometry and identifiers come from the importer.

signal progress_changed(run: Dictionary)
signal level_finished
signal menu_requested
signal restart_requested
signal next_requested
signal ready_to_play

const PlayerScript = preload("res://scripts/player.gd")
const CameraScript = preload("res://scripts/native_camera.gd")
const HUDScript = preload("res://scripts/hud.gd")
const ActorScript = preload("res://scripts/native_state_actor.gd")
const MotionScript = preload("res://scripts/native_actor_motion.gd")
const SamplerScript = preload("res://scripts/original_animation.gd")
const EffectsScript = preload("res://scripts/native_effects.gd")
const BackgroundShader = preload("res://scripts/native_background.gdshader")
const GraphScript = preload("res://scripts/native_graph_colliders.gd")
const ScopeScript = preload("res://scripts/native_scopes.gd")
const SoundScript = preload("res://scripts/native_audio.gd")
const SpeakerScript = preload("res://scripts/native_speaker.gd")
const NativeMaterialsScript = preload("res://scripts/native_materials.gd")

var entry: Dictionary
var data: Dictionary
var gameplay: Dictionary
var native_rules: Dictionary = {}
var qualified_level_count: int = 0
var starting_lives: int = 4
var restored_run: Dictionary = {}
var chapter_number: int = 1
var has_next: bool = true
var player: HugoPlayer
var camera_rig: HugoNativeCamera
var hud: RemasterHUD
var level_geometry: Node3D
var owners: Dictionary = {}
var owner_nodes: Dictionary = {}
var collected: Dictionary = {}
var defeated: Dictionary = {}
var activated: Dictionary = {}
var checkpoint_id: String = ""
var elapsed_seconds: float = 0.0
var completed: bool = false
var finish_rewards_applied: bool = false
var spawn_point := Vector3.ZERO
var scene_bounds := AABB()
var health: int = 100
var max_health: int = 100
var lives: int = 3
var diamonds: int = 0
var total_diamonds: int = 0
var difficulty: int = 1
var state_actors: Dictionary = {}
var actor_motions: Dictionary = {}
var effects: NativeEffects
var pickup_areas: Dictionary = {}
var pickup_graphs: Dictionary = {}
var player_graph: NativeGraphColliders
var scopes: NativeScopes
var _scope_wrappers: Dictionary = {}
var _owner_areas: Dictionary = {}
var _scope_removed_actors: Dictionary = {}
var speakers: Dictionary = {}
var _sampler: HugoOriginalAnimation
var _event_queue: Array[Dictionary] = []
var _stay_triggers: Array[Dictionary] = []
var _moved_owners: Dictionary = {}
var _backgrounds: Array[Dictionary] = []
var _save_clock: float = 0.0
var _pickup_sound: AudioStreamPlayer
var _damage_remaining: float = 0.0
var _collision_count: int = 0
var _trigger_count: int = 0
var _pickup_count: int = 0
var _ready_ok: bool = false
var _checkpoint_state: Dictionary = {}
var _restoring_world: bool = false
var _death_in_progress: bool = false
var _collecting: Dictionary = {}
var _death_surface: Dictionary = {}


func _ready() -> void:
	RemasterInput.configure()
	var path: String = "res://assets/generated/" + str(entry.get("geometry_path", ""))
	if not ResourceLoader.exists(path, "PackedScene"):
		push_error("Missing generated level: " + path)
		return
	level_geometry = (load(path) as PackedScene).instantiate() as Node3D
	add_child(level_geometry)
	_enable_vertex_colors(level_geometry)
	for owner: Dictionary in data.get("owners", []):
		owners[str(owner.id)] = owner
		var found: Node = level_geometry.find_child(str(owner.id), true, false)
		if found is Node3D:
			owner_nodes[str(owner.id)] = found
	var bounds_value: Variant = data.get("bounds", entry.get("bounds", []))
	if bounds_value is Array and bounds_value.size() == 2:
		scene_bounds = AABB(_vector(bounds_value[0]), _vector(bounds_value[1]) - _vector(bounds_value[0]))
	_restore_flags()
	finish_rewards_applied = bool(restored_run.get("finish_rewards_applied", false))
	var health_bases: Array = native_rules.get("maximum_health_base_by_difficulty", [11, 10, 8])
	max_health = int(health_bases[clampi(difficulty, 0, 2)]) + qualified_level_count
	health = clampi(int(restored_run.get("health", max_health)), 1, max_health)
	lives = clampi(int(restored_run.get("lives", starting_lives)), 0, 20)
	if lives <= 0:
		health = 0
	_build_environment()
	_build_collision()
	spawn_point = _find_spawn()
	_create_player()
	_prepare_native_scopes()
	_create_motions()
	_create_player_logic()
	hud = HUDScript.new()
	add_child(hud)
	hud.set_chapter(str(entry.get("title", entry.get("source_name", ""))), chapter_number, has_next)
	hud.restart_requested.connect(func() -> void: restart_requested.emit())
	hud.menu_requested.connect(func() -> void: _save_progress(); menu_requested.emit())
	hud.next_requested.connect(func() -> void: next_requested.emit())
	_create_entities()
	_create_speakers()
	_create_effects()
	_restore_checkpoint()
	if is_instance_valid(scopes):
		scopes.start()
	if restored_run.get("checkpoint_state") is Dictionary:
		_checkpoint_state = restored_run.checkpoint_state.duplicate(true)
	else:
		save_native_world()
	if bool(restored_run.get("death_pending", false)) and lives > 0:
		# A modern save can be taken during a native death animation. Its life
		# cost is already committed, so resume the checkpoint without charging again.
		restore_native_world()
	_update_hud()
	hud.toast(str(entry.get("title", "")), 4.0)
	_ready_ok = true
	if lives <= 0:
		player.controls_enabled = false
		hud.game_over()
	ready_to_play.emit()
	if bool(restored_run.get("completed", false)):
		finish_level.call_deferred()


func _process(_delta: float) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	for background: Dictionary in _backgrounds:
		var visual: Node3D = background.node
		visual.global_position = camera.global_position + background.offset


func _physics_process(delta: float) -> void:
	if not _ready_ok or completed:
		return
	elapsed_seconds += delta
	_update_collecting(delta)
	_damage_remaining = maxf(0.0, _damage_remaining - delta)
	_dispatch_events()
	_apply_surface_rules()
	for trigger: Dictionary in _stay_triggers:
		var area: Area3D = trigger.area
		if _native_owner_active(str(trigger.id)) and area.overlaps_body(player):
			queue_native_event(trigger.event, str(trigger.id))
			if int(trigger.damage) > 0:
				damage_player(int(trigger.damage), area.global_position)
	_save_clock += delta
	if _save_clock >= 15.0:
		_save_progress()
	_update_hud()


func _restore_flags() -> void:
	for id: Variant in restored_run.get("collected", []):
		if owners.has(str(id)):
			collected[str(id)] = true
	for id: Variant in restored_run.get("defeated", []):
		if owners.has(str(id)):
			defeated[str(id)] = true
	for id: Variant in restored_run.get("activated", []):
		if owners.has(str(id)):
			activated[str(id)] = true
	checkpoint_id = str(restored_run.get("checkpoint_id", ""))
	elapsed_seconds = maxf(float(restored_run.get("elapsed", 0.0)), 0.0)
	for id: String in restored_run.get("moved", {}):
		if owner_nodes.has(id):
			var at: Vector3 = _vector(restored_run.moved[id])
			if at.is_finite():
				(owner_nodes[id] as Node3D).global_position = at
				_moved_owners[id] = [at.x, at.y, at.z]


func _find_spawn() -> Vector3:
	var native_spawn: Variant = gameplay.get("spawn", {})
	if native_spawn is Dictionary:
		for key: String in ["position", "godot_position"]:
			if native_spawn.has(key):
				return _vector(native_spawn[key]) + Vector3.UP * 0.03
	elif native_spawn is Array and native_spawn.size() == 3:
		return _vector(native_spawn) + Vector3.UP * 0.03
	if data.get("spawn") is Array:
		return _vector(data.spawn) + Vector3.UP * 0.03
	for owner: Dictionary in owners.values():
		if int(owner.type) == 10000:
			return _vector(owner.position) + Vector3.UP * 0.03
	push_error("Source level has no decoded Hugo spawn")
	return scene_bounds.get_center()


func _create_player() -> void:
	player = PlayerScript.new()
	player.name = "Hugo"
	player.character_height = 3.33077
	var size_ratio: float = player.character_height / 1.7
	if not player.set_native_configuration(gameplay.get("native_player", {}).get("movement", {})):
		player.walk_speed *= size_ratio
		player.sprint_speed *= size_ratio
		player.jump_height *= size_ratio
		player.ground_acceleration *= size_ratio
		player.ground_braking *= size_ratio
		player.air_acceleration *= size_ratio
		player.terminal_velocity *= size_ratio
	player.model_yaw_degrees = 180.0
	player.position = spawn_point
	player.fall_reset_height = minf(scene_bounds.position.y - 30.0, spawn_point.y - 45.0)
	add_child(player)
	var facing: float = 0.0
	for source_owner: Dictionary in owners.values():
		if int(source_owner.type) == 10000:
			var matrix: Array = source_owner.get("matrix", [])
			if matrix.size() == 16:
				var forward := Vector3(float(matrix[8]), 0.0, float(matrix[10]))
				if forward.length_squared() > 0.01:
					facing = atan2(-forward.x, -forward.z)
			break
	player.visual_root.rotation.y = facing
	player.set_checkpoint(spawn_point)
	player.respawned.connect(_on_respawn)
	if player.has_signal("reset_requested"):
		player.set("native_reset_handling", true)
		player.connect("reset_requested", _on_reset_requested)
	camera_rig = CameraScript.new()
	camera_rig.target_height = 1.05 * size_ratio
	camera_rig.orbit_distance = 6.5 * size_ratio
	camera_rig.minimum_distance = 2.0 * size_ratio
	camera_rig.maximum_distance = 12.0 * size_ratio
	camera_rig.initial_pitch_degrees = -16.0
	camera_rig.initial_yaw_degrees = rad_to_deg(facing)
	camera_rig.configure(gameplay.get("camera", {}), data.get("native_transform_tracks", {}))
	add_child(camera_rig)
	camera_rig.set_target(player)
	player.movement_camera = camera_rig.camera
	for id: String in owners:
		if int(owners[id].type) == 10000 and owner_nodes.has(id):
			(owner_nodes[id] as Node3D).hide()


func _build_collision() -> void:
	var collision_meshes: Dictionary = data.get("native_collision_meshes", {})
	var native_owners: Dictionary = gameplay.get("owners", {})
	for id: String in owners:
		var owner: Dictionary = owners[id]
		if not owner_nodes.has(id):
			continue
		var role: String = str(owner.get("collision_role", ""))
		var visual: Node3D = owner_nodes[id]
		if role == "segment":
			var key: String = str(owner.get("collision_mesh_key", ""))
			var mesh_data: Dictionary = collision_meshes.get(key, {})
			if mesh_data.is_empty():
				# A missing native tree means no collision, including the source g058 segment.
				continue
			var faces := PackedVector3Array()
			for point: Array in mesh_data.get("faces", []):
				faces.append(_vector(point))
			if faces.is_empty() or faces.size() % 3 != 0:
				continue
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			shape.backface_collision = true
			var body := StaticBody3D.new()
			body.name = "NativeCollision"
			body.collision_layer = 1
			body.collision_mask = 0
			body.set_meta("native_owner", id)
			body.set_meta("native_surfaces", mesh_data.get("surface_types", []))
			var collider := CollisionShape3D.new()
			collider.shape = shape
			body.add_child(collider)
			visual.add_child(body)
			_collision_count += 1
		elif role == "platform":
			var native: Dictionary = native_owners.get(id, {})
			var bounds: Dictionary = native.get("bounds", {})
			if not bounds.has("source_min") or not bounds.has("source_max"):
				continue
			var low: Vector3 = _source_vector(bounds.source_min)
			var high: Vector3 = _source_vector(bounds.source_max)
			var body := AnimatableBody3D.new()
			body.name = "NativePlatform"
			body.sync_to_physics = false
			body.collision_layer = 1
			body.collision_mask = 0
			body.set_meta("native_owner", id)
			var collider := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = (high - low).abs().max(Vector3.ONE * 0.02)
			collider.shape = shape
			collider.position = (high + low) * 0.5
			body.add_child(collider)
			visual.add_child(body)
			_collision_count += 1


func _prepare_native_scopes() -> void:
	var policy: Dictionary = data.get("native_scope_policy", {})
	if policy.is_empty():
		push_error("Imported level lacks native_scope_policy; reimport the source assets")
		return
	scopes = ScopeScript.new()
	scopes.policy = policy
	scopes.level = self
	for id: String in owners:
		scopes.owner_groups[id] = int(owners[id].get("source_group", data.get("main_group", -1)))
	for id: String in gameplay.get("owners", {}):
		if not scopes.owner_groups.has(id):
			scopes.owner_groups[id] = int(gameplay.owners[id].get("source", {}).get("group", -1))
	for id: String in restored_run.get("scope_removed_actors", []):
		if owners.has(id):
			_scope_removed_actors[id] = true
	scopes.prepare(restored_run.get("scopes", {}))
	add_child(scopes)
	# A separate visibility parent preserves each actor's own action/removed
	# visibility across activation-range suspension.
	for id: String in owner_nodes:
		var visual: Node3D = owner_nodes[id]
		var wrapper := Node3D.new()
		wrapper.name = "Scope_" + id
		visual.get_parent().add_child(wrapper)
		visual.reparent(wrapper, true)
		_scope_wrappers[id] = wrapper
		wrapper.visible = scopes.is_owner_active(id)


func _native_owner_resident(id: String) -> bool:
	return not is_instance_valid(scopes) or scopes.is_owner_resident(id)


func _native_owner_active(id: String) -> bool:
	return not is_instance_valid(scopes) or scopes.is_owner_active(id)


func set_native_owner_active(id: String, resident: bool, active: bool) -> void:
	if _scope_wrappers.has(id):
		(_scope_wrappers[id] as Node3D).visible = active
	if actor_motions.has(id):
		(actor_motions[id] as NativeActorMotion).set_physics_process(active)
	if state_actors.has(id):
		(state_actors[id] as NativeStateActor).set_native_scope(resident, active)
	if pickup_graphs.has(id):
		var starts_inactive: bool = bool(gameplay.owners[id].get("pickup", {}).get("starts_inactive", false))
		(pickup_graphs[id] as NativeGraphColliders).enabled = active and not collected.has(id) and not _collecting.has(id) and (not starts_inactive or activated.has(id))
	if speakers.has(id):
		(speakers[id] as NativeSpeaker).set_physics_process(active)
	var kind: int = int(owners.get(id, {}).get("type", 0))
	for area: Area3D in _owner_areas.get(id, []):
		area.set_deferred("monitoring", active and kind != 10301)
	if owner_nodes.has(id) and kind != 10300:
		for body: Node in (owner_nodes[id] as Node3D).find_children("*", "PhysicsBody3D", true, false):
			(body as PhysicsBody3D).collision_layer = 1 if active else 0


func native_scope_unloaded(group: int) -> void:
	for id: String in scopes.owner_groups:
		if int(scopes.owner_groups[id]) != group:
			continue
		if state_actors.has(id):
			var actor: NativeStateActor = state_actors[id]
			if not _restoring_world and actor.removed_after_scope_unload():
				_scope_removed_actors[id] = true
			actor.set_native_scope(false, false)
		_collecting.erase(id)
		if speakers.has(id):
			(speakers[id] as NativeSpeaker).reset_native_world()
		if owner_nodes.has(id):
			for sound: Node in (owner_nodes[id] as Node3D).find_children("*", "AudioStreamPlayer3D", true, false):
				if sound.has_method("stop_source"):
					sound.call("stop_source")


func native_scope_loaded(group: int) -> void:
	for id: String in scopes.owner_groups:
		if int(scopes.owner_groups[id]) != group:
			continue
		if state_actors.has(id):
			var actor: NativeStateActor = state_actors[id]
			actor.set_native_scope(true, scopes.is_owner_active(id))
			var saved: Dictionary = _checkpoint_state.get("native_actors", {}).get(id, {}) if _restoring_world else {}
			actor.reset_native_checkpoint(_scope_removed_actors.has(id), saved)
		elif pickup_graphs.has(id):
			activated.erase(id)
			_moved_owners.erase(id)
			var native: Dictionary = gameplay.owners[id]
			if owner_nodes.has(id):
				var visual: Node3D = owner_nodes[id]
				visual.visible = not collected.has(id) and not bool(native.get("pickup", {}).get("starts_inactive", false))
			if actor_motions.has(id):
				var motion: NativeActorMotion = actor_motions[id]
				motion.autonomous = true
				motion.reset_native_checkpoint()
		elif actor_motions.has(id):
			(actor_motions[id] as NativeActorMotion).reset_native_checkpoint()
		if int(owners.get(id, {}).get("type", 0)) in [10203, 10600]:
			activated.erase(id)
		if speakers.has(id):
			(speakers[id] as NativeSpeaker).reset_native_world()


func _create_motions() -> void:
	_sampler = SamplerScript.new()
	add_child(_sampler)
	var native_owners: Dictionary = gameplay.get("owners", {})
	for id: String in owners:
		var source: Dictionary = owners[id]
		if not owner_nodes.has(id) or int(source.type) == 10000:
			continue
		if source.get("render_policy", "") == "camera_centered":
			_backgrounds.append({"node": owner_nodes[id], "offset": _vector(source.get("camera_offset", [0, 0, 0]))})
			_prepare_background_material(owner_nodes[id])
		var native: Dictionary = native_owners.get(id, {})
		if int(source.type) == 10301:
			native = native.duplicate(true)
			native["motion"] = {"visual_period_seconds": 2.0, "visual_initial_phase": 0.0, "wrap": true}
		if source.get("actions", []).is_empty() and not native.has("motion"):
			continue
		var motion: NativeActorMotion = MotionScript.new()
		motion.source = source
		motion.native = native
		motion.owner_visual = owner_nodes[id]
		motion.tracks = data.get("native_transform_tracks", {})
		motion.sampler = _sampler
		motion.player = player
		motion.autonomous = int(source.type) != 10300
		actor_motions[id] = motion
		add_child(motion)
		motion.set_physics_process(_native_owner_active(id))


func _create_player_logic() -> void:
	var id: String = str(gameplay.get("native_player", {}).get("id", ""))
	if not owners.has(id):
		return
	player_graph = GraphScript.new()
	player_graph.source = owners[id]
	player_graph.player = player
	player_graph.space = self
	player_graph.tracks = data.get("native_transform_tracks", {})
	player_graph.sampler = _sampler
	add_child(player_graph)


func _create_effects() -> void:
	if data.get("effect_definitions", {}).is_empty():
		return
	effects = EffectsScript.new()
	effects.source = data
	effects.owner_nodes = owner_nodes
	effects.player = player
	add_child(effects)


func _create_speakers() -> void:
	for id: String in gameplay.get("owners", {}):
		var native: Dictionary = gameplay.owners[id]
		if not native.has("speaker"):
			continue
		var speaker: NativeSpeaker = SpeakerScript.new()
		speaker.native = native
		speaker.tracks = data.get("native_transform_tracks", {})
		speaker.sampler = _sampler
		speaker.listener = player
		speakers[id] = speaker
		add_child(speaker)
		speaker.set_physics_process(_native_owner_active(id))


func _create_entities() -> void:
	var native_owners: Dictionary = gameplay.get("owners", {})
	for id: String in owners:
		var owner: Dictionary = owners[id]
		var kind: int = int(owner.type)
		var native: Dictionary = native_owners.get(id, {})
		if kind == 10301:
			var pickup: Dictionary = native.get("pickup", {})
			var value: int = int(pickup.get("diamonds", 0))
			total_diamonds += maxi(value, 0)
			if collected.has(id):
				diamonds += maxi(value, 0)
				_hide_owner(id)
			var area := _owner_area(owner, native, 0.7)
			if owner_nodes.has(id):
				area.reparent(owner_nodes[id], true)
			area.name = "Pickup_" + id
			pickup_areas[id] = area
			# Retain the volume for diagnostics; native graph boxes award the item.
			area.monitoring = false
			var graph: NativeGraphColliders = GraphScript.new()
			graph.source = owner
			graph.owner_visual = owner_nodes.get(id)
			graph.motion = actor_motions.get(id)
			graph.space = self
			graph.tracks = data.get("native_transform_tracks", {})
			graph.sampler = _sampler
			graph.collided.connect(func(other: NativeGraphColliders, _own: Dictionary, _other: Dictionary) -> void:
				if other.player == player:
					collect_pickup(id, native, area))
			pickup_graphs[id] = graph
			add_child(graph)
			if collected.has(id) or (bool(pickup.get("starts_inactive", false)) and not activated.has(id)):
				_hide_owner(id)
				graph.enabled = false
			_pickup_count += 1
		elif kind == 10204:
			_hide_owner(id)
			var area := _owner_area(owner, native, 1.0)
			area.name = "Fall_" + id
			area.body_entered.connect(func(body: Node3D) -> void:
				if body == player and not completed and _native_owner_active(id):
					damage_player(int(native.get("damage", 1000)), area.global_position))
			_trigger_count += 1
		elif kind == 10300 and owner_nodes.has(id) and native.has("state_machine"):
			var actor: NativeStateActor = ActorScript.new()
			actor.source_id = id
			actor.native = native
			actor.visual = owner_nodes[id]
			actor.level = self
			actor.motion = actor_motions.get(id)
			actor.scope_resident = _native_owner_resident(id)
			actor.scope_active = _native_owner_active(id)
			actor.restore(restored_run.get("actors", {}).get(id, {}))
			state_actors[id] = actor
			add_child(actor)
		elif kind == 10200 and native.has("events"):
			_hide_owner(id)
			var area := _owner_area(owner, native, 0.0)
			var events: Dictionary = native.events
			area.body_entered.connect(func(body: Node3D) -> void:
				if body == player and _native_owner_active(id):
					queue_native_event(events.get("on_enter", {}), id))
			area.body_exited.connect(func(body: Node3D) -> void:
				if body == player and _native_owner_active(id):
					queue_native_event(events.get("on_exit", {}), id))
			_stay_triggers.append({"area": area, "event": events.get("on_stay", {}),
				"id": id, "damage": native.get("contact_damage", 0)})
			_trigger_count += 1
		elif kind == 10203 and native.get("events") is Array:
			_hide_owner(id)
			var area := _owner_area(owner, native, 0.0)
			area.body_entered.connect(func(body: Node3D) -> void:
				if body != player or not _native_owner_active(id) or (native.get("once", false) and activated.has(id)):
					return
				activated[id] = true
				for event: Dictionary in native.events:
					queue_native_event(event, id))
			_trigger_count += 1
		elif kind == 10602:
			_hide_owner(id)
			var area := _owner_area(owner, native, 1.2)
			area.name = "Exit_" + id
			area.body_entered.connect(func(body: Node3D) -> void:
				if body == player and _native_owner_active(id):
					finish_level())
			_trigger_count += 1
		elif kind == 10600:
			_hide_owner(id)
			# Native phase2 checks the camera against a source plane each frame.
			# NativeScopes owns this trigger; no player Area is created.
			_trigger_count += 1
	var expected: int = int(gameplay.get("health_bar", {}).get("diamonds_total_native", total_diamonds))
	total_diamonds = expected


func _owner_area(owner: Dictionary, native: Dictionary, padding: float) -> Area3D:
	var area := Area3D.new()
	var id: String = str(owner.id)
	if not _owner_areas.has(id):
		_owner_areas[id] = []
	(_owner_areas[id] as Array).append(area)
	area.set_meta("native_owner", id)
	area.collision_layer = 0
	area.collision_mask = 1
	var bounds: Variant = native.get("bounds", owner.get("bounds", []))
	var center: Vector3 = _vector(owner.get("position", [0, 0, 0]))
	var size := Vector3.ONE * padding * 2.0
	if bounds is Dictionary and bounds.has("source_min") and bounds.has("source_max") and owner.has("matrix"):
		# The native box is oriented with its owner; avoid expanding it to a world AABB.
		var low: Vector3 = _source_vector(bounds.source_min)
		var high: Vector3 = _source_vector(bounds.source_max)
		var shape := BoxShape3D.new()
		var extent: Vector3 = (high - low).abs()
		shape.size = Vector3(maxf(extent.x, 0.02), maxf(extent.y, 0.02), maxf(extent.z, 0.02))
		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.position = (low + high) * 0.5
		area.add_child(collision)
		area.transform = _matrix(owner.matrix)
		add_child(area)
		return area
	elif bounds is Array and bounds.size() == 2:
		var low: Vector3 = _vector(bounds[0])
		var high: Vector3 = _vector(bounds[1])
		center = (low + high) * 0.5
		size = (high - low).abs() + Vector3.ONE * padding
	area.position = center
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(size.x, 0.3), maxf(size.y, 0.3), maxf(size.z, 0.3))
	var collider := CollisionShape3D.new()
	collider.shape = box
	area.add_child(collider)
	add_child(area)
	return area


func collect_pickup(id: String, native: Dictionary, area: Area3D = null) -> bool:
	if collected.has(id) or _collecting.has(id) or completed or not _native_owner_active(id):
		return false
	if bool(native.get("pickup", {}).get("starts_inactive", false)) and not activated.has(id):
		return false
	_collecting[id] = {"elapsed": 0.0, "native": native,
		"duration": float(native.get("pickup", {}).get("collection_delay_seconds", 0.6))}
	if actor_motions.has(id):
		var motion: NativeActorMotion = actor_motions[id]
		motion.autonomous = false
		motion.sample_state(1, 0.0, 0.0, {"animate_transform": false})
	if area != null:
		area.set_deferred("monitoring", false)
	if pickup_graphs.has(id):
		(pickup_graphs[id] as NativeGraphColliders).enabled = false
	play_native_sound(native.get("collection_sound", {}), (owner_nodes[id] as Node3D).global_position if owner_nodes.has(id) else player.global_position, owner_nodes.get(id))
	return true


func _update_collecting(delta: float) -> void:
	for id: String in _collecting.keys():
		if not _native_owner_active(id):
			continue
		var pending: Dictionary = _collecting[id]
		pending.elapsed = float(pending.elapsed) + delta
		var phase: float = float(pending.elapsed) / maxf(float(pending.duration), 0.0001)
		if actor_motions.has(id):
			(actor_motions[id] as NativeActorMotion).sample_state(1, minf(phase, 1.0), 0.0, {"animate_transform": false})
		if phase <= 1.0:
			continue
		collected[id] = true
		var pickup: Dictionary = pending.native.get("pickup", {})
		diamonds += maxi(int(pickup.get("diamonds", 0)), 0)
		lives = mini(lives + int(pickup.get("lives", 0)), 20)
		if bool(pickup.get("health", false)):
			var amounts: Array = pickup.get("healing_by_difficulty", [20, 10, 5])
			health = mini(health + int(amounts[clampi(difficulty, 0, 2)]), max_health)
		_hide_owner(id)
		_collecting.erase(id)
		_save_progress()


func _activate_segment(id: String) -> void:
	if activated.has(id):
		return
	activated[id] = true
	_save_progress()


func _on_respawn() -> void:
	if hud:
		hud.toast("Возвращение к контрольной точке", 2.0)


func _on_reset_requested(reason: String) -> void:
	if completed or _death_in_progress or lives <= 0:
		return
	if reason == "fall":
		_begin_death.call_deferred()
	else:
		restore_native_world.call_deferred()


func finish_level() -> void:
	if completed:
		return
	completed = true
	player.controls_enabled = false
	camera_rig.controls_enabled = false
	_save_progress()
	hud.finish(elapsed_seconds)
	level_finished.emit()


func run_state() -> Dictionary:
	var actor_states: Dictionary = {}
	for id: String in state_actors:
		actor_states[id] = (state_actors[id] as NativeStateActor).snapshot()
	var pending_death: bool = _death_in_progress or (health <= 0 and lives > 0 and not completed)
	var saved_lives: int = lives
	if pending_death and not _death_in_progress:
		# damage_player saves before its deferred death handler spends the life.
		saved_lives = maxi(lives - 1, 0)
	return {"collected": collected.keys(), "defeated": defeated.keys(), "activated": activated.keys(),
		"completed": completed, "finish_rewards_applied": finish_rewards_applied,
		"checkpoint_id": checkpoint_id, "elapsed": elapsed_seconds, "actors": actor_states,
		"health": health, "lives": saved_lives, "diamonds": diamonds, "moved": _moved_owners,
		"death_pending": pending_death,
		"player_position": _array(player.global_position), "player_facing": player.visual_root.global_rotation.y,
		"checkpoint_state": _checkpoint_state,
		"scopes": scopes.snapshot() if is_instance_valid(scopes) else {},
		"scope_removed_actors": _scope_removed_actors.keys(),
		"camera": camera_rig.native_checkpoint_snapshot()}


func _save_progress() -> void:
	if _restoring_world:
		return
	_save_clock = 0.0
	progress_changed.emit(run_state())


func _update_hud() -> void:
	if hud:
		hud.set_progress(diamonds, total_diamonds, elapsed_seconds)
		hud.set_vitals(health, max_health, maxi(lives - 1, 0))


func queue_native_event(event: Dictionary, sender: String = "") -> void:
	if int(event.get("event", 0)) == 0 or event.get("target") == null:
		return
	if (not sender.is_empty() and not _native_owner_resident(sender)) or not _native_owner_resident(str(event.target)):
		return
	if _event_queue.size() < 4096:
		var queued: Dictionary = event.duplicate()
		queued["sender"] = sender
		_event_queue.append(queued)


func _dispatch_events() -> void:
	var budget: int = mini(_event_queue.size(), 256)
	for i: int in range(budget):
		var event: Dictionary = _event_queue.pop_front()
		var target: String = str(event.get("target", ""))
		var code: int = int(event.get("event", 0))
		var sender: String = str(event.get("sender", ""))
		if not _native_owner_resident(target) or (not sender.is_empty() and not _native_owner_resident(sender)):
			continue
		var param1: Variant = event.get("param1", 0)
		if state_actors.has(target):
			(state_actors[target] as NativeStateActor).receive_event(code, param1, event.get("param2", 0), sender)
		elif pickup_areas.has(target) and code == 0x22000002 and not collected.has(target):
			if activated.has(target) or _collecting.has(target) or not bool(gameplay.owners[target].get("pickup", {}).get("starts_inactive", false)):
				continue
			activated[target] = true
			if owner_nodes.has(target):
				var visual: Node3D = owner_nodes[target]
				visual.show()
				if owner_nodes.has(sender):
					visual.global_transform = (owner_nodes[sender] as Node3D).global_transform
				var at: Vector3 = visual.global_position
				_moved_owners[target] = [at.x, at.y, at.z]
			if pickup_graphs.has(target):
				(pickup_graphs[target] as NativeGraphColliders).enabled = _native_owner_active(target)
			if actor_motions.has(target):
				var motion: NativeActorMotion = actor_motions[target]
				motion.autonomous = true
				motion.reset_playback()
		elif target == str(gameplay.get("native_player", {}).get("id", "")):
			if code == 0x22000013 and owner_nodes.has(sender):
				set_native_checkpoint(sender, (owner_nodes[sender] as Node3D).global_position)
			elif code in [0x22000003, 0x22000012]:
				damage_player(int(param1), player.global_position, 1.0, code)
		elif target == str(gameplay.get("health_bar", {}).get("id", "")):
			match code:
				0x22000005: diamonds += int(param1)
				0x22000006: health = mini(health + [20, 10, 5][difficulty], max_health)
				0x22000007: lives = clampi(lives + int(param1), 0, 20)
				0x22000040: finish_level()
		elif target == str(gameplay.get("camera", {}).get("id", "")):
			if camera_rig.has_method("receive_native_event"):
				camera_rig.call("receive_native_event", event)
		elif speakers.has(target):
			(speakers[target] as NativeSpeaker).receive_native_event(event)
		if code == 0x22000030:
			save_native_world()
		elif code == 0x22000031:
			restore_native_world.call_deferred()


func set_native_checkpoint(id: String, position: Vector3) -> void:
	if not owners.has(id):
		return
	checkpoint_id = id
	activated[id] = true
	player.set_checkpoint(position + Vector3.UP * 0.05)
	hud.toast("Контрольная точка", 3.0)
	save_native_world.call_deferred()


func _restore_checkpoint() -> void:
	if checkpoint_id in gameplay.get("checkpoints", []) and owner_nodes.has(checkpoint_id):
		player.set_checkpoint((owner_nodes[checkpoint_id] as Node3D).global_position + Vector3.UP * 0.05)
		player.respawn()
	var resumed: Variant = restored_run.get("player_position")
	if resumed is Array and resumed.size() == 3:
		var at: Vector3 = _vector(resumed)
		if at.is_finite() and scene_bounds.grow(40.0).has_point(at):
			player.global_position = at
			player.visual_root.global_rotation.y = float(restored_run.get("player_facing", 0.0))
			camera_rig.snap_to_target()
	if restored_run.has("diamonds"):
		diamonds = maxi(int(restored_run.diamonds), 0)
	if restored_run.get("camera") is Dictionary:
		camera_rig.restore_native_checkpoint(restored_run.camera)


func save_native_world() -> void:
	if _restoring_world or not is_instance_valid(player):
		return
	var removed_actors: Array[String] = []
	for id: String in _scope_removed_actors:
		removed_actors.append(id)
	var native_actors: Dictionary = {}
	for id: String in state_actors:
		var actor: NativeStateActor = state_actors[id]
		if actor.removed and _native_owner_resident(id) and id not in removed_actors:
			removed_actors.append(id)
		if actor.has_method("native_checkpoint_snapshot"):
			native_actors[id] = actor.call("native_checkpoint_snapshot")
	var checkpoint_position: Vector3 = spawn_point
	if owner_nodes.has(checkpoint_id):
		checkpoint_position = (owner_nodes[checkpoint_id] as Node3D).global_position + Vector3.UP * 0.05
	_checkpoint_state = {"collected": collected.keys(), "removed_actors": removed_actors,
		"native_actors": native_actors, "activated": activated.keys(),
		"diamonds": diamonds, "checkpoint_id": checkpoint_id,
		"checkpoint_position": _array(checkpoint_position),
		"checkpoint_facing": player.visual_root.global_rotation.y,
		"resident_groups": scopes.resident_groups.duplicate() if is_instance_valid(scopes) else [],
		"camera": camera_rig.native_checkpoint_snapshot()}
	_save_progress()


func restore_native_world() -> void:
	if _restoring_world or _checkpoint_state.is_empty():
		return
	_restoring_world = true
	var was_suspended: bool = scopes.suspended if is_instance_valid(scopes) else false
	if is_instance_valid(scopes):
		scopes.suspended = true
	_event_queue.clear()
	_collecting.clear()
	_death_surface.clear()
	if is_instance_valid(effects):
		effects.reset_native_world()
	collected.clear()
	for id: String in _checkpoint_state.get("collected", []):
		if owners.has(id):
			collected[id] = true
	diamonds = maxi(int(_checkpoint_state.get("diamonds", 0)), 0)
	checkpoint_id = str(_checkpoint_state.get("checkpoint_id", ""))
	activated.clear()
	for id: String in _checkpoint_state.get("activated", []):
		if owners.has(id):
			activated[id] = true
	_scope_removed_actors.clear()
	for id: String in _checkpoint_state.get("removed_actors", []):
		if owners.has(id):
			_scope_removed_actors[id] = true
	health = max_health
	_damage_remaining = 0.0
	# Main-scene actors receive their native event31; child actors are recreated
	# by the restored scope membership, preserving the saved removed-ID set.
	for id: String in state_actors:
		if int(owners[id].get("source_group", -1)) == int(data.get("main_group", -2)):
			(state_actors[id] as NativeStateActor).reset_native_checkpoint(_scope_removed_actors.has(id),
				_checkpoint_state.get("native_actors", {}).get(id, {}))
	if is_instance_valid(scopes):
		scopes.restore_membership({"resident_groups": _checkpoint_state.get("resident_groups", scopes.policy.get("initial_segment_groups", []))})
	var at: Vector3 = _vector(_checkpoint_state.get("checkpoint_position", _array(spawn_point)))
	player.visual_root.global_rotation.y = float(_checkpoint_state.get("checkpoint_facing", 0.0))
	player.set_checkpoint(at)
	player.respawn()
	player.controls_enabled = lives > 0
	if not camera_rig.restore_native_checkpoint(_checkpoint_state.get("camera", {})):
		camera_rig.snap_to_target()
	if is_instance_valid(scopes):
		scopes.start()
		scopes.suspended = was_suspended
	_restoring_world = false
	_save_progress()


func damage_player(amount: int, origin: Vector3, knockback: float = 1.0, event_code: int = 0x22000003) -> bool:
	if amount <= 0 or completed or lives <= 0 or (_damage_remaining > 0.0 and amount < 1000) or _death_in_progress:
		return false
	var away: Vector3 = player.global_position - origin
	away.y = 0.0
	if away.length_squared() > 0.01:
		away = away.normalized() * knockback * 3.0
	if player.has_method("apply_damage") and not player.call("apply_damage", amount, away):
		return false
	_damage_remaining = 1.0
	health = maxi(health - amount - (difficulty if event_code == 0x22000003 else 0), 0)
	if health <= 0:
		_begin_death.call_deferred()
	_save_progress()
	return true


func _begin_death() -> void:
	if _death_in_progress or completed or lives <= 0:
		return
	_death_in_progress = true
	lives = maxi(lives - 1, 0)
	if player.has_method("play_death"):
		var duration: float
		if not _death_surface.is_empty():
			duration = player.play_death_for_surface(int(_death_surface.group), int(_death_surface.record), int(_death_surface.offset))
		else:
			duration = float(player.call("play_death"))
		await get_tree().create_timer(maxf(duration, 0.01), false).timeout
	player.controls_enabled = false
	if lives == 0:
		health = 0
		hud.game_over()
		_death_in_progress = false
		_save_progress()
	else:
		_death_in_progress = false
		restore_native_world()


func _apply_surface_rules() -> void:
	player.set_native_surface()
	if not player.is_on_floor() or _death_in_progress or lives <= 0:
		return
	var query := PhysicsRayQueryParameters3D.create(player.global_position + Vector3.UP * 0.25,
		player.global_position - Vector3.UP * 0.65, 1, [player.get_rid()])
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var collider: Node = hit.get("collider") as Node
	if collider == null or not collider.has_meta("native_surfaces"):
		return
	var surfaces: Array = collider.get_meta("native_surfaces")
	var face: int = int(hit.get("face_index", -1))
	if face < 0 or face >= surfaces.size():
		return
	var id: String = str(collider.get_meta("native_owner", ""))
	var owner: Dictionary = gameplay.get("owners", {}).get(id, {})
	for surface: Dictionary in owner.get("surface_data", []):
		if int(surface.get("surface_type", -1)) != int(surfaces[face]):
			continue
		player.set_native_surface(float(surface.get("movement_response_coefficient", 1.0)),
			int(surface.get("movement_constraint_raw", 0)) != 0)
		var damage: int = int(surface.get("ground_damage", 0))
		if damage > 0:
			if damage_player(damage, hit.position, 0.0, 0x22000003):
				if health > 0:
					player.bounce_from_native_surface()
				elif int(surface.get("death_visual_offset", 0)) > 0:
					_death_surface = {"group": owner.source.group, "record": owner.source.record,
						"offset": int(surface.death_visual_offset)}
		break


func play_native_sound(info: Dictionary, position: Vector3, attach: Node3D = null, pitch: float = 1.0) -> NativeSound:
	var path: String = str(info.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists("res://assets/generated/" + path):
		return null
	var sound: NativeSound = SoundScript.new()
	sound.listener = player
	sound.finished.connect(sound.queue_free)
	if is_instance_valid(attach):
		attach.add_child(sound)
	else:
		add_child(sound)
	sound.global_position = position
	if not sound.play_source(info, pitch):
		sound.queue_free()
		return null
	return sound


func _hide_owner(id: String) -> void:
	if owner_nodes.has(id):
		(owner_nodes[id] as Node3D).hide()


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color("518aa2")
	material.sky_horizon_color = Color("bdd8cf")
	material.ground_horizon_color = Color("a8c5c0")
	material.ground_bottom_color = Color("1b3943")
	sky.sky_material = material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("bbd2d2")
	environment.ambient_light_energy = 0.25
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 0.42
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 90.0
	add_child(light)


func _enable_vertex_colors(node: Node) -> void:
	NativeMaterialsScript.apply_recursive(node)


func _prepare_background_material(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh: MeshInstance3D = node as MeshInstance3D
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for index: int in range(mesh.mesh.get_surface_count()):
			var original: BaseMaterial3D = mesh.get_active_material(index) as BaseMaterial3D
			if original == null:
				continue
			var material := ShaderMaterial.new()
			material.shader = BackgroundShader
			material.set_shader_parameter("background_tint", original.albedo_color)
			material.set_shader_parameter("has_texture", original.albedo_texture != null)
			if original.albedo_texture:
				material.set_shader_parameter("source_texture", original.albedo_texture)
			mesh.set_surface_override_material(index, material)
	for child: Node in node.get_children():
		_prepare_background_material(child)


func _vector(value: Variant) -> Vector3:
	if value is Array and value.size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _source_vector(value: Variant) -> Vector3:
	var original: Vector3 = _vector(value)
	return Vector3(original.x, original.z, -original.y) * 0.01


func _matrix(values: Array) -> Transform3D:
	if values.size() != 16:
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3(values[0], values[1], values[2]),
		Vector3(values[4], values[5], values[6]), Vector3(values[8], values[9], values[10])),
		Vector3(values[12], values[13], values[14]))
