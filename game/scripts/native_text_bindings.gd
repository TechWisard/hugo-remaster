class_name NativeTextBindings
extends RefCounted
## Owners refresh these bindings only on language changes or value changes.
## Weak references avoid retaining dialogs or controls that have been freed.

const Localizer = preload("res://scripts/native_localization.gd")
var _entries: Array[Dictionary] = []


func bind_property(target: Object, property: StringName, key: String, arguments: Dictionary = {}) -> void:
	for entry: Dictionary in _entries:
		if entry.target.get_ref() == target and entry.get("property") == property:
			entry.key = key
			entry.arguments = arguments.duplicate()
			_apply(entry)
			return
	var entry: Dictionary = {"target": weakref(target), "property": property,
		"key": key, "arguments": arguments.duplicate()}
	_entries.append(entry)
	_apply(entry)


func bind_item(target: OptionButton, index: int, key: String) -> void:
	var entry: Dictionary = {"target": weakref(target), "item": index, "key": key, "arguments": {}}
	_entries.append(entry)
	_apply(entry)


func refresh() -> void:
	var live: Array[Dictionary] = []
	for entry: Dictionary in _entries:
		if is_instance_valid(entry.target.get_ref()):
			_apply(entry)
			live.append(entry)
	_entries = live


func _apply(entry: Dictionary) -> void:
	var target: Object = entry.target.get_ref()
	if not is_instance_valid(target):
		return
	var translated: String = Localizer.text(str(entry.key), entry.arguments)
	if entry.has("item"):
		var option := target as OptionButton
		var index: int = int(entry.item)
		if index >= 0 and index < option.item_count and option.get_item_text(index) != translated:
			option.set_item_text(index, translated)
	elif target.get(entry.property) != translated:
		target.set(entry.property, translated)
