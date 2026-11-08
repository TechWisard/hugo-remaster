extends SceneTree
## Synthetic source graphs exercise the real native runtime without game assets.

class TestLevel extends Node3D:
	var difficulty: int = 1
	var data: Dictionary = {"main_group": 1}
	var owner_nodes: Dictionary = {}
	var events: Array = []
	var damage: Array = []
	func queue_native_event(message: Dictionary, sender: String = "") -> void:
		events.append(["event", message, sender])
	func save_native_world() -> void:
		events.append(["save"])
	func set_native_checkpoint(id: String, position: Vector3) -> void:
		events.append(["checkpoint", id, position])
	func damage_player(amount: int, origin: Vector3, force: float = 1.0, event: int = 0x22000003) -> void:
		damage.append([amount, origin, force, event])

class TestPlayer extends Node3D:
	var is_attacking: bool = false
	var attack_serial: int = 0
	var action: int = 0
	var phase: float = 0.0
	func get_native_visual_action() -> int:
		return action
	func get_native_visual_phase() -> float:
		return phase
	func get_native_visual_transform() -> Transform3D:
		return global_transform

var level: TestLevel
var sampler: HugoOriginalAnimation
var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	level = TestLevel.new()
	root.add_child(level)
	sampler = HugoOriginalAnimation.new()
	level.add_child(sampler)
	_test_clock_and_transitions()
	_test_directed_graph_contacts()
	_test_checkpoint_and_resume()
	_test_pose_sampling()
	_test_oriented_boxes()
	await _test_physical_slot()
	print("NATIVE_VM_TEST checks=%d failures=%d" % [checks, failures])
	level.free()
	quit(1 if failures else 0)


func _expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)


func _state(flags: int = 0, transitions: Array = []) -> Dictionary:
	return {"visual_action": 0, "visual_period": 1.0, "transform_period": 1.0,
		"visual_loop_limit": 0, "transform_loop_limit": 0, "timeout_seconds": 1000.0,
		"contact_damage": 0, "knockback_multiplier": 1.0, "flags": flags,
		"transitions": transitions, "entry_events": []}


func _transition(mask: int, target: int, argument: int = 0) -> Dictionary:
	return {"mask": mask, "next_state": target, "argument": argument}


func _node(category: int, receive_mask: int) -> Dictionary:
	return {"node_index": 0, "collision_mask_a": category, "collision_mask_b": receive_mask,
		"bounds": [[-0.5, 0.0, -0.5], [0.5, 1.0, 0.5]], "transform_chain": []}


func _actor(states: Array, nodes: Array = [], machine_fields: Dictionary = {}, source_fields: Dictionary = {}) -> NativeStateActor:
	var visual := Node3D.new()
	level.add_child(visual)
	for index: int in range(3):
		var action_node := Node3D.new()
		action_node.name = "Action%03d" % index
		visual.add_child(action_node)
	var source: Dictionary = {"id": "actor_%d" % visual.get_instance_id(), "actions": []}
	for index: int in range(3):
		source.actions.append({"index": index, "node_name": "Action%03d" % index,
			"duration": 1.0, "collision_nodes": nodes, "phase_domain": "seconds"})
	source.merge(source_fields, true)
	var machine: Dictionary = {"initial_state": 0, "initial_health_base": 3,
		"health_adds_difficulty_index": true, "states": states}
	machine.merge(machine_fields, true)
	var actor := NativeStateActor.new()
	actor.native = {"state_machine": machine, "source": {"group": 2}}
	actor.source_id = source.id
	actor.level = level
	actor.visual = visual
	var motion := NativeActorMotion.new()
	motion.source = source
	motion.native = actor.native
	motion.owner_visual = visual
	motion.sampler = sampler
	motion.autonomous = false
	level.add_child(motion)
	actor.motion = motion
	level.owner_nodes[source.id] = visual
	level.add_child(actor)
	actor.set_physics_process(false)
	actor.graph_colliders.set_physics_process(false)
	return actor


func _player(nodes: Array) -> NativeGraphColliders:
	var player := TestPlayer.new()
	level.add_child(player)
	var graph := NativeGraphColliders.new()
	graph.source = {"id": "player", "actions": [{"index": 0, "collision_nodes": nodes}]}
	graph.player = player
	graph.sampler = sampler
	graph.space = level
	level.add_child(graph)
	graph.set_physics_process(false)
	return graph


func _touch(a: NativeGraphColliders, b: NativeGraphColliders) -> void:
	a.refresh()
	b.refresh()
	NativeGraphColliders._test_pair(a, b)


func _test_clock_and_transitions() -> void:
	var frozen: Dictionary = _state(0, [_transition(16, 1)])
	frozen.visual_period = 0.0
	var actor: NativeStateActor = _actor([frozen, _state()], [],
		{"initial_visual_phase": 0.25, "initial_transform_phase": 0.375})
	actor._physics_process(0.5)
	_expect(is_equal_approx(actor.visual_phase, 0.25), "zero period freezes visual ticker")
	_expect(is_equal_approx(actor.path_phase, 0.375), "path ticker needs native state flag4")
	_expect(actor.state_index == 0, "loop limit0 does not cause an immediate transition")
	frozen.visual_period = 1.0
	actor._physics_process(0.75)
	_expect(actor.state_index == 0 and is_equal_approx(actor.visual_phase, 1.0), "exact phase1 is retained until overflow")
	actor._physics_process(0.01)
	_expect(actor.state_index == 1, "visual loop transition follows actual overflow")
	var reversed: NativeStateActor = _actor([_state(), _state(0xC3)])
	reversed._transition(1, false)
	_expect(reversed.visual_phase == 1.0 and reversed.path_phase == 1.0, "reverse reset starts at endpoint1")
	reversed._physics_process(0.25)
	_expect(is_equal_approx(reversed.visual_phase, 0.75), "reverse visual phase advances once, without double reversal")
	_expect(reversed.path_phase == 1.0, "reverse flag does not implicitly enable world path")
	var sentinel: NativeStateActor = _actor([_state(0, [_transition(1, -2000), _transition(1, 1)]), _state()])
	sentinel.receive_event(0x22000001)
	_expect(sentinel.state_index == 0, "first matched -2000 stops the transition table search")
	var argument: NativeStateActor = _actor([_state(0, [_transition(512, 1, 7)]), _state()])
	argument.receive_event(0x22000004, 6)
	_expect(argument.state_index == 0, "event04 rejects a different argument")
	argument.receive_event(0x22000004, 7)
	_expect(argument.state_index == 1, "event04 accepts the authored argument")
	var path: NativeStateActor = _actor([_state(4, [_transition(72, 1)]), _state()])
	path._physics_process(1.0)
	_expect(path.state_index == 0, "path endpoint1 is not overflow")
	path._physics_process(0.01)
	_expect(path.state_index == 1, "combined mask72 accepts path overflow bit8")
	var stall: NativeStateActor = _actor([_state(4)])
	stall._physics_process(1.01)
	_expect(stall.elapsed == 0.0 and stall.path_phase == 0.0, "native stall guard discards dt greater than one second")


func _test_directed_graph_contacts() -> void:
	var body: NativeGraphColliders = _player([_node(1, 8)])
	var checkpoint: NativeStateActor = _actor([_state(0, [_transition(2, 1, 16)]), _state()], [_node(16, 1)])
	_touch(checkpoint.graph_colliders, body)
	_expect(checkpoint.state_index == 1, "transition mask2 examines receiver OWN category16")
	var filtered: NativeStateActor = _actor([_state(0, [_transition(64, 1)]), _state()], [_node(16, 2)])
	_touch(filtered.graph_colliders, body)
	_expect(filtered.state_index == 0, "receive mask excludes a mismatched other category")
	var no_fallback: NativeStateActor = _actor([_state(0, [_transition(2, 1, 32), _transition(64, 1)]), _state()], [_node(16, 1)])
	_touch(no_fallback.graph_colliders, body)
	_expect(no_fallback.state_index == 0, "mask2 branch does not fall back to mask64 after argument mismatch")
	var attack: NativeGraphColliders = _player([_node(2, 4)])
	attack.player.set("is_attacking", true)
	attack.player.set("attack_serial", 7)
	var target: NativeStateActor = _actor([_state()], [_node(4, 2)])
	_touch(attack, target.graph_colliders)
	_touch(attack, target.graph_colliders)
	_expect(target.hit_points == 3, "same accepted attack inflicts exactly one HP across repeated overlaps")
	attack.player.set("attack_serial", 8)
	_touch(attack, target.graph_colliders)
	_expect(target.hit_points == 2, "next accepted attack can inflict another HP")
	target.receive_event(0x22000012, 99)
	_expect(target.hit_points == 2, "state actor does not handle Hugo alternate-damage event12")
	var hazard_state: Dictionary = _state()
	hazard_state.contact_damage = 3
	var hazard: NativeStateActor = _actor([hazard_state], [_node(8, 1)], {"damage_event": 0x22000012})
	level.damage.clear()
	_touch(hazard.graph_colliders, body)
	_expect(level.damage.size() == 1 and int(level.damage[0][3]) == 0x22000012, "contact category8 retains native alternate damage event")
	var harmless: NativeStateActor = _actor([hazard_state], [_node(16, 1)])
	_touch(harmless.graph_colliders, body)
	_expect(level.damage.size() == 1, "contact damage requires OWN category bit8")
	var removed_state: Dictionary = _state(0x200)
	removed_state.visual_action = -1
	target._states.append(removed_state)
	target._transition(1, false)
	target.graph_colliders.refresh()
	_expect(target.graph_colliders.active_boxes.is_empty(), "removed actor has no active logic collider")


func _test_checkpoint_and_resume() -> void:
	var collected_state: Dictionary = _state(0x4101)
	collected_state.entry_events = [{"target": "dummy", "event": 0x22000001}]
	var actor: NativeStateActor = _actor([_state(0, [_transition(2, 1, 16)]), collected_state], [_node(16, 1)],
		{"persistent_checkpoint_item": true, "initial_transform_phase": 0.375})
	var body: NativeGraphColliders = _player([_node(1, 0)])
	level.events.clear()
	_touch(actor.graph_colliders, body)
	_expect(level.events.size() == 3 and level.events[0][0] == "checkpoint" and level.events[1][0] == "save" and level.events[2][0] == "event", "checkpoint and native save precede state entry notifications")
	var checkpoint: Dictionary = actor.native_checkpoint_snapshot()
	_expect(checkpoint == {"persistent_activation": true}, "native state snapshot contains only its persistent bool")
	actor.visual_phase = 0.43
	actor.path_phase = 0.67
	actor.elapsed = 4.5
	actor.visual_loops = 3
	actor.path_loops = 2
	actor.hit_points = 2
	actor.visual.position = Vector3(4, 5, 6)
	var saved: Dictionary = actor.snapshot()
	actor.reset_native_checkpoint(false, checkpoint)
	_expect(actor.removed, "activated checkpoint is removed even before removal animation had finished")
	actor.restore(saved)
	_expect(not actor.removed and actor.state_index == 1 and actor.hit_points == 2, "modern resume restores saved state and HP")
	_expect(is_equal_approx(actor.visual_phase, 0.43) and is_equal_approx(actor.path_phase, 0.67) and actor.visual_loops == 3 and actor.path_loops == 2, "modern resume restores both phase counters")
	_expect(actor.visual.position.is_equal_approx(Vector3(4, 5, 6)), "modern resume preserves the saved world pose")
	actor.reset_native_checkpoint(false, {})
	_expect(actor.state_index == 0 and actor.hit_points == 4 and not actor.removed, "native child-segment reload restores source state0 and initial HP")
	_expect(is_equal_approx(actor.path_phase, 0.375), "native reset reapplies authored initial percentage after state0 entry")


func _test_pose_sampling() -> void:
	var visual := Node3D.new()
	level.add_child(visual)
	var action := Node3D.new()
	action.name = "Action000"
	visual.add_child(action)
	var anchor := Node3D.new()
	anchor.name = "EffectAnchor"
	action.add_child(anchor)
	var reference: Dictionary = {"group": 1, "record": 1}
	var track: Dictionary = {"initial_translation": [0, 0, 0],
		"initial_basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
		"translation_keys": [[0, 0, 0], [200, 0, 0]], "translation_loop": false}
	var motion := NativeActorMotion.new()
	motion.owner_visual = visual
	motion.sampler = sampler
	motion.autonomous = false
	motion.tracks = {"g001_r0001": track}
	motion.source = {"actions": [{"index": 0, "node_name": "Action000"}],
		"effect_instances": [{"name": "EffectAnchor", "action": 0, "transform_chain": [reference]}]}
	level.add_child(motion)
	motion.sample_state(0, 0.5, 0.0, {})
	_expect(anchor.position.is_equal_approx(Vector3(1, 0, 0)), "effect anchor samples the same source chain at the visual phase")
	_expect(is_equal_approx(motion.sampled_visual_phase, 0.5), "public sampled visual phase matches mesh/effect pose")
	motion.native["motion"] = {"visual_period_seconds": 1.0}
	motion.autonomous = true
	motion.reset_playback(0, 0.25, 0.0)
	motion._physics_process(0.1)
	_expect(is_equal_approx(motion.sampled_visual_phase, 0.35), "autonomous reset changes the actual ticker, not only the rendered pose")
	motion.autonomous = false
	var collider: NativeGraphColliders = _player([_node(1, 0)])
	collider.player.position = Vector3(2, 3, 4)
	collider.refresh()
	_expect((collider.active_boxes[0].center as Vector3).is_equal_approx(Vector3(2, 3.5, 4)), "node-local bounds compose with player visual transform")
	var actor: NativeStateActor = _actor([_state(4)])
	actor.motion._world_track = track
	actor.motion._actions[0]["phase_domain"] = "distance"
	actor.motion._actions[0]["root_motion_length"] = 2.0
	actor._physics_process(0.5)
	_expect(is_equal_approx(actor.visual_phase, actor.visual.position.length() / 2.0), "distance action advances by actual world displacement over native cycle length")


func _test_oriented_boxes() -> void:
	var pose := Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3.ZERO)
	var a: Dictionary = NativeGraphColliders.make_box(pose, Vector3.ZERO, Vector3(2, 0.5, 0.1))
	var bpose: Transform3D = pose
	bpose.origin = pose.basis.z * 0.3
	var b: Dictionary = NativeGraphColliders.make_box(bpose, Vector3.ZERO, Vector3(2, 0.5, 0.1))
	_expect((a.aabb as AABB).intersects(b.aabb), "oriented-box regression actually has overlapping enclosing AABBs")
	_expect(not NativeGraphColliders.boxes_intersect(a, b), "separating axes reject rotated boxes whose AABBs overlap")
	bpose.origin = pose.basis.z * 0.19
	b = NativeGraphColliders.make_box(bpose, Vector3.ZERO, Vector3(2, 0.5, 0.1))
	_expect(NativeGraphColliders.boxes_intersect(a, b), "oriented boxes accept a real overlap")


func _test_physical_slot() -> void:
	var empty: Dictionary = _node(0, 0)
	empty.bounds = null
	var first_box: Dictionary = _node(0, 0)
	first_box.node_index = 1
	var second: Dictionary = _node(0, 0)
	second.node_index = 2
	second.bounds = [[-10, -10, -10], [10, 10, 10]]
	var state: Dictionary = _state(8)
	var actor: NativeStateActor = _actor([state], [empty, first_box, second])
	actor.visual.position = Vector3(100, 0, 0)
	actor.graph_colliders.refresh()
	await physics_frame
	await physics_frame
	var physics: PhysicsDirectSpaceState3D = level.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(Vector3(100, 5, 0), Vector3(100, -5, 0), 1)
	_expect(not physics.intersect_ray(ray).is_empty(), "native flag8 uses packed collider0 even when graph node0 is empty")
	ray.from.x = 100.75
	ray.to.x = 100.75
	_expect(physics.intersect_ray(ray).is_empty(), "physical wrapper uses source slot0, not the union of graph boxes")
	for flag: int in [16, 24, 0]:
		state.flags = flag
		actor._transition(0, false)
		await physics_frame
		await physics_frame
		ray.from.x = 100.0
		ray.to.x = 100.0
		_expect(physics.intersect_ray(ray).is_empty() == (flag == 0), "physical flag%d uses native nonzero gate" % flag)
