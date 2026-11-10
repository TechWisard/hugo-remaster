class_name NativeContactSeparation
extends RefCounted
## A scripted blocking box can advance into a supported player between physics
## steps. Godot's overlap recovery may then choose the box's underside and move
## the player through a thin terrain mesh. Resolve that horizontal encounter
## with a world-constrained sweep before submitting normal native movement.

enum Result { UNCHANGED, SEPARATED, BLOCKED }
var _blocked_proxies: Array[RID] = []


func resolve(player: CharacterBody3D, player_shape: CollisionShape3D,
		preferred: Vector3 = Vector3.ZERO) -> Result:
	if not player.is_on_floor() or player_shape == null or not player_shape.shape is BoxShape3D:
		_blocked_proxies.clear()
		return Result.UNCHANGED
	var world: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = player_shape.shape
	query.transform = player_shape.global_transform
	query.collision_mask = player.collision_mask
	var query_excludes: Array[RID] = [player.get_rid()]
	for ignored: PhysicsBody3D in player.get_collision_exceptions():
		query_excludes.append(ignored.get_rid())
	query.exclude = query_excludes
	var proxies: Array[PhysicsBody3D] = []
	var boxes: Array[Dictionary] = []
	var excludes: Array[RID] = []
	for hit: Dictionary in world.intersect_shape(query, 16):
		var body: PhysicsBody3D = hit.collider as PhysicsBody3D
		if not body is AnimatableBody3D or body.name != "NativePhysicalSlot0" or not body.has_meta("native_owner"):
			continue
		var proxy_velocity: Vector3 = PhysicsServer3D.body_get_state(body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		# Vertical platforms and descending crushers retain their own physical
		# response. This repair concerns a horizontally moving native blocker.
		var horizontal_speed: float = Vector2(proxy_velocity.x, proxy_velocity.z).length()
		var side_entry: bool = horizontal_speed > absf(proxy_velocity.y) + 0.01
		var tracked_stationary: bool = proxy_velocity.length_squared() < 0.0001 and body.get_rid() in _blocked_proxies
		if not side_entry and not tracked_stationary:
			continue
		var owner_id: int = body.shape_find_owner(int(hit.shape))
		var collider: CollisionShape3D = body.shape_owner_get_owner(owner_id) as CollisionShape3D
		if collider == null or not collider.shape is BoxShape3D:
			continue
		proxies.append(body)
		boxes.append(_box(collider))
		excludes.append(body.get_rid())
	if proxies.is_empty():
		_blocked_proxies.clear()
		return Result.UNCHANGED
	# A remembered floor flag alone is insufficient near a genuine drop. Only
	# a nearby, currently solid static floor permits horizontal separation.
	var floor_query := PhysicsRayQueryParameters3D.create(player.global_position + Vector3.UP * 0.04,
		player.global_position - Vector3.UP * 0.06, player.collision_mask, query.exclude)
	floor_query.hit_back_faces = true
	var floor_hit: Dictionary = world.intersect_ray(floor_query)
	if floor_hit.is_empty() or not floor_hit.collider is StaticBody3D or floor_hit.collider is AnimatableBody3D \
			or (floor_hit.normal as Vector3).dot(Vector3.UP) < cos(player.floor_max_angle):
		_blocked_proxies.clear()
		return Result.UNCHANGED
	var params := PhysicsTestMotionParameters3D.new()
	params.from = player.global_transform
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	var recovery := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), params, recovery)
	if recovery.get_travel().y >= -maxf(0.03, player.safe_margin * 2.0):
		_blocked_proxies.clear()
		return Result.UNCHANGED
	var own: Dictionary = _box(player_shape)
	preferred.y = 0.0
	if preferred.length_squared() < 0.0001:
		preferred = own.center - boxes[0].center
		preferred.y = 0.0
	if preferred.length_squared() < 0.0001:
		preferred = Vector3.RIGHT
	preferred = preferred.normalized()
	params.exclude_bodies = excludes
	var padding: float = maxf(0.005, player.safe_margin * 2.0)
	for angle: float in [0.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0, 180.0]:
		var direction: Vector3 = preferred.rotated(Vector3.UP, deg_to_rad(angle))
		var distance: float = 0.0
		for box: Dictionary in boxes:
			distance = maxf(distance, _exit_distance(own, box, direction, padding))
		if not is_finite(distance) or distance <= 0.0:
			continue
		var motion: Vector3 = direction * distance
		params.motion = motion
		var swept := PhysicsTestMotionResult3D.new()
		PhysicsServer3D.body_test_motion(player.get_rid(), params, swept)
		var travel: Vector3 = swept.get_travel()
		if travel.y < -padding or Vector2(travel.x - motion.x, travel.z - motion.z).length() > padding:
			continue
		query.transform = player_shape.global_transform
		query.transform.origin += travel
		var still_overlapping: bool = false
		for hit: Dictionary in world.intersect_shape(query, 16):
			if hit.collider in proxies:
				still_overlapping = true
				break
		if still_overlapping:
			continue
		# Ignore only the initial intersecting proxies during this one swept
		# separation. Terrain, walls and every other actor remain solid. The
		# destination was checked clear, and all exceptions are restored below.
		var added: Array[PhysicsBody3D] = []
		for body: PhysicsBody3D in proxies:
			if body not in player.get_collision_exceptions():
				player.add_collision_exception_with(body)
				added.append(body)
		player.move_and_collide(motion, false, player.safe_margin)
		for body: PhysicsBody3D in added:
			player.remove_collision_exception_with(body)
		_blocked_proxies.clear()
		return Result.SEPARATED
	# No collision-free escape exists this tick. Keep the supported body
	# constrained by the existing world instead of accepting an unsafe recovery.
	# Native hit/state/animation clocks continue; no health or life is invented.
	_blocked_proxies = excludes
	return Result.BLOCKED


static func _box(shape: CollisionShape3D) -> Dictionary:
	var transform: Transform3D = shape.global_transform
	var half: Vector3 = (shape.shape as BoxShape3D).size * 0.5
	return {"center": transform.origin, "edges": [transform.basis.x * half.x,
		transform.basis.y * half.y, transform.basis.z * half.z]}


static func _exit_distance(a: Dictionary, b: Dictionary, direction: Vector3, padding: float) -> float:
	# Along a given horizontal direction, the first separating SAT plane is
	# the exact exit from two boxes. Cross products also handle authored shear.
	var ae: Array = a.edges
	var be: Array = b.edges
	var axes: Array[Vector3] = []
	for index: int in range(3):
		axes.append((ae[(index + 1) % 3] as Vector3).cross(ae[(index + 2) % 3]))
		axes.append((be[(index + 1) % 3] as Vector3).cross(be[(index + 2) % 3]))
		for other: int in range(3):
			axes.append((ae[index] as Vector3).cross(be[other]))
	var distance: float = INF
	var offset: Vector3 = a.center - b.center
	for raw: Vector3 in axes:
		if raw.length_squared() < 0.000000000001:
			continue
		var axis: Vector3 = raw.normalized()
		var speed: float = axis.dot(direction)
		if absf(speed) < 0.000001:
			continue
		var radius: float = padding
		for edge: Vector3 in ae + be:
			radius += absf(axis.dot(edge))
		var exit: float = ((radius if speed > 0.0 else -radius) - axis.dot(offset)) / speed
		if exit > 0.0:
			distance = minf(distance, exit)
	return distance
