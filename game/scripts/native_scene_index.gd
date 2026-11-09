class_name NativeSceneIndex
extends RefCounted
## Exact source names are indexed once instead of searching the whole tree per owner.
## First depth-first match is retained, matching find_child(name, true, false).


static func descendants(root: Node) -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[Node] = []
	var children: Array[Node] = root.get_children()
	for index: int in range(children.size() - 1, -1, -1):
		pending.append(children[index])
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var key: String = str(node.name)
		if not result.has(key):
			result[key] = node
		children = node.get_children()
		for index: int in range(children.size() - 1, -1, -1):
			pending.append(children[index])
	return result
