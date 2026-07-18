class_name HighScoreData
extends Resource

## Holds the high score table. Each entry is {"name": String, "score": int},
## kept sorted by score, descending.

const MAX_ENTRIES := 10

@export var entries: Array[Dictionary] = []


func add_entry(player_name: String, score: int) -> void:
	entries.append({"name": player_name, "score": score})
	entries.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	if entries.size() > MAX_ENTRIES:
		entries = entries.slice(0, MAX_ENTRIES)
