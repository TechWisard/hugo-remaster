extends SceneTree
## Regression for sustained S at the Beach camera-rail endpoint. Uses the
## imported level, ordinary movement inputs and real terrain contacts.
const LevelScript=preload("res://scripts/original_level.gd")
const AudioScript=preload("res://scripts/native_audio.gd")
var checks: int=0
var failures: Array[String]=[]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not ResourceLoader.exists("res://assets/generated/levels/g006.glb","PackedScene"):
		print("NATIVE_CAMERA_BACKTRACK SKIP: imported Beach is unavailable")
		quit()
		return
	root.size=Vector2i(1280,720)
	var campaign: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/campaign.json"))
	var gameplay: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/gameplay_manifest.json"))
	AudioScript.configure_catalog(gameplay.audio)
	for bus: String in ["Music","Effects"]:
		if AudioServer.get_bus_index(bus)<0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count-1,bus)
	var entry: Dictionary={}
	for candidate: Dictionary in campaign.levels:
		if candidate.id=="g006":entry=candidate
	for prefix: int in [0,90]:
		var level: OriginalLevel=LevelScript.new()
		level.entry=entry
		level.data=JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/levels/g006.json"))
		level.gameplay=gameplay.levels.g006
		level.native_rules=gameplay.native_rules
		root.add_child(level)
		for i: int in range(60):await _tick()
		var source_tracks: Dictionary=level.data.native_transform_tracks.duplicate(true)
		var start: Vector3=level.player.global_position
		if prefix>0:
			Input.action_press("move_forward")
			for i: int in range(prefix):await _tick()
			Input.action_release("move_forward")
		Input.action_press("move_back")
		var entered_guard: bool=false
		var unsupported: int=0
		var reversed: int=0
		var out_of_view: int=0
		var previous: Vector3=level.player.global_position
		# Stop before the authored outer shore edge: this test must not create a
		# floor or pretend that walking beyond the map is safe terrain.
		for i: int in range(205+prefix):
			await _tick()
			# A short downward step legitimately has a few airborne ticks. Check
			# the actual floor below the feet, rather than calling every such
			# contact transition a hole or forcing the character onto a plane.
			var feet: Vector3=level.player.global_position
			var query:=PhysicsRayQueryParameters3D.create(feet+Vector3.UP*0.1,feet-Vector3.UP*0.65,1,[level.player.get_rid()])
			query.hit_back_faces=true
			var support: Dictionary=level.get_world_3d().direct_space_state.intersect_ray(query)
			if support.is_empty() or support.position.y>feet.y+0.04:unsupported+=1
			if level.camera_rig.backtracking_clearance_active:
				entered_guard=true
				if level.player.global_position.x>previous.x+0.015:reversed+=1
				var point: Vector2=level.camera_rig.camera.unproject_position(level.player.global_position+Vector3.UP*level.player.character_height*0.5)
				if not Rect2(Vector2.ZERO,Vector2(root.size)).has_point(point):out_of_view+=1
			previous=level.player.global_position
		Input.action_release("move_back")
		_check(entered_guard,"S reaches the source camera endpoint after %d W ticks"%prefix)
		_check(reversed==0,"held S does not reverse direction around the camera after %d W ticks"%prefix)
		_check(out_of_view==0,"Hugo's body centre stays framed throughout the endpoint guard after %d W ticks"%prefix)
		_check(level.player.global_position.x<start.x-15.0,"held S advances beyond the former camera trap after %d W ticks"%prefix)
		_check(unsupported<=1,"actual sand support stays beneath the feet on this S route after %d W ticks"%prefix)
		_check(source_tracks==level.data.native_transform_tracks,"the framing guard preserves every source track after %d W ticks"%prefix)
		level.queue_free()
		await process_frame
	print("NATIVE_CAMERA_BACKTRACK checks=",checks," failures=",JSON.stringify(failures))
	quit(0 if failures.is_empty() else 1)

func _tick() -> void:
	await physics_frame
	await process_frame

func _check(condition: bool,message: String) -> void:
	checks+=1
	if not condition:
		failures.append(message)
		push_error(message)
