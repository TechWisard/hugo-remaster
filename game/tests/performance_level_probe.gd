extends OriginalLevel
## Opt-in benchmark instrumentation; the shipped game does not instantiate this.

var stage_ms: Dictionary = {}


func _enable_vertex_colors(node: Node) -> void:
	var start: int = Time.get_ticks_usec()
	super._enable_vertex_colors(node)
	stage_ms["material_setup"] = float(Time.get_ticks_usec() - start) / 1000.0


func _build_collision() -> void:
	var start: int = Time.get_ticks_usec()
	super._build_collision()
	stage_ms["collision_setup"] = float(Time.get_ticks_usec() - start) / 1000.0


func _create_player() -> void:
	var start: int = Time.get_ticks_usec()
	super._create_player()
	stage_ms["player_setup"] = float(Time.get_ticks_usec() - start) / 1000.0


func _create_motions() -> void:
	var start: int = Time.get_ticks_usec()
	super._create_motions()
	stage_ms["motion_setup"] = float(Time.get_ticks_usec() - start) / 1000.0


func _create_entities() -> void:
	var start: int = Time.get_ticks_usec()
	super._create_entities()
	stage_ms["entity_setup"] = float(Time.get_ticks_usec() - start) / 1000.0


func _create_effects() -> void:
	var start: int = Time.get_ticks_usec()
	super._create_effects()
	stage_ms["effect_setup"] = float(Time.get_ticks_usec() - start) / 1000.0
