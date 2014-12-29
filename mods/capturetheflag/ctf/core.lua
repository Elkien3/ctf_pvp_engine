ctf.registered_on_load = {}
function ctf.register_on_load(func)
	table.insert(ctf.registered_on_load, func)
end
ctf.registered_on_save = {}
function ctf.register_on_save(func)
	table.insert(ctf.registered_on_save, func)
end

function ctf.init()
	print("[CaptureTheFlag] Initialising...")

	-- Set up structures
	ctf._defsettings = {}
	ctf.teams = {}
	ctf.players = {}
	ctf.claimed = {}

	-- See minetest.conf.example in the root of this subgame

	-- Settings: Feature enabling
	ctf._set("node_ownership",             true)
	ctf._set("multiple_flags",             true)
	ctf._set("flag_capture_take",          false)
	ctf._set("gui",                        true)
	ctf._set("hud",                        true)
	ctf._set("team_gui",                   true)
	ctf._set("flag_teleport_gui",          true)
	ctf._set("spawn_in_flag_teleport_gui", false)
	ctf._set("news_gui",                   true)
	ctf._set("diplomacy",                  true)
	ctf._set("flag_names",                 true)
	ctf._set("team_channel",               true)
	ctf._set("global_channel",             true)
	ctf._set("players_can_change_team",    true)

	-- Settings: Teams
	ctf._set("allocate_mode",              0)
	ctf._set("maximum_in_team",            -1)
	ctf._set("default_diplo_state",        "war")

	-- Settings: Misc
	ctf._set("flag_protect_distance",      25)
	ctf._set("team_gui_initial",           "news")

	ctf.load()
end

-- Set default setting value
function ctf._set(setting,default)
	ctf._defsettings[setting] = default
end

function ctf.setting(name)
	local set = minetest.setting_get("ctf_"..name)
	local dset = ctf._defsettings[name]
	if set ~= nil then
		if type(dset) == "number" then
			return tonumber(set)
		elseif type(dset) == "bool" then
			return minetest.is_yes(set)
		else
			return set
		end
	elseif dset ~= nil then
		return ctf._defsettings[name]
	else
		print("[CaptureTheFlag] Setting "..name.." not found!")
		return nil
	end
end

function ctf.load()
	local file = io.open(minetest.get_worldpath().."/ctf.txt", "r")
	if file then
		local table = minetest.deserialize(file:read("*all"))
		if type(table) == "table" then
			ctf.teams = table.teams
			ctf.players = table.players

			for i = 1, #ctf.registered_on_load do
				ctf.registered_on_load[i](table)
			end
			return
		end
	end
end

function ctf.save()
	print("[CaptureTheFlag] Saving data...")
	local file = io.open(minetest.get_worldpath().."/ctf.txt", "w")
	if file then
		local out = {
			teams = ctf.teams,
			players = ctf.players
		}

		for i = 1, #ctf.registered_on_save do
			local res = ctf.registered_on_save[i]()

			if res then
				for key, value in pairs(res) do
					out[key] = value
				end
			end
		end

		file:write(minetest.serialize(out))
		file:close()
	end
end

-- Get or add a team
function ctf.team(name) -- get or add a team
	if type(name) == "table" then
		if not name.add_team then
			error("Invalid table given to ctf.team")
			return
		end

		print("Defining team "..name.name)

		ctf.teams[name.name]={
			data = name,
			spawn=nil,
			players={},
			flags = {}
		}

		ctf.save()

		return ctf.teams[name.name]
	else
		return ctf.teams[name]
	end
end

-- Count number of players in a team
function ctf.count_players_in_team(team)
	local count = 0
	for name, player in pairs(ctf.team(team).players) do
		count = count + 1
	end
	return count
end

-- get a player
function ctf.player(name)
	return ctf.players[name]
end

-- Player joins team
function ctf.join(name, team, force)
	if not name or name == "" or not team or team == "" then
		return false
	end

	local player = ctf.player(name)

	if not player then
		player = {name = name}
	end

	if not force and not ctf.setting("players_can_change_team") and (not player.team or player.team == "") then
		minetest.chat_send_player(name, "You are not allowed to switch teams, traitor!")
		return false
	end

	if ctf.add_user(team, player) == true then
		minetest.chat_send_all(name.." has joined team "..team)

		if ctf.setting("hud") then
			ctf.hud.update(minetest.get_player_by_name(name))
		end

		return true
	end
	return false
end

-- Add a player to a team in data structures
function ctf.add_user(team, user)
	local _team = ctf.team(team)
	local _user = ctf.player(user.name)
	if _team and user and user.name then
		if _user and _user.team and ctf.team(_user.team) then
			ctf.teams[_user.team].players[user.name] = nil
		end

		user.team = team
		user.auth = false
		_team.players[user.name]=user
		ctf.players[user.name] = user
		ctf.save()

		return true
	else
		return false
	end
end

-- Cleans up the player lists
function ctf.clean_player_lists()
	for _, str in pairs(ctf.players) do
		if str and str.team and ctf.teams[str.team] then
			print("Adding player "..str.name.." to team "..str.team)
			ctf.teams[str.team].players[str.name] = str
		else
			print("Skipping player "..str.name)
		end
	end
end

-- Get info for ctf.claimed
function ctf.collect_claimed()
	ctf.claimed = {}
	for _, team in pairs(ctf.teams) do
		for i = 1, #team.flags do
			if team.flags[i].claimed then
				table.insert(ctf.claimed, team.flags[i])
			end
		end
	end
end

-- Sees if the player can change stuff in a team
function ctf.can_mod(player,team)
	local privs = minetest.get_player_privs(player)

	if privs then
		if privs.team == true then
		 	return true
		end
	end

	if player and ctf.teams[team] and ctf.teams[team].players and ctf.teams[team].players[player] then
		if ctf.teams[team].players[player].auth == true then
			return true
		end
	end
	return false
end

-- post a message to a team board
function ctf.post(team,msg)
	if not ctf.team(team) then
		return false
	end

	if not ctf.team(team).log then
		ctf.team(team).log = {}
	end

	table.insert(ctf.team(team).log,1,msg)
	ctf.save()

	return true
end

minetest.register_on_newplayer(function(player)
	local name = player:get_player_name()
	local max_players = ctf.setting("maximum_in_team")
	local alloc_mode = tonumber(ctf.setting("allocate_mode"))

	if alloc_mode == 0 then
		return
	elseif alloc_mode == 1 then
		local index = {}

		for key, team in pairs(ctf.teams) do
			if max_players == -1 or ctf.count_players_in_team(key) < max_players then
				table.insert(index, key)
			end
		end

		if #index == 0 then
			minetest.log("error", "[CaptureTheFlag] No teams to join!")
		else
			local team = index[math.random(1, #index)]

			print(name.." was allocated to "..team)

			ctf.join(name, team)
		end
	elseif alloc_mode == 2 then
		local one = nil
		local one_count = -1
		local two = nil
		local two_count = -1
		for key, team in pairs(ctf.teams) do
			local count = ctf.count_players_in_team(key)
			if (max_players == -1 or count < max_players) then
				if count > one_count then
					two = one
					two_count = one_count
					one = key
					one_count = count
				end

				if count > two_count then
					two = key
					two_count = count
				end
			end
		end

		if not one and not two then
			minetest.log("error", "[CaptureTheFlag] No teams to join!")
		elseif one and two then
			if math.random() > 0.5 then
				print(name.." was allocated to "..one)
				ctf.join(name, one)
			else
				print(name.." was allocated to "..two)
				ctf.join(name, two)
			end
		else
			if one then
				print(name.." was allocated to "..one)
				ctf.join(name, one)
			else
				print(name.." was allocated to "..two)
				ctf.join(name, two)
			end
		end
	elseif alloc_mode == 3 then
		local smallest = nil
		local smallest_count = 1000
		for key, team in pairs(ctf.teams) do
			local count = ctf.count_players_in_team(key)
			if not smallest or count < smallest_count then
				smallest = key
				smallest_count = count
			end
		end

		if not smallest then
			minetest.log("error", "[CaptureTheFlag] No teams to join!")
		else
			print(name.." was allocated to "..smallest)
			ctf.join(name, smallest)
		end
	else
		print("Unknown allocation mode: "..ctf.setting("allocate_mode"))
	end
end)
