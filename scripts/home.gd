extends Node2D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_select_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/level_select_grid.tscn")


func _on_reset_button_pressed() -> void:
	Progress.reset()
