class_name NativeStep
extends RefCounted
## Walk over small solid details added to formerly passable source terrain.
## Every part of the up/forward/down path is a shape sweep against the world.


static func try_step(player: CharacterBody3D, motion: Vector3, maximum_height: float) -> bool:
	motion.y = 0.0
	if motion.length_squared() < 0.000001 or maximum_height <= 0.0 or not player.is_on_floor():
		return false
	var obstacle: bool = false
	for index: int in range(player.get_slide_collision_count()):
		var hit: KinematicCollision3D = player.get_slide_collision(index)
		var body: Object = hit.get_collider()
		if body is StaticBody3D and not body is AnimatableBody3D \
				and absf(hit.get_normal().y) < 0.2 and motion.dot(hit.get_normal()) < -0.0001:
			obstacle = true
			break
	if not obstacle:
		return false
	var world: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var excludes: Array[RID] = [player.get_rid()]
	for ignored: PhysicsBody3D in player.get_collision_exceptions():
		excludes.append(ignored.get_rid())
	var support_query := PhysicsRayQueryParameters3D.create(player.global_position + Vector3.UP * 0.04,
		player.global_position - Vector3.UP * 0.06, player.collision_mask, excludes)
	support_query.hit_back_faces = true
	var support: Dictionary = world.intersect_ray(support_query)
	if support.is_empty() or not support.collider is StaticBody3D or support.collider is AnimatableBody3D:
		return false
	var params := PhysicsTestMotionParameters3D.new()
	params.from = player.global_transform
	params.margin = player.safe_margin
	params.max_collisions = 4
	var tolerance: float = maxf(0.002, player.safe_margin * 2.0)
	var up: Vector3 = Vector3.UP * maximum_height
	params.motion = up
	var upward := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), params, upward)
	if upward.get_travel().y < maximum_height - tolerance \
			or Vector2(upward.get_travel().x, upward.get_travel().z).length() > tolerance:
		return false
	params.from.origin += upward.get_travel()
	params.motion = motion
	var forward := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), params, forward)
	if forward.get_travel().distance_to(motion) > tolerance:
		return false
	params.from.origin += forward.get_travel()
	var down: Vector3 = Vector3.DOWN * (maximum_height + player.floor_snap_length + tolerance)
	params.motion = down
	var downward := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(player.get_rid(), params, downward):
		return false
	var walkable: bool = false
	for index: int in range(downward.get_collision_count()):
		var body: Object = downward.get_collider(index)
		if body is StaticBody3D and not body is AnimatableBody3D \
				and downward.get_collision_normal(index).dot(Vector3.UP) >= cos(player.floor_max_angle):
			# A sweep can report an artificial upward separating normal at the
			# top edge of an uncapped vertical sheet. Require an actual walkable
			# face just inside the contacted edge, without reading a whole mesh.
			var point: Vector3 = downward.get_collision_point(index)
			var inside: Vector3 = point + motion.normalized() * maxf(0.005, player.safe_margin)
			var face_query := PhysicsRayQueryParameters3D.create(inside + Vector3.UP * 0.04,
				inside - Vector3.UP * 0.04, player.collision_mask, excludes)
			face_query.hit_back_faces = true
			var face: Dictionary = world.intersect_ray(face_query)
			if not face.is_empty() and face.collider == body \
					and (face.normal as Vector3).dot(Vector3.UP) >= cos(player.floor_max_angle) \
					and absf((face.position as Vector3).y - point.y) <= tolerance:
				walkable = true
				break
	var destination: Vector3 = params.from.origin + downward.get_travel()
	var rise: float = destination.y - player.global_position.y
	if not walkable or rise <= 0.002 or rise > maximum_height + tolerance:
		return false
	# No world step occurs between the queries and these constrained moves.
	# Keep the bent path: a single diagonal move would hit the riser's corner.
	player.move_and_collide(up, false, player.safe_margin)
	player.move_and_collide(motion, false, player.safe_margin)
	player.move_and_collide(down, false, player.safe_margin)
	# move_and_collide does not update CharacterBody's floor flags. A zero-input
	# slide refreshes actual contact/snap at the new support without advancing
	# native momentum or fabricating a grounded flag.
	var saved_velocity: Vector3 = player.velocity
	player.velocity = Vector3.ZERO
	player.move_and_slide()
	player.velocity = saved_velocity
	return player.is_on_floor()


static func try_ground_tangent(player: CharacterBody3D, motion: Vector3) -> bool:
	## Continue a stopped grounded command across a real walkable mesh seam.
	## The caller requires zero X/Z progress and excludes airborne/damage moves.
	motion.y = 0.0
	if motion.is_zero_approx() or not player.is_on_floor() or player.get_slide_collision_count() == 0:
		return false
	var minimum_normal_y: float = cos(player.floor_max_angle)
	var contact_point := Vector3.ZERO
	var contact_body: StaticBody3D = null
	for index: int in range(player.get_slide_collision_count()):
		var contact := player.get_slide_collision(index)
		var body: Object = contact.get_collider()
		if not body is StaticBody3D or body is AnimatableBody3D or contact.get_normal().y < minimum_normal_y:
			return false
		if contact_body == null:
			contact_body = body as StaticBody3D
			contact_point = contact.get_position()
	var excludes: Array[RID] = [player.get_rid()]
	for ignored: PhysicsBody3D in player.get_collision_exceptions():
		excludes.append(ignored.get_rid())
	# A box rests on its uphill corner: the centre of its base can be well
	# above the plane. Verify the actual contacted face and its continuation.
	var tolerance: float = maxf(0.02, player.safe_margin * 3.0)
	var inside: Vector3 = contact_point + motion.normalized() * maxf(0.005, player.safe_margin)
	var query := PhysicsRayQueryParameters3D.create(inside + Vector3.UP * tolerance,
		inside - Vector3.UP * tolerance, player.collision_mask, excludes)
	query.hit_back_faces = true
	var world: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var ground: Dictionary = world.intersect_ray(query)
	if ground.is_empty() or ground.collider != contact_body or ground.normal.y < minimum_normal_y:
		return false
	var normal: Vector3 = ground.normal
	var tangent: Vector3 = motion
	# Preserve the native horizontal displacement; Vector3.slide would change
	# X/Z as well. Descents retain the normal floor-snap path.
	tangent.y = -(normal.x * motion.x + normal.z * motion.z) / normal.y
	if tangent.y <= 0.0:
		return false
	var params := PhysicsTestMotionParameters3D.new()
	params.from = player.global_transform
	params.motion = tangent
	params.margin = player.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 32
	var result := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(player.get_rid(), params, result)
	if result.get_collision_safe_fraction() < 1.0 or not result.get_remainder().is_zero_approx() \
			or (result.get_travel() - tangent).length() > maxf(0.003, player.safe_margin * 2.0):
		return false
	for index: int in range(result.get_collision_count()):
		var body: Object = result.get_collider(index)
		if not body is StaticBody3D or body is AnimatableBody3D or result.get_collision_normal(index).y < minimum_normal_y:
			return false
	var destination: Vector3 = ground.position + tangent
	query.from = destination + Vector3.UP * tolerance
	query.to = destination - Vector3.UP * tolerance
	var landing: Dictionary = world.intersect_ray(query)
	if landing.is_empty() or landing.collider != contact_body or landing.normal.y < minimum_normal_y \
			or absf(landing.position.y - destination.y) > player.safe_margin * 2.0:
		return false
	# Only this already swept motion is executed; no collision exception or
	# position assignment is needed. Refresh the real floor flag afterward.
	var before: Vector3 = player.global_position
	player.move_and_collide(tangent, false, player.safe_margin)
	var saved_velocity: Vector3 = player.velocity
	player.velocity = Vector3.ZERO
	player.move_and_slide()
	player.velocity = saved_velocity
	var actual: Vector3 = player.global_position - before
	actual.y = 0.0
	return player.is_on_floor() and actual.dot(motion) > 0.0
