class_name HugoPlayerVisual
extends Node3D
const NativeMaterialsScript = preload("res://scripts/native_materials.gd")
## Loads the locally generated mesh, or builds an original geometric stand-in.
## Recovered actions play when the local animation manifest is present.
## Procedural movement is only a fallback for assets without recovered tracks.

const OriginalAnimationScript = preload("res://scripts/original_animation.gd")
const NativePresentationScript = preload("res://scripts/native_player_presentation.gd")

var using_imported_model: bool = false
var using_original_animation: bool = false
var source_bounds: AABB = AABB()
var original_animation: HugoOriginalAnimation
var native_presentation: NativePlayerPresentation

var _pose_root: Node3D
var _normalized_root: Node3D
var _has_mesh_bounds: bool = false
var _left_arm: Node3D
var _right_arm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _stride_phase: float = 0.0
var _motion_weight: float = 0.0
var _character_scale: float = 1.0


func build(path: String, target_height: float, yaw_degrees: float = 0.0) -> void:
	_pose_root = Node3D.new()
	_pose_root.name = "Pose"
	add_child(_pose_root)
	_normalized_root = Node3D.new()
	_normalized_root.name = "NormalizedModel"
	_pose_root.add_child(_normalized_root)

	_character_scale = target_height / 1.7
	var manifest_path: String = path.get_base_dir().path_join("animation_manifest.json")
	if path.get_file() == "hugo.glb" and FileAccess.file_exists(manifest_path):
		var orientation: Node3D = Node3D.new()
		orientation.name = "SourceOrientation"
		orientation.rotation.y = deg_to_rad(yaw_degrees)
		_normalized_root.add_child(orientation)
		original_animation = OriginalAnimationScript.new() as HugoOriginalAnimation
		original_animation.name = "RecoveredActions"
		orientation.add_child(original_animation)
		using_original_animation = original_animation.load_manifest(manifest_path, Callable(self, "_enable_imported_vertex_colors"))
		if using_original_animation:
			_scan_bounds(orientation, Transform3D.IDENTITY)
			# Use the one recovered idle bound for every action. A moving hand or
			# imported morph bound must never rescale or recenter the character.
			var bind: Dictionary = original_animation.manifest.get("bind_bounds", {}) as Dictionary
			var lower: Array = bind.get("min", []) as Array
			var upper: Array = bind.get("max", []) as Array
			if lower.size() == 3 and upper.size() == 3:
				var low: Vector3 = Vector3(float(lower[0]), float(lower[1]), float(lower[2]))
				var high: Vector3 = Vector3(float(upper[0]), float(upper[1]), float(upper[2]))
				if low.is_finite() and high.is_finite() and high.y > low.y:
					source_bounds = orientation.transform * AABB(low, high - low)
					_has_mesh_bounds = true
			using_imported_model = _has_mesh_bounds and source_bounds.size.y > 0.0001
		else:
			_normalized_root.remove_child(orientation)
			orientation.free()
			original_animation = null

	if not using_original_animation and not path.is_empty() and ResourceLoader.exists(path, "PackedScene"):
		var packed: PackedScene = ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed != null:
			var instance: Node = packed.instantiate()
			if instance is Node3D:
				var source_orientation: Node3D = Node3D.new()
				source_orientation.name = "SourceOrientation"
				source_orientation.rotation.y = deg_to_rad(yaw_degrees)
				_normalized_root.add_child(source_orientation)
				source_orientation.add_child(instance)
				_enable_imported_vertex_colors(instance)
				_scan_bounds(source_orientation, Transform3D.IDENTITY)
				using_imported_model = _has_mesh_bounds and source_bounds.size.y > 0.0001
				if not using_imported_model:
					_normalized_root.remove_child(source_orientation)
					source_orientation.free()
			else:
				instance.free()

	if not using_imported_model:
		_has_mesh_bounds = false
		source_bounds = AABB()
		_build_stand_in()
		for child: Node in _normalized_root.get_children():
			_scan_bounds(child, Transform3D.IDENTITY)

	if _has_mesh_bounds and source_bounds.size.y > 0.0001:
		var height_scale: float = target_height / source_bounds.size.y
		var bounds_center: Vector3 = source_bounds.get_center()
		_normalized_root.scale = Vector3.ONE * height_scale
		_normalized_root.position = Vector3(-bounds_center.x, -source_bounds.position.y, -bounds_center.z) * height_scale
		if using_original_animation:
			original_animation.distance_scale = height_scale

	if bool(get_parent().get("using_native_movement")):
		native_presentation = NativePresentationScript.new() as NativePlayerPresentation
		native_presentation.name = "NativePresentation"
		add_child(native_presentation)
		var shadow_info: Dictionary = original_animation.manifest.get("hugo_shadow", {}) as Dictionary \
			if is_instance_valid(original_animation) else {}
		native_presentation.configure(get_parent() as CharacterBody3D, _pose_root, self,
			original_animation, shadow_info, manifest_path.get_base_dir())


func update_motion(local_velocity: Vector3, grounded: bool, delta: float, action: String = "") -> void:
	if not is_instance_valid(_pose_root):
		return
	var horizontal_speed: float = Vector2(local_velocity.x, local_velocity.z).length()
	if using_original_animation and is_instance_valid(original_animation):
		var selected_action: String = action
		if selected_action.is_empty():
			if not grounded:
				selected_action = "jump" if local_velocity.y > 0.0 else "fall"
			elif horizontal_speed < 0.08 * _character_scale:
				selected_action = "idle"
			else:
				selected_action = "run" if horizontal_speed > 5.8 * _character_scale else "walk"
		original_animation.set_action(selected_action)
		var distance: float = absf(local_velocity.y) * delta if selected_action == "fall" else horizontal_speed * delta
		original_animation.advance(delta, distance)
		return
	var target_weight: float = clampf(horizontal_speed / 4.8, 0.0, 1.0) if grounded else 0.0
	var blend: float = 1.0 - exp(-12.0 * delta)
	_motion_weight = lerpf(_motion_weight, target_weight, blend)
	_stride_phase = fposmod(_stride_phase + horizontal_speed * delta * 3.8, TAU)
	var step: float = sin(_stride_phase) * _motion_weight
	var bob_height: float = 0.018 if using_imported_model else 0.035
	_pose_root.position.y = lerpf(_pose_root.position.y, absf(sin(_stride_phase)) * bob_height * _motion_weight, blend)
	var lean: Vector3 = Vector3(
		clampf(local_velocity.z * 0.012, -0.08, 0.08),
		0.0,
		clampf(-local_velocity.x * 0.012, -0.06, 0.06)
	)
	_pose_root.rotation = _pose_root.rotation.lerp(lean, blend)
	if not using_imported_model:
		_left_leg.rotation.x = step * 0.55 if grounded else -0.22
		_right_leg.rotation.x = -step * 0.55 if grounded else 0.25
		_left_arm.rotation.x = -step * 0.42 if grounded else -0.3
		_right_arm.rotation.x = step * 0.42 if grounded else -0.3


func reset_pose() -> void:
	_stride_phase = 0.0
	_motion_weight = 0.0
	if using_original_animation and is_instance_valid(original_animation):
		original_animation.set_action("idle", true)
	if is_instance_valid(_pose_root):
		_pose_root.position = Vector3.ZERO
		_pose_root.rotation = Vector3.ZERO
	for limb: Node3D in [_left_arm, _right_arm, _left_leg, _right_leg]:
		if is_instance_valid(limb):
			limb.rotation = Vector3.ZERO


func _scan_bounds(node: Node, parent_transform: Transform3D) -> void:
	var local_transform: Transform3D = parent_transform
	var spatial: Node3D = node as Node3D
	if spatial != null:
		local_transform = parent_transform * spatial.transform
	var mesh_node: MeshInstance3D = node as MeshInstance3D
	if mesh_node != null and mesh_node.mesh != null:
		var mesh_bounds: AABB = local_transform * mesh_node.mesh.get_aabb()
		if mesh_bounds.position.is_finite() and mesh_bounds.size.is_finite():
			if _has_mesh_bounds:
				source_bounds = source_bounds.merge(mesh_bounds)
			else:
				source_bounds = mesh_bounds
				_has_mesh_bounds = true
	for child: Node in node.get_children():
		_scan_bounds(child, local_transform)


func _enable_imported_vertex_colors(node: Node) -> void:
	NativeMaterialsScript.apply_recursive(node)


func _build_stand_in() -> void:
	var coat: StandardMaterial3D = _material(Color("3e908c"))
	var skin: StandardMaterial3D = _material(Color("dba574"))
	var trousers: StandardMaterial3D = _material(Color("6b5140"))
	var boots: StandardMaterial3D = _material(Color("332c35"))
	var scarf: StandardMaterial3D = _material(Color("e3b34f"))
	var eye_white: StandardMaterial3D = _material(Color("fff4dd"))
	var dark: StandardMaterial3D = _material(Color("302a2d"))

	_add_capsule(_normalized_root, "Coat", 0.25, 0.65, Vector3(0.0, 0.94, 0.0), coat)
	_add_sphere(_normalized_root, "Head", 0.275, Vector3(0.0, 1.405, -0.015), skin)
	_add_sphere(_normalized_root, "LeftEar", 0.1, Vector3(-0.29, 1.40, 0.0), skin)
	_add_sphere(_normalized_root, "RightEar", 0.1, Vector3(0.29, 1.40, 0.0), skin)
	var hair: MeshInstance3D = _add_sphere(_normalized_root, "Cap", 0.27, Vector3(0.0, 1.61, 0.015), trousers)
	hair.scale = Vector3(1.02, 0.34, 1.0)
	_add_sphere(_normalized_root, "Nose", 0.08, Vector3(0.0, 1.39, -0.283), skin)
	_add_sphere(_normalized_root, "LeftEye", 0.057, Vector3(-0.105, 1.49, -0.25), eye_white)
	_add_sphere(_normalized_root, "RightEye", 0.057, Vector3(0.105, 1.49, -0.25), eye_white)
	_add_sphere(_normalized_root, "LeftPupil", 0.028, Vector3(-0.105, 1.49, -0.297), dark)
	_add_sphere(_normalized_root, "RightPupil", 0.028, Vector3(0.105, 1.49, -0.297), dark)
	_add_box(_normalized_root, "Scarf", Vector3(0.42, 0.09, 0.35), Vector3(0.0, 1.215, -0.025), scarf)
	_add_box(_normalized_root, "ScarfEnd", Vector3(0.11, 0.28, 0.06), Vector3(0.11, 1.065, -0.22), scarf)

	_left_leg = _pivot("LeftLeg", Vector3(-0.145, 0.67, 0.0))
	_right_leg = _pivot("RightLeg", Vector3(0.145, 0.67, 0.0))
	for leg: Node3D in [_left_leg, _right_leg]:
		_add_capsule(leg, "Trouser", 0.095, 0.44, Vector3(0.0, -0.22, 0.0), trousers)
		_add_box(leg, "Boot", Vector3(0.215, 0.19, 0.33), Vector3(0.0, -0.565, -0.055), boots)
	_left_arm = _pivot("LeftArm", Vector3(-0.29, 1.12, 0.0))
	_right_arm = _pivot("RightArm", Vector3(0.29, 1.12, 0.0))
	for arm: Node3D in [_left_arm, _right_arm]:
		_add_capsule(arm, "Sleeve", 0.085, 0.46, Vector3(0.0, -0.21, 0.0), coat)
		_add_sphere(arm, "Hand", 0.1, Vector3(0.0, -0.46, 0.0), skin)


func _pivot(node_name: String, at: Vector3) -> Node3D:
	var pivot: Node3D = Node3D.new()
	pivot.name = node_name
	pivot.position = at
	_normalized_root.add_child(pivot)
	return pivot


func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	return material


func _add_capsule(parent: Node3D, node_name: String, radius: float, height: float, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh: CapsuleMesh = CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 4
	return _add_mesh(parent, node_name, mesh, at, material)


func _add_sphere(parent: Node3D, node_name: String, radius: float, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return _add_mesh(parent, node_name, mesh, at, material)


func _add_box(parent: Node3D, node_name: String, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	return _add_mesh(parent, node_name, mesh, at, material)


func _add_mesh(parent: Node3D, node_name: String, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance
