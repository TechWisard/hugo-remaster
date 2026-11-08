class_name NativeEffects
extends Node3D
## Original CEmitter parameters, sprite frames and shared pool capacities.
## Native per-update drag/gravity run at the project's 60 Hz physics cadence.

const SamplerScript = preload("res://scripts/original_animation.gd")
const SOURCE_SCALE: float = 0.01
var source: Dictionary
var owner_nodes: Dictionary
var player: HugoPlayer
var _emitters: Array[Dictionary] = []
var _pools: Dictionary = {}
var _definitions: Dictionary = {}
var _shaders: Dictionary = {}
var _quad: QuadMesh
var _sampler: HugoOriginalAnimation
var _tracks: Dictionary
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	_random.randomize()
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
	_sampler = SamplerScript.new()
	add_child(_sampler)
	_tracks = source.get("native_transform_tracks", {})
	for key: String in source.get("effect_definitions", {}):
		var definition: Dictionary = source.effect_definitions[key]
		var textures: Array[Texture2D] = []
		for frame: Dictionary in definition.get("sprite", {}).get("frames", []):
			var path: String = "res://assets/generated/" + str(frame.get("texture_path", ""))
			if ResourceLoader.exists(path):
				textures.append(load(path) as Texture2D)
		if textures.is_empty():
			continue
		var environment: Dictionary = definition.get("environment", {})
		var pool_key: String = "g%03d_r%04d" % [int(environment.get("source_group", -1)), int(environment.get("source_record", -1))]
		if not _pools.has(pool_key):
			_pools[pool_key] = {"capacity": int(environment.get("capacity", 0)), "active": [], "free": [],
				"drag": float(environment.get("velocity_multiplier_per_update", 1.0)),
				"gravity": float(environment.get("gravity_z_per_update_source", 0.0)) * SOURCE_SCALE}
		_definitions[key] = {"data": definition, "textures": textures, "pool": pool_key,
			"shader": _shader(int(definition.get("sprite", {}).get("blend_mode", 3)))}
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
		if emitter.is_player:
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
	var material: ShaderMaterial = node.material_override as ShaderMaterial
	material.shader = info.shader
	material.set_shader_parameter("sprite_texture", info.textures[0])
	node.show()
	var particle: Dictionary = {"node": node, "position": pose * disk, "velocity": velocity,
		"remaining": life, "lifetime": life, "start_size": start_size,
		"end_size": end_size, "spin": spin,
		"angle": angle, "start_color": _color(data.get("start_rgb", [128, 128, 128])),
		"end_color": _color(data.get("end_rgb", [0, 0, 0])), "textures": info.textures, "frame": -1}
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
	var start: Color = particle.start_color
	var end: Color = particle.end_color
	var tint := Color(float(int(lerpf(start.r * 128.0, end.r * 128.0, age))) / 128.0,
		float(int(lerpf(start.g * 128.0, end.g * 128.0, age))) / 128.0,
		float(int(lerpf(start.b * 128.0, end.b * 128.0, age))) / 128.0)
	material.set_shader_parameter("tint", tint)
	var frame: int = mini(floori(age * particle.textures.size()), particle.textures.size() - 1)
	if frame != int(particle.frame):
		material.set_shader_parameter("sprite_texture", particle.textures[frame])
		particle.frame = frame


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


func _shader(mode: int) -> Shader:
	if _shaders.has(mode):
		return _shaders[mode]
	var shader := Shader.new()
	var blend: String = "blend_mul" if mode == 1 else ("blend_add" if mode == 2 else "blend_mix")
	var color: String = "vec3(1.0) - sample_color.rgb * tint.rgb" if mode == 1 else "sample_color.rgb * tint.rgb"
	var alpha: String = "sample_color.a" if mode == 3 else "1.0"
	shader.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_draw_never, " + blend + ";\n" + \
		"uniform sampler2D sprite_texture : source_color, filter_nearest, repeat_disable;\n" + \
		"uniform vec4 tint : source_color = vec4(1.0);\n" + \
		"void fragment() { vec4 sample_color = texture(sprite_texture, UV); ALBEDO = " + color + "; ALPHA = " + alpha + "; }"
	_shaders[mode] = shader
	return shader
