extends SceneTree

var game: Control
var role: String
var sent := {}
var connect_at := 0
var original_host := 0

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
			if room.phase == "partie" and not room.bag.is_empty() and draw_ready(room):
				room.next_draw = mini(room.next_draw, Time.get_ticks_msec() + 135)
			if room.phase == "terminée" and game.wallet == null:
				verify(game.house == 100, "La plateforme doit recevoir 100 pièces sur 500.")
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
			send("buy", 3)
		if state.cards.size() == 4 and state.count == 2 and once("start"):
			verify(state.tickets == 5 and state.balance == 9600 and game.card_views.size() == 4, "Quatre cartons visibles doivent coûter 400 pièces.")
			verify(state.prizes == [75, 75, 250], "Les gains doivent dépendre du nombre de cartons.")
			send("chat", "Bonne partie")
			send("start")

	if state.phase == "partie" and not state.drawn.is_empty() and role == "Alice":
		var count: int = state.drawn.size()
		if once("ball:%d" % count):
			if count == 1:
				verify(game.marked.is_empty(), "Une boule annoncée ne doit rien cocher automatiquement.")
			game.show_ball(state.drawn.back())
			for ticket in range(3):
				for cell in game.card_views[ticket].cells:
					if not cell.disabled:
						cell.pressed.emit()
			if count == 4 and not state.test_mode:
				call_deferred("reconnect")
		if count > 4 and sent.has("reconnect") and once("resumed"):
			verify(state.cards.size() == 4 and state.balance == 9600 and not game.marked.is_empty(),
				"Revenir dans le salon doit restaurer les cartons, les coches et le solde.")
			var previous: int = state.drawn[1]
			send("mark", {"ticket": 3, "number": previous})
		if count >= 6 and sent.has("resumed") and once("resume_report"):
			verify(game.marked.get(3, []).is_empty(), "Une ancienne boule ne peut pas être cochée.")
			send("chat", "Reprise vérifiée")

		if count == 90:
			if once("late"):
				for line in state.cards[3]:
					for number in line:
						if number > 0 and number != state.drawn.back():
							send("mark", {"ticket": 3, "number": number})
			var stage: int = state.awards.size()
			var ticket := 0 if stage == 2 else 1
			var claim: Button = game.card_views[ticket].claim
			if not claim.disabled and once("claim:%d" % stage):
				verify(game.marked.get(3, []).is_empty(), "Un carton oublié doit rester vide.")
				claim.pressed.emit()

	if "Alice · Reprise vérifiée" in state.chat:
		print(role, " : quatre cartons, reprise et marquage vérifiés")
		call_deferred("quit")
		return false
	if state.phase == "terminée" and once("done"):
		verify(state.drawn.size() == 90 and state.awards.size() == 3, "Les trois lots doivent avoir un gagnant.")
		verify(state.awards[0].ticket == 2 and state.awards[1].ticket == 2 and state.awards[2].ticket == 1,
			"Le gagnant doit être associé au bon carton.")
		verify(state.balance == (10000 if role == "Alice" else 9900), "Solde final incorrect.")
		verify(state.chat.size() == (4 if state.test_mode else 5) and state.chat[0].contains("Bonne partie"), "Chat ou annonces manquants.")
		print(role, " : partie, cartons, réclamations et solde vérifiés")
		send("leave")
	return false

func reconnect() -> void:
	await create_timer(0.1).timeout
	if not once("reconnect"):
		return
	game.multiplayer.multiplayer_peer.close()
	game.queue_free()
	await process_frame
	begin()

func draw_ready(room) -> bool:
	if room.drawn.is_empty():
		original_host = room.host
		var first_line: Array = room.cards[room.host][0][0]
		var chosen := 0
		for number in first_line:
			if number != 0:
				chosen = number
				break
		room.bag.erase(chosen)
		room.bag.append(chosen)
		var second_line: Array = room.cards[room.host][3][0]
		for number in second_line:
			if number != 0 and number != chosen:
				room.bag.erase(number)
				room.bag.insert(room.bag.size() - 1, number)
				break
		return true
	if room.drawn.size() == 4 and game.wallet and room.host == original_host:
		return false
	var number: int = room.drawn.back()
	var marks: Dictionary = room.player_marks(room.host)
	for ticket in range(3):
		for line in room.cards[room.host][ticket]:
			if number in line and number not in marks.get(ticket, []):
				return false
	return true
