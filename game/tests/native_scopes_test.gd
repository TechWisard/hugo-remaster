extends SceneTree
## Native residency policy against the real runtime manager, no source assets.

class CameraRig extends Node3D:
	var native_phase: float = 0.0
	var camera: Camera3D = Camera3D.new()
	func _ready() -> void:
		add_child(camera)

class Host extends Node3D:
	var camera_rig: CameraRig = CameraRig.new()
	var events: Array = []
	var gates: Dictionary = {}
	func _ready() -> void:
		add_child(camera_rig)
	func native_scope_loaded(group: int) -> void:
		events.append(["load", group])
	func native_scope_unloaded(group: int) -> void:
		events.append(["unload", group])
	func set_native_owner_active(id: String, resident: bool, active: bool) -> void:
		gates[id] = {"resident": resident, "active": active}

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var host := Host.new()
	root.add_child(host)
	var scopes := NativeScopes.new()
	scopes.level = host
	scopes.policy = {"main_group": 1, "persistent_groups": [0, 1],
		"initial_segment_groups": [2], "max_resident_segments": 2,
		"segments": [{"group": 2, "source_container_offset": 100},
			{"group": 3, "source_container_offset": 200}, {"group": 4, "source_container_offset": 300}],
		"actor_progress": {"phase_multiplier": 992.0},
		"actor_ranges": {"ranged": {"minimum": 248, "maximum": 496},
			"never": {"minimum": 40, "maximum": 30}},
		"triggers": [
			{"id": "p2", "group": 2, "origin": [0, 0, 0], "normal": [1, 0, 0], "previous_group": null, "next_group": 3},
			{"id": "p3", "group": 3, "origin": [100, 0, 0], "normal": [1, 0, 0], "previous_group": 2, "next_group": 4},
			{"id": "p4", "group": 4, "origin": [200, 0, 0], "normal": [1, 0, 0], "previous_group": 3, "next_group": null}]}
	# Match the actual importer/runtime boundary, including JSON numeric types.
	scopes.policy = JSON.parse_string(JSON.stringify(scopes.policy)) as Dictionary
	scopes.owner_groups = {"main": 1, "a2": 2, "a3": 3, "a4": 4,
		"p2": 2, "p3": 3, "p4": 4, "ranged": 1, "never": 1}
	scopes.prepare()
	host.add_child(scopes)
	scopes.start()
	scopes.set_physics_process(false)
	_check(scopes.resident_groups == [2], "initial source residency contains only the first segment")
	_check(scopes.is_owner_active("main") and scopes.is_owner_active("a2") and not scopes.is_owner_active("a3"), "main persists and unloaded children do not activate")
	scopes.evaluate_planes(Vector3(-1, 1000, 1000))
	_check(scopes.resident_groups == [2], "negative side with no previous segment does not load")
	scopes.evaluate_planes(Vector3(1, 1000, 1000))
	_check(scopes.resident_groups == [2, 3], "camera plane works far outside any plausible trigger AABB")
	host.events.clear()
	scopes.evaluate_planes(Vector3(101, 0, 0))
	_check(scopes.resident_groups == [3, 4], "forward crossing preserves a two-segment resident window")
	_check(host.events == [["unload", 2], ["load", 4]], "eviction finishes before loading the new segment")
	_check(not scopes.is_owner_active("a2") and scopes.is_owner_active("a4"), "scope transition updates actor gates")
	host.events.clear()
	scopes.evaluate_planes(Vector3(50, 0, 0))
	_check(scopes.resident_groups == [2, 3] and host.events == [["unload", 4], ["load", 2]], "backtracking evicts the opposite window end")
	host.events.clear()
	scopes.request_group(3)
	_check(host.events.is_empty(), "requesting a resident segment does not recreate actors")
	scopes.restore_membership({"resident_groups": [3, 4]})
	_check(scopes.resident_groups == [3, 4], "checkpoint restores the saved residency")
	_check(host.events == [["unload", 2], ["unload", 3], ["load", 3], ["load", 4]], "checkpoint reloads even a segment shared with the old resident set")
	scopes.policy.triggers = []
	host.camera_rig.native_phase = 0.25
	scopes._physics_process(0.0)
	_check(scopes.camera_progress == 248 and scopes.is_owner_active("ranged"), "camera phase uses992 multiplier and inclusive minimum")
	host.camera_rig.native_phase = 0.5
	scopes._physics_process(0.0)
	_check(scopes.camera_progress == 496 and scopes.is_owner_active("ranged"), "authored maximum is inclusive")
	host.camera_rig.native_phase = 0.5011
	scopes._physics_process(0.0)
	_check(scopes.camera_progress == 497 and not scopes.is_owner_active("ranged"), "progress truncates and suspends outside the authored interval")
	_check(not scopes.is_owner_active("never"), "reversed source interval stays disabled without sorting")
	_check(scopes.is_owner_resident("ranged"), "range suspension is distinct from source scope unloading")
	_check(scopes.snapshot() == {"resident_groups": [3, 4]}, "residency snapshot stores source group IDs")
	print("NATIVE_SCOPES_TEST checks=%d failures=%d" % [checks, failures])
	host.free()
	quit(1 if failures else 0)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)
