extends SceneTree

var game: Control
var role: String
var sent := {}
var connect_at := 0

func _initialize() -> void:
	role = OS.get_cmdline_user_args()[0]
	call_deferred("begin")

func begin() -> void:
	game = load("res://loto.tscn").instantiate()
	root.add_child(game)
	connect_at = Time.get_ticks_msec() + 400
	if role != "--server":
		game.platform_token = role
		game.connect_game("ws://127.0.0.1:8071", role)

func once(key: String) -> bool:
	if sent.has(key):
		return false
	sent[key] = true
	return true

func send(kind: String, value: Variant = null) -> void:
	game.action.rpc_id(1, kind, value)

func verify(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		quit(1)
		assert(condition, message)

func _process(_delta: float) -> bool:
	if game == null:
		return false
	if role == "--server":
		for room in game.rooms.values():
			if room.phase == "partie" and not room.bag.is_empty():
				room.next_draw = mini(room.next_draw, Time.get_ticks_msec() + 35)
			if room.phase == "terminée" and game.wallet == null:
				verify(game.house == 60, "La plateforme doit recevoir 60 pièces sur 300.")
		return false
	var state: Dictionary = game.current
	if state.is_empty() or Time.get_ticks_msec() < connect_at:
		return false
	if state.code == "":
		if sent.has("done"):
			call_deferred("quit")
			return false
		if role == "Claire" and sent.has("leave"):
			verify(state.balance == 10000, "Quitter un salon en attente doit rembourser le carton.")
			call_deferred("quit")
			return false
		if role == "Alice" and once("create"):
			send("create", 100)
		elif role == "Claire" and once("create"):
			send("create", 500)
		elif role == "Benoit":
			for entry in state.lobby:
				if entry.host == "Alice" and once("join"):
					send("join", entry.code)
		return false
	if role == "Claire":
		verify(state.count == 1 and state.price == 500 and state.chat.is_empty(), "Le second salon doit rester isolé.")
		if once("leave"):
			send("leave")
		return false

	if state.phase == "attente" and role == "Alice":
		if once("buy"):
			send("buy", 1)
		if state.cards.size() == 2 and state.count == 2 and once("start"):
			verify(state.tickets == 3 and state.balance == 9800, "Deux cartons doivent coûter 200 pièces.")
			verify(state.prizes == [45, 45, 150], "Les gains doivent dépendre du nombre de cartons.")
			send("chat", "Bonne partie")
			send("start")

	if state.phase == "partie" and state.drawn.size() == 90 and game.current_ball_label == state.drawn.back() and role == "Alice":
		var stage: int = state.awards.size()
		if once(str(stage)):
			game.ticket_picker.select(1)
			game.ticket_picker.item_selected.emit(1)
			if stage == 0:
				verify(game.marked.is_empty() and game.claim_button.disabled, "Les numéros doivent être cochés à la main.")
				send("claim", {"stage": stage, "ticket": 0, "numbers": []})
			if stage == 2:
				game.ticket_picker.select(0)
				game.ticket_picker.item_selected.emit(0)
				verify(game.marked.get(0, []).is_empty(), "Les coches ne doivent pas passer d’un carton à l’autre.")
			if stage != 1:
				for cell in game.ticket_cells:
					if not cell.disabled:
						cell.pressed.emit()
			verify(not game.claim_button.disabled, "La réclamation correcte doit être possible.")
			game.claim_button.pressed.emit()

	if state.phase == "terminée" and once("done"):
		verify(state.drawn.size() == 90 and state.awards.size() == 3, "Les trois lots doivent avoir un gagnant.")
		verify(state.awards[0].ticket == 2 and state.awards[1].ticket == 2 and state.awards[2].ticket == 1,
			"Le gagnant doit être associé au bon carton.")
		verify(state.balance == (10040 if role == "Alice" else 9900), "Solde final incorrect.")
		verify(state.chat.size() == (4 if state.test_mode else 5) and state.chat[0].contains("Bonne partie"), "Chat ou annonces manquants.")
		print(role, " : partie, cartons, réclamations et solde vérifiés")
		send("leave")
	return false
