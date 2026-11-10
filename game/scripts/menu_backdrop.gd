class_name HugoMenuBackdrop
extends Control
## Authored menu artwork is optional. The native gradient and small vector
## ornaments keep a source-only checkout usable without private art assets.

const ART_PATH: String = "res://assets/hd/ui/menu_background.png"
var _elapsed: float = 0.0
var _redraw_time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := TextureRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if ResourceLoader.exists(ART_PATH, "Texture2D"):
		backdrop.texture = load(ART_PATH) as Texture2D
	else:
		var gradient := Gradient.new()
		gradient.colors = PackedColorArray([Color("061e26"), Color("176470"), Color("35694d")])
		gradient.offsets = PackedFloat32Array([0.0, 0.62, 1.0])
		var texture := GradientTexture2D.new()
		texture.gradient = gradient
		texture.fill_from = Vector2(0, 0)
		texture.fill_to = Vector2(1, 0.75)
		backdrop.texture = texture
	add_child(backdrop)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
render_mode unshaded;
void fragment() {
    float left = 1.0 - smoothstep(0.12, 0.57, UV.x);
    float bottom = smoothstep(0.68, 1.0, UV.y);
    float edge = smoothstep(0.35, 0.75, distance(UV, vec2(0.55, 0.45)));
    COLOR = vec4(vec3(0.012, 0.045, 0.052), clamp(0.08 + left * 0.26 + bottom * 0.22 + edge * 0.13, 0.0, 0.72));
}"""
	material.shader = shader
	shade.material = material
	add_child(shade)
	# Decorative particles stay behind every interactive control and update at
	# 20 Hz. They never consume native gameplay particle budgets or random draws.
	var ornaments := Control.new()
	ornaments.name = "MenuLightMotes"
	ornaments.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ornaments.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.draw.connect(func() -> void: _draw_motes(ornaments))
	add_child(ornaments)
	resized.connect(ornaments.queue_redraw)


func _process(delta: float) -> void:
	_elapsed += minf(delta, 0.1)
	_redraw_time += delta
	if _redraw_time >= 0.05:
		_redraw_time = 0.0
		var motes: Control = get_node_or_null("MenuLightMotes") as Control
		if motes != null:
			motes.queue_redraw()


func _draw_motes(canvas: Control) -> void:
	for index: int in range(14):
		var phase: float = float(index) * 2.399963
		var u: float = 0.06 + fposmod(float(index) * 0.139, 0.88)
		var v: float = fposmod(0.83 + float(index) * 0.173 - _elapsed * (0.004 + index * 0.00015), 1.0)
		var point := Vector2((u + sin(_elapsed * 0.23 + phase) * 0.008) * canvas.size.x, v * canvas.size.y)
		var alpha: float = (0.13 + 0.09 * sin(_elapsed * 0.7 + phase)) * sin(PI * v)
		var radius: float = 1.1 + float(index % 3) * 0.35
		canvas.draw_circle(point, radius * 3.0, Color(1.0, 0.78, 0.35, alpha * 0.12), true, -1, true)
		canvas.draw_circle(point, radius, Color(1.0, 0.88, 0.57, alpha), true, -1, true)
