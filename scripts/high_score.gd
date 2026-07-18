extends Node

## HighScore autoload.
##
## Public API:
##   HighScore.submit_score("AAA", 10000)
##   HighScore.is_high_score(9000)
##   HighScore.get_scores()  -> Array[Dictionary] of {"name": ..., "score": ...}
##   HighScore.get_best()    -> highest score, 0 if none
##   HighScore.clear_scores()
##
## Scores live in a HighScoreData resource persisted to user://, and are
## exported as /arcade/scores/<game_id>.json per the GD_ArcadeLauncher spec
## (https://github.com/thygrrr/GD_ArcadeLauncher) on every update and on exit.

signal scores_changed

const ScoreData := preload("res://scripts/high_score_data.gd")
const MAX_SCORES := ScoreData.MAX_ENTRIES
const RESOURCE_PATH := "user://high_scores.tres"
const ARCADE_SCORES_DIR := "/arcade/scores"

var data: ScoreData
var _game_id: String


func _init() -> void:
	_game_id = _detect_game_id()
	data = _load_data()


func _exit_tree() -> void:
	# Runs on get_tree().quit() (e.g. ui_exit) and normal shutdown.
	_save_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_all()


## Adds a score to the table. Returns the entry's rank (0 = best),
## or -1 if it didn't make the top MAX_SCORES.
func submit_score(player_name: String, score: int) -> int:
	data.add_entry(player_name, score)
	_save_all()
	scores_changed.emit()
	for i in data.entries.size():
		if data.entries[i]["name"] == player_name and int(data.entries[i]["score"]) == score:
			return i
	return -1


## True if this score would make it onto the table.
func is_high_score(score: int) -> bool:
	if data.entries.size() < MAX_SCORES:
		return true
	return score > int(data.entries[-1]["score"])


## Sorted copy of the table, best first.
func get_scores() -> Array[Dictionary]:
	return data.entries.duplicate()


## Highest score on the table, 0 if the table is empty.
func get_best() -> int:
	return int(data.entries[0]["score"]) if not data.entries.is_empty() else 0


func clear_scores() -> void:
	data.entries.clear()
	_save_all()
	scores_changed.emit()


func _load_data() -> ScoreData:
	if ResourceLoader.exists(RESOURCE_PATH):
		var loaded := ResourceLoader.load(RESOURCE_PATH)
		if loaded is ScoreData:
			return loaded
	return ScoreData.new()


func _save_all() -> void:
	if data == null:
		return
	var err := ResourceSaver.save(data, RESOURCE_PATH)
	if err != OK:
		push_warning("HighScore: failed to save %s (%s)" % [RESOURCE_PATH, error_string(err)])
	_write_arcade_json()


func _write_arcade_json() -> void:
	var json := JSON.stringify(data.entries, "  ")
	var f: FileAccess = null
	var path := ""
	if DirAccess.dir_exists_absolute(ARCADE_SCORES_DIR.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(ARCADE_SCORES_DIR)
		path = ARCADE_SCORES_DIR.path_join("%s.json" % _game_id)
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		# Not on the arcade cabinet (e.g. a dev machine) — keep a copy
		# in user:// so the output can still be inspected.
		path = "user://%s.json" % _game_id
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("HighScore: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(json)


func _detect_game_id() -> String:
	# The launcher keys scores by the game's folder name under /arcade/games/.
	if not OS.has_feature("editor"):
		var folder := OS.get_executable_path().get_base_dir().get_file()
		if not folder.is_empty():
			return folder
	return str(ProjectSettings.get_setting("application/config/name", "game")).to_lower().replace(" ", "_")
