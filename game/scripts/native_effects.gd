class_name NativeEffects
extends Node3D
## Original CEmitter simulation with optional continuous high-detail surfaces.
## Native per-update drag/gravity run at the project's 60 Hz physics cadence.

const SamplerScript = preload("res://scripts/original_animation.gd")
const TexturePack = preload("res://scripts/hd_texture_pack.gd")
const Profiles = preload("res://scripts/native_effect_profiles.gd")
const EnhancedSurface = preload("res://scripts/shaders/native_effects_hq.gdshaderinc")
const EnhancedSolid = preload("res://scripts/shaders/native_effects_solid.gdshaderinc")
const SOURCE_SCALE: float = 0.01
var source: Dictionary
var owner_nodes: Dictionary
var player: HugoPlayer
var _emitters: Array[Dictionary] = []
var _pools: Dictionary = {}
var _definitions: Dictionary = {}
var _shaders: Dictionary = {}
var _quad: QuadMesh
var _solid_meshes: Dictionary = {}
var _sampler: HugoOriginalAnimation
var _tracks: Dictionary
var _random := RandomNumberGenerator.new()
var _enhanced: bool = true
var _missing_definitions: Array[String] = []
var _source_frames: Dictionary = {}


func _ready() -> void:
	add_to_group("native_effects")
	_enhanced = TexturePack.is_enabled()
	_random.randomize()
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
	_sampler = SamplerScript.new()
	add_child(_sampler)
	_tracks = source.get("native_transform_tracks", {})
	for key: String in source.get("effect_definitions", {}):
		var definition: Dictionary = source.effect_definitions[key]
		var textures: Array[Texture2D] = []
		var profiles: Array[int] = []
		var identities: Array[String] = []
		var frames: Array = definition.get("sprite", {}).get("frames", [])
		for frame: Dictionary in frames:
			var path: String = "res://assets/generated/" + str(frame.get("texture_path", ""))
			if ResourceLoader.exists(path):
				var texture: Texture2D = load(path) as Texture2D
				if texture != null:
					if not _source_frames.has(path):
						_source_frames[path] = Profiles.identify(texture)
					textures.append(texture)
					profiles.append(int(_source_frames[path].profile))
					identities.append(str(_source_frames[path].key))
		# Do not shorten an animation when one source frame is absent.
		if textures.is_empty() or textures.size() != frames.size():
			_missing_definitions.append(key)
			continue
		var environment: Dictionary = definition.get("environment", {})
		var pool_key: String = "g%03d_r%04d" % [int(environment.get("source_group", -1)), int(environment.get("source_record", -1))]
		if not _pools.has(pool_key):
			_pools[pool_key] = {"capacity": int(environment.get("capacity", 0)), "active": [], "free": [],
				"drag": float(environment.get("velocity_multiplier_per_update", 1.0)),
				"gravity": float(environment.get("gravity_z_per_update_source", 0.0)) * SOURCE_SCALE}
		_definitions[key] = {"data": definition, "textures": textures, "pool": pool_key,
			"profiles": profiles, "identities": identities,
			"mode": int(definition.get("sprite", {}).get("blend_mode", 3))}
	for owner: Dictionary in source.get("owners", []):
		var id: String = str(owner.id)
		for instance: Dictionary in owner.get("effect_instances", []):
			if not _definitions.has(str(instance.effect_key)):
				continue
			var anchor: Node3D = null
			if owner_nodes.has(id):
				anchor = (owner_nodes[id] as Node3D).find_child(str(instance.name), true, false) as Node3D
			_emitters.append({"source": instance, "owner": id, "anchor": anchor,
				"is_player": int(owner.type) == 10000, "remainder": 0.0, "last_action": -1})


func _physics_process(delta: float) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	for key: String in _pools:
		_update_pool(_pools[key], delta, camera)
	for emitter: Dictionary in _emitters:
		var instance: Dictionary = emitter.source
		var pose: Transform3D
		var enabled: bool = false
		if emitter.is_player and is_instance_valid(player):
			var action: int = player.get_native_visual_action()
			enabled = action == int(instance.get("action", -1))
			if enabled:
				pose = player.get_native_visual_transform() * _sample_chain(instance.get("transform_chain", []), player.get_native_visual_phase())
		else:
			var anchor: Node3D = emitter.anchor
			if is_instance_valid(anchor):
				enabled = anchor.is_visible_in_tree()
				pose = anchor.global_transform
		if not enabled or not camera.is_position_in_frustum(pose.origin):
			emitter.remainder = 0.0
			continue
		var info: Dictionary = _definitions[str(instance.effect_key)]
		var rate: float = float(info.data.get("emission_rate", 0))
		if rate <= 0.0:
			continue
		emitter.remainder = float(emitter.remainder) + delta
		var count: int = floori(rate * float(emitter.remainder))
		emitter.remainder = float(emitter.remainder) - float(count) / rate
		var pool: Dictionary = _pools[info.pool]
		count = mini(count, int(pool.capacity) - pool.active.size())
		for i: int in range(count):
			_spawn(info, pool, pose, camera)


func _spawn(info: Dictionary, pool: Dictionary, pose: Transform3D, camera: Camera3D) -> void:
	var data: Dictionary = info.data
	# 0x425710 consumes ten random values in this order. Sizes are stored as
	# integers and the initial angle is random, before the disk/cone samples.
	var end_size: int = int(_sample(data.get("end_size", {})))
	var start_size: int = int(_sample(data.get("start_size", {})))
	var life: float = maxf(_sample(data.get("lifetime", {})), 0.0001)
	var spin: float = _sample(data.get("spin_turns_per_0_06_seconds", {}))
	var angle: float = _random.randf() * TAU
	var disk_angle: float = _random.randf() * TAU
	var radius: float = sqrt(_random.randf()) * float(data.get("spawn_disk_radius_source", 0)) * SOURCE_SCALE
	var disk := Vector3(cos(disk_angle) * radius, 0.0, -sin(disk_angle) * radius)
	var azimuth: float = _random.randf() * TAU
	var cosine: float = lerpf(cos(deg_to_rad(float(data.get("cone_half_angle_degrees", 0.0)))), 1.0, _random.randf())
	var sine: float = sqrt(maxf(0.0, 1.0 - cosine * cosine))
	var direction := Vector3(sine * cos(azimuth), cosine, -sine * sin(azimuth))
	var velocity: Vector3 = pose.basis * direction * _sample(data.get("speed_source", {})) * SOURCE_SCALE
	var node: MeshInstance3D
	if pool.free.is_empty():
		node = MeshInstance3D.new()
		node.mesh = _quad
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = ShaderMaterial.new()
		add_child(node)
	else:
		node = pool.free.pop_back() as MeshInstance3D
	node.show()
	var particle: Dictionary = {"node": node, "position": pose * disk, "velocity": velocity,
		"remaining": life, "lifetime": life, "start_size": start_size,
		"end_size": end_size, "spin": spin,
		"angle": angle, "start_color": _color(data.get("start_rgb", [128, 128, 128])),
		"end_color": _color(data.get("end_rgb", [0, 0, 0])), "textures": info.textures, "frame": -1,
		"info": info, "appearance_seed": fposmod(angle / TAU + disk_angle / TAU * 0.61803398875, 1.0)}
	pool.active.append(particle)
	_draw(particle, camera)


func _update_pool(pool: Dictionary, delta: float, camera: Camera3D) -> void:
	var active: Array = pool.active
	for i: int in range(active.size() - 1, -1, -1):
		var particle: Dictionary = active[i]
		particle.remaining = float(particle.remaining) - delta
		if float(particle.remaining) <= 0.0:
			(particle.node as MeshInstance3D).hide()
			pool.free.append(particle.node)
			active.remove_at(i)
			continue
		var velocity: Vector3 = particle.velocity
		velocity *= float(pool.drag)
		velocity.y -= float(pool.gravity)
		particle.velocity = velocity
		particle.position = (particle.position as Vector3) + velocity * delta
		particle.angle = float(particle.angle) + delta * 16.66666603088379 * float(particle.spin) * TAU
		_draw(particle, camera)


func _draw(particle: Dictionary, camera: Camera3D) -> void:
	var age: float = clampf(1.0 - float(particle.remaining) / float(particle.lifetime), 0.0, 1.0)
	# The native update writes the current size and RGB to integer fields
	# (0x425D44..0x425E19), after interpolation and before drawing.
	var size: int = int(lerpf(float(particle.start_size), float(particle.end_size), age))
	var side: float = float(size) * 2.65165042945 * SOURCE_SCALE
	var rotation: Basis = Basis(Vector3.BACK, PI * 0.25 + float(particle.angle))
	var node: MeshInstance3D = particle.node
	node.global_transform = Transform3D(camera.global_basis * rotation * Basis.from_scale(Vector3(side, side, side)), particle.position)
	var material: ShaderMaterial = node.material_override as ShaderMaterial
	var frame: int = mini(floori(age * particle.textures.size()), particle.textures.size() - 1)
	if frame != int(particle.frame):
		particle.frame = frame
		_apply_particle_style(particle)
	var start: Color = particle.start_color
	var end: Color = particle.end_color
	var tint := Color(float(int(lerpf(start.r * 128.0, end.r * 128.0, age))) / 128.0,
		float(int(lerpf(start.g * 128.0, end.g * 128.0, age))) / 128.0,
		float(int(lerpf(start.b * 128.0, end.b * 128.0, age))) / 128.0)
	material.set_shader_parameter("tint", tint)
	particle["tint"] = tint
	if _enhanced and int(particle.info.profiles[frame]) >= 0:
		material.set_shader_parameter("effect_age", age)
		material.set_shader_parameter("particle_extent", side)
		if _is_solid_profile(int(particle.info.profiles[frame])):
			material.set_shader_parameter("effect_rotation", float(particle.angle))


func _apply_particle_style(particle: Dictionary) -> void:
	var node: MeshInstance3D = particle.node
	var material: ShaderMaterial = node.material_override as ShaderMaterial
	var info: Dictionary = particle.info
	var profile: int = int(info.profiles[int(particle.frame)])
	# Unknown future source art remains visible, but is reported as uncovered.
	# All seven pixel identities in the imported campaign have analytic surfaces.
	var style: int = 1 if _enhanced and profile >= 0 else (2 if _enhanced else 0)
	if style == 1 and _is_solid_profile(profile):
		style = 3
		node.mesh = _solid_mesh(profile, float(particle.appearance_seed))
	else:
		node.mesh = _quad
	material.shader = _shader(int(info.mode), style)
	material.set_shader_parameter("tint", particle.get("tint", Color.WHITE))
	if style == 1 or style == 3:
		material.set_shader_parameter("effect_profile", profile)
		material.set_shader_parameter("effect_seed", float(particle.appearance_seed))
		material.set_shader_parameter("effect_lifetime", float(particle.lifetime))
		material.set_shader_parameter("effect_age", clampf(1.0 - float(particle.remaining) / float(particle.lifetime), 0.0, 1.0))
		material.set_shader_parameter("particle_extent", (particle.node as MeshInstance3D).global_basis.x.length())
		if style == 3:
			material.set_shader_parameter("effect_rotation", float(particle.angle))
	else:
		material.set_shader_parameter("sprite_texture", particle.textures[int(particle.frame)])


func _is_solid_profile(profile: int) -> bool:
	return profile == Profiles.Kind.HEALTH_ORB or profile == Profiles.Kind.STONE


func _solid_mesh(profile: int, seed_value: float) -> Mesh:
	# Meshes are shared by every particle and recycled with the original pools.
	# This changes presentation only: no new RNG, emitter, lifetime or physics.
	var variant: int = mini(int(seed_value * 4.0), 3)
	var key: int = 3 if profile == Profiles.Kind.HEALTH_ORB else 10 + variant
	if _solid_meshes.has(key):
		return _solid_meshes[key] as Mesh
	var sphere := SphereMesh.new()
	sphere.radius = 0.39 if profile == Profiles.Kind.HEALTH_ORB else 0.37
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 48 if profile == Profiles.Kind.HEALTH_ORB else 32
	sphere.rings = 24 if profile == Profiles.Kind.HEALTH_ORB else 18
	if profile == Profiles.Kind.HEALTH_ORB:
		_solid_meshes[key] = sphere
		return sphere
	var arrays: Array = sphere.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var offset: float = float(variant) * 1.731
	for i: int in range(vertices.size()):
		var direction: Vector3 = vertices[i].normalized()
		var tangent: Vector3 = direction.cross(Vector3.UP).normalized()
		if tangent.length_squared() < 0.5:
			tangent = Vector3.RIGHT
		var bitangent: Vector3 = direction.cross(tangent).normalized()
		var point: Vector3 = direction * _stone_radius(direction, offset)
		var a: Vector3 = (direction + tangent * 0.01).normalized()
		var b: Vector3 = (direction + bitangent * 0.01).normalized()
		var normal: Vector3 = (a * _stone_radius(a, offset) - point).cross(b * _stone_radius(b, offset) - point).normalized()
		if normal.dot(direction) < 0.0:
			normal = -normal
		vertices[i] = point
		normals[i] = normal
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var stone := ArrayMesh.new()
	stone.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_solid_meshes[key] = stone
	return stone


func _stone_radius(direction: Vector3, offset: float) -> float:
	return 0.37 * (1.0 + 0.10 * sin(direction.x * 5.1 + direction.y * 2.3 + offset)
		* cos(direction.z * 4.3 - offset) + 0.055 * sin(direction.y * 9.7 + direction.z * 3.1 + offset))


func set_enhanced(enabled: bool) -> void:
	if _enhanced == enabled:
		return
	_enhanced = enabled
	for pool: Dictionary in _pools.values():
		for particle: Dictionary in pool.active:
			_apply_particle_style(particle)


func get_quality_coverage() -> Dictionary:
	var missing: Array[String] = []
	var identities: Dictionary = {}
	var families: Dictionary = {}
	var covered: int = 0
	var frame_slots: int = 0
	var sequences_preserved: bool = _missing_definitions.is_empty()
	for key: String in _definitions:
		var info: Dictionary = _definitions[key]
		var complete: bool = true
		frame_slots += info.textures.size()
		sequences_preserved = sequences_preserved and info.textures.size() == info.data.sprite.frames.size()
		for i: int in range(info.profiles.size()):
			var profile: int = int(info.profiles[i])
			var identity: String = str(info.identities[i])
			identities[identity] = true
			if profile < 0:
				complete = false
				if not missing.has(identity):
					missing.append(identity)
			else:
				families[Profiles.NAMES[profile]] = true
		if complete:
			covered += 1
	return {"enabled": _enhanced, "render_path": "analytic_surfaces" if _enhanced else "source_sprites",
		"definition_count": source.get("effect_definitions", {}).size(), "loaded_definitions": _definitions.size(),
		"profiled_definitions": covered, "enhanced_definitions": covered if _enhanced else 0,
		"anchor_count": _emitters.size(), "source_texture_files": _source_frames.size(), "referenced_frame_slots": frame_slots,
		"unique_source_frames": identities.size(), "frame_identities": identities.keys(), "families": families.keys(),
		"missing_profiles": missing, "missing_definitions": _missing_definitions.duplicate(),
		"frame_sequence_preserved": sequences_preserved, "pool_count": _pools.size(), "active_particles": active_particle_count(),
		"surface_source_bitmap_sampled": not _enhanced or not missing.is_empty(), "depth_soft_intersections": _enhanced,
		"geometric_particle_profiles": ["health_orb", "stone"] if _enhanced else [],
		"shared_solid_meshes": _solid_meshes.size()}


func reset_native_world() -> void:
	for pool: Dictionary in _pools.values():
		for particle: Dictionary in pool.active:
			(particle.node as MeshInstance3D).hide()
			pool.free.append(particle.node)
		pool.active.clear()
	for emitter: Dictionary in _emitters:
		emitter.remainder = 0.0


func active_particle_count() -> int:
	var count: int = 0
	for pool: Dictionary in _pools.values():
		count += pool.active.size()
	return count


func _sample(parameters: Dictionary) -> float:
	var percent: float = float(parameters.get("percent", 100.0))
	return float(parameters.get("base", 0.0)) * (_random.randf() * (100.0 - percent) + percent) * 0.01


func _color(bytes: Array) -> Color:
	return Color(float(bytes[0]) / 128.0, float(bytes[1]) / 128.0, float(bytes[2]) / 128.0)


func _sample_chain(chain: Array, phase: float) -> Transform3D:
	var pose := Transform3D.IDENTITY
	for reference: Dictionary in chain:
		var key: String = "g%03d_r%04d" % [int(reference.group), int(reference.record)]
		var track: Dictionary = _tracks.get(key, {})
		if not track.is_empty():
			pose = pose * _sampler.sample_native_transform(track, phase)
	return _sampler.to_godot_transform(pose)


func _shader(mode: int, style: int = 0) -> Shader:
	var key: String = "%d:%d" % [mode, style]
	if _shaders.has(key):
		return _shaders[key]
	var shader := Shader.new()
	var blend: String = "blend_mul" if mode == 1 else ("blend_add" if mode == 2 else "blend_mix")
	var header: String = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_draw_never, " + blend + ";\n"
	if style == 3:
		header = "shader_type spatial;\nrender_mode unshaded, cull_back, depth_draw_opaque, " + blend + ";\n"
		shader.code = header + "#define NATIVE_FX_BLEND %d\n" % mode + EnhancedSolid.code
		_shaders[key] = shader
		return shader
	if style == 1:
		shader.code = header + "#define NATIVE_FX_BLEND %d\n" % mode + EnhancedSurface.code
		_shaders[key] = shader
		return shader
	var color: String = "vec3(1.0) - sample_color.rgb * tint.rgb" if mode == 1 else "sample_color.rgb * tint.rgb"
	var alpha: String = "sample_color.a" if mode == 3 else "1.0"
	var filtering: String = "filter_nearest" if style == 0 else "filter_linear_mipmap_anisotropic"
	shader.code = header + \
		"uniform sampler2D sprite_texture : source_color, " + filtering + ", repeat_disable;\n" + \
		"uniform vec4 tint : source_color = vec4(1.0);\n" + \
		"void fragment() { vec4 sample_color = texture(sprite_texture, UV); ALBEDO = " + color + "; ALPHA = " + alpha + "; }"
	_shaders[key] = shader
	return shader
