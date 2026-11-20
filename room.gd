extends RefCounted

const TITLES := ["Première quine", "Deuxième quine", "Carton plein"]
const PRICES := [50, 100, 500, 1000]

var wallet_id := ""
var accounts := {}
var pending_balance := false
var cancelling := false
var wallet_job := false
var retry_at := 0
var winning_accounts := [null, null, null]
var host: int
var price: int
var players := {}
var cards := {}
var tickets := 0
var drawn: Array[int] = []
var bag: Array[int] = []
var awards: Array[Dictionary] = []
var claimed_lines := {}
var marks := {}
var wait_until := Time.get_ticks_msec() + 1500000
var retain_until := 0
var chat: Array[String] = []
var phase := "attente"
var next_draw := 0
var final_window := false

func _init(owner: int, stake: int) -> void:
	host = owner
	price = stake

func add_player(id: int, nickname: String) -> void:
	if not players.has(id):
		players[id] = nickname
		cards[id] = []
	cards[id].append(make_card())
	tickets += 1

static func make_card() -> Array:
	var card := [[], [], []]
	var columns := []
	for column in range(9):
		var pool := range(maxi(1, column * 10), 91 if column == 8 else (column + 1) * 10)
		pool.shuffle()
		columns.append(pool)
	for row in range(3):
		var choices := range(9)
		choices.shuffle()
		var selected := choices.slice(0, 5)
		selected.sort()
		for column in range(9):
			card[row].append(columns[column].pop_back() if column in selected else 0)
	var occupancy := []
	for column in range(9):
		var occupied := 0
		for row in card:
			occupied += int(row[column] != 0)
		occupancy.append(occupied)
	for column in range(9):
		if occupancy[column] != 0:
			continue
		for row in card:
			var donor := -1
			for other in range(9):
				if row[other] != 0 and occupancy[other] > 1:
					donor = other
					break
			if donor >= 0:
				row[donor] = 0
				row[column] = columns[column].pop_back()
				occupancy[donor] -= 1
				occupancy[column] += 1
				break
	for column in range(9):
		var values := []
		for row in range(3):
			if card[row][column] != 0:
				values.append(card[row][column])
		values.sort()
		for row in range(3):
			if card[row][column] != 0:
				card[row][column] = values.pop_front()
	return card

func prizes() -> Array[int]:
	var total := price * tickets
	var quine := floori(total * 0.15)
	return [quine, quine, floori(total * 0.50)]

func start() -> void:
	bag.assign(range(1, 91))
	var crypto := Crypto.new()
	for index in range(bag.size() - 1, 0, -1):
		var choices := index + 1
		var range_end := 65536 - (65536 % choices)
		var random := crypto.generate_random_bytes(2).decode_u16(0)
		while random >= range_end:
			random = crypto.generate_random_bytes(2).decode_u16(0)
		var selected := random % choices
		var previous := bag[index]
		bag[index] = bag[selected]
		bag[selected] = previous
	phase = "partie"
	next_draw = Time.get_ticks_msec() + 2500

func draw() -> void:
	drawn.append(bag.pop_back())
	next_draw = Time.get_ticks_msec() + 10000

func complete(row: Array) -> bool:
	for number in row:
		if number != 0 and number not in drawn:
			return false
	return true

func eligible(id: int, ticket: int, marked: Array) -> int:
	if phase != "partie" or not cards.has(id):
		return -1
	if ticket < 0 or ticket >= cards[id].size():
		return -1
	var card: Array = cards[id][ticket]
	var key := Vector2i(id, ticket)
	if awards.size() == 2:
		for row in card:
			if not complete(row) or not marked_row(row, marked):
				return -1
		return 3
	for index in range(3):
		if index not in claimed_lines.get(key, []) and complete(card[index]) and marked_row(card[index], marked):
			return index
	return -1

func used_lines(id: int) -> Dictionary:
	var lines := {}
	for key: Vector2i in claimed_lines:
		if key.x == id:
			lines[key.y] = claimed_lines[key]
	return lines

static func marked_row(row: Array, marked: Array) -> bool:
	for number in row:
		if number != 0 and number not in marked:
			return false
	return true

func award(id: int, ticket: int, line: int) -> int:
	var stage := awards.size()
	var gain := prizes()[stage]
	if stage < 2:
		var key := Vector2i(id, ticket)
		if not claimed_lines.has(key):
			claimed_lines[key] = []
		claimed_lines[key].append(line)
	awards.append({"title": TITLES[stage], "name": players[id], "gain": gain, "ticket": ticket + 1})
	add_chat("Tirage · %s — %s remporte %d pièces." % [TITLES[stage], players[id], gain])
	if not final_window:
		next_draw = Time.get_ticks_msec() + 5500
	if stage == 2:
		phase = "terminée"
	return gain

func add_chat(message: String) -> void:
	chat.append(message)
	if chat.size() > 40:
		chat.pop_front()

func mark_number(id: int, ticket: int, number: int) -> bool:
	if phase != "partie" or drawn.is_empty() or number != drawn.back() or not cards.has(id):
		return false
	if ticket < 0 or ticket >= cards[id].size():
		return false
	for row in cards[id][ticket]:
		if number in row:
			var key := Vector2i(id, ticket)
			var previous: Array = marks.get(key, [])
			if number in previous:
				return false
			previous.append(number)
			marks[key] = previous
			return true
	return false

func player_marks(id: int) -> Dictionary:
	var result := {}
	for key: Vector2i in marks:
		if key.x == id:
			result[key.y] = marks[key]
	return result

func reassign_player(old_id: int, new_id: int) -> void:
	for entry: Dictionary in [players, cards, accounts]:
		if entry.has(old_id):
			entry[new_id] = entry[old_id]
			entry.erase(old_id)
	for entry: Dictionary in [marks, claimed_lines]:
		for key: Vector2i in entry.keys():
			if key.x == old_id:
				entry[Vector2i(new_id, key.y)] = entry[key]
				entry.erase(key)
	if host == old_id:
		host = new_id
