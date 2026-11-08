class_name DiamondPickup
extends Area3D
## A collectible with idempotent collection and an explicit restart lifecycle.

signal collected(pickup: DiamondPickup)

var active: bool = true
var visual: MeshInstance3D
var phase: float = 0.0
var _elapsed: float = 0.0
var _pickup_tween: Tween


func _ready() -> void:
	monitoring = true
	collision_layer = 0
	collision_mask = 1
	var collision := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.55
	collision.shape = sphere
	add_child(collision)
	visual = MeshInstance3D.new()
	visual.mesh = _diamond_mesh()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.78, 0.95)
	material.metallic = 0.45
	material.roughness = 0.2
	material.emission_enabled = true
	material.emission = Color(0.03, 0.32, 0.48)
	material.emission_energy_multiplier = 0.6
	visual.material_override = material
	add_child(visual)
	body_entered.connect(_on_body_entered)
	add_to_group("diamonds")


func _process(delta: float) -> void:
	_elapsed += delta
	if active:
		visual.rotation.y += delta * 1.1
		visual.position.y = sin(_elapsed * 2.4 + phase) * 0.12


func _on_body_entered(body: Node3D) -> void:
	if body is HugoPlayer:
		collect()


func collect() -> bool:
	if not active:
		return false
	active = false
	set_deferred("monitoring", false)
	if is_instance_valid(visual):
		_pickup_tween = create_tween().set_parallel(true)
		_pickup_tween.tween_property(visual, "scale", Vector3.ONE * 0.01, 0.16)
		_pickup_tween.tween_property(visual, "position:y", 0.8, 0.16)
	collected.emit(self)
	return true


func reset_pickup() -> void:
	if _pickup_tween and _pickup_tween.is_valid():
		_pickup_tween.kill()
	active = true
	set_deferred("monitoring", true)
	if is_instance_valid(visual):
		visual.scale = Vector3.ONE
		visual.position = Vector3.ZERO


func _diamond_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := Vector3(0, 0.48, 0)
	var bottom := Vector3(0, -0.36, 0)
	var ring: Array[Vector3] = [Vector3(0.27, 0, 0), Vector3(0, 0, 0.27), Vector3(-0.27, 0, 0), Vector3(0, 0, -0.27)]
	for i in range(4):
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % 4]
		for point: Vector3 in [top, a, b, bottom, b, a]:
			surface.add_vertex(point)
	surface.generate_normals()
	return surface.commit()
