extends SceneTree

const Graph = preload("res://scripts/native_graph_colliders.gd")
const Sampler = preload("res://scripts/original_animation.gd")
const Motion = preload("res://scripts/native_actor_motion.gd")
var checks: int = 0
var failures: Array[String] = []

class Receiver extends Node:
	var physical_flags: int = 8
	var logic_enabled: bool = true
	func is_logic_enabled() -> bool:
		return logic_enabled


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var visual := Node3D.new()
	root.add_child(visual)
	var receiver := Receiver.new()
	visual.add_child(receiver)
	var sampler := Sampler.new()
	visual.add_child(sampler)
	var motion := Motion.new()
	var box: Dictionary = {"bounds": [[-50, -50, -50], [50, 50, 50]], "collision_mask_a": 1,
		"collision_mask_b": 2, "transform_chain": [{"group": 1, "record": 0}]}
	var graph := Graph.new()
	graph.owner_visual = visual
	graph.receiver = receiver
	graph.sampler = sampler
	graph.motion = motion
	graph.tracks = {"g001_r0000": {"initial_translation": [0, 0, 0], "translation_keys": []},
		"g001_r0001": {"initial_translation": [0, 0, 0], "translation_keys": [[0, 0, 0], [100, 0, 0]]}}
	var moving: Dictionary = box.duplicate(true)
	moving.transform_chain = [{"group": 1, "record": 1}]
	graph.source = {"actions": [{"index": 0, "collision_nodes": [box]}, {"index": 1, "collision_nodes": [moving]}]}
	visual.add_child(graph)
	graph.set_physics_process(false)
	_check(graph.active_boxes.size() == 1 and is_instance_valid(graph.physical_body), "source box and physical slot created")
	var original: Array = graph.active_boxes.duplicate(true)
	var refreshed: int = graph.refreshed_poses
	for tick: int in range(60):
		motion.sampled_visual_phase = float(tick) / 60.0
		graph.refresh()
	_check(graph.active_boxes == original and graph.refreshed_poses == refreshed, "fixed box reused across changing visual phases")
	_check(graph.reused_poses == 60, "one cache reuse for each stable frame")
	visual.position = Vector3(3, 4, 5)
	graph.refresh()
	_check(graph.active_boxes[0].center == Vector3(3, 4, 5), "world movement invalidates cached OBB")
	_check(graph.physical_body.global_position == Vector3(3, 4, 5), "physical body follows changed world pose")
	motion.active_action = 1
	motion.sampled_visual_phase = 0.25
	graph.refresh()
	var first: Vector3 = graph.active_boxes[0].center
	motion.sampled_visual_phase = 0.75
	graph.refresh()
	_check(graph.active_boxes[0].center != first, "animated source track invalidates by phase")
	var cached: Array = graph.active_boxes.duplicate(true)
	graph.invalidate_pose()
	graph.refresh()
	_check(graph.active_boxes == cached, "cached and freshly sampled OBB agree")
	receiver.physical_flags = 0
	graph.refresh()
	_check(graph.physical_body.collision_layer == 0, "physical state flag disables collider without changing action")
	receiver.physical_flags = 16
	graph.refresh()
	_check(graph.physical_body.collision_layer == 1, "physical state flag restores collider")
	visual.hide()
	graph.refresh()
	_check(graph.active_boxes.is_empty() and graph.physical_body.collision_layer == 0, "hidden scope invalidates both collision forms")
	visual.show()
	graph.refresh()
	_check(graph.active_boxes == cached and graph.physical_body.collision_layer == 1, "visible scope resamples same source box")
	graph.enabled = false
	graph.refresh()
	_check(graph.active_boxes.is_empty(), "disabled graph clears cached boxes")
	graph.enabled = true
	graph.refresh()
	_check(graph.active_boxes == cached, "reenabled graph restores collision")
	receiver.logic_enabled = false
	graph.refresh()
	_check(graph.active_boxes.is_empty(), "removed receiver has no cached collider")
	receiver.logic_enabled = true
	graph.refresh()
	_check(graph.active_boxes == cached, "receiver reset restores original collider")
	motion.free()
	visual.queue_free()
	await process_frame
	print("NATIVE_COLLISION_CACHE ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)
