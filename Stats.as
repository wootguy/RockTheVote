// using the filesystem as a database. Shouldn't be a problem until sven has millions of players (never)
// DB size for TWLZ is about 30 MB (50k unique players, mostly short visitors)
const string ROOT_DB_PATH = "scripts/plugins/store/rtv/";

// TODO
// - detect series maps so playing 50% of a series counts as a play (I always join HL late)
// - add map prefs
// - replace game_end with custom ent so script can run next map logic
// - categorize every map or add tags
// - add categories to prefs and nom menu

// Your map preferences:
// 1. Preferences enabled: [Yes, No]
// 2. Types: [action, puzzle, chill, skill, meme, Any]
// 3. Quality: [good, bad, Any]
// 4. Mode: [survival, casual, Any]

// Map preferences -> Select categories
// 1. ..
// 2. Action
// 3. Puzzle
// 5. Chill
// 6. Skill
// 7. Meme

// Total maps in your selection: 1234
// Your preferred map list has a chance to be used when deciding the next map.
// Because you have 0 maps selected, other players will decide the next map.
// Say '.cycle' for more info.

// Use bucket folders to keep filesystem lookups fast.
// For 50k unique players, 256 buckets would have 195 files each, on average
// Make sure to keep this in sync with the db_setup.py script
const uint MAX_DB_BUCKETS = 256;
const int FRESH_MAP_LIMIT = 20;
const float MIN_ACTIVE_TIME = 0.5f;

dictionary g_player_map_history; // maps steam id to PlayerMapHistory
dictionary g_player_activity; // maps steam id to time they joined the map. used to track play time for the previous map
dictionary g_prev_map_activity; // maps steam id to percentage active time in previous map
array<SteamName> g_nextmap_players; // active players from the previous map that will decide the next map for the current map
bool g_anyone_joined = false; // used to prevent double-loaded maps from clearing active player list
string g_previous_stats_map = ""; // last map which ran the map selection logic
float g_lastActiveCheck = 0;

enum MAP_RATINGS {
	RATE_NONE, // no preference or never played
	RATE_FAVORITE, // player likes the map and wants to play it all the time
	RATE_TRASH // player hates the map and never wants to play it again
}

// stats for a map by a single player
// used in a dictionary which maps a map name -> player
class MapStat {
	uint32 last_played = 0; // unix timestamp, max date of 2106
	uint16 total_plays = 0;
	uint8 rating = 0; // does the player like this map?
}

class PlayerMapHistory {
	HashMapMapStat stats = HashMapMapStat(512); // maps map name to MapStat
	
	bool loaded = false;
	File@ fileHandle = null; // for loading across multiple server frames
	int lineNum = 1;
	
	PlayerMapHistory() {}
}

class PlayerActivity {
	float totalActivity;
}

class SteamName {
	string steamid;
	string name;
	
	SteamName() {}
	
	SteamName(string steamid, string name) {
		this.steamid = steamid;
		this.name = name;
	}
}

class LastPlay {
	string steamid;
	string name;
	bool wasConsidered = false; // was considered for deciding the next map
	uint64 last_played = 0;
	int previousPlayPercent;
	int total_plays = 0;
	
	LastPlay() {}
	
	LastPlay(string steamid, string name, bool wasConsidered) {
		this.steamid = steamid;
		this.name = name;
		this.wasConsidered = wasConsidered;
		
		if (g_prev_map_activity.exists(steamid)) {
			g_prev_map_activity.get(steamid, previousPlayPercent);
		}
	}
}

enum TargetTypes {
	TARGET_SELF,
	TARGET_PLAYER,
	TARGET_ALL
}

funcdef void void_callback();

funcdef void dict_callback(dictionary);

void initStats() {
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		string steamid = getPlayerUniqueId(plr);
		
		loadPlayerMapStats(steamid, function(args){}, {});
		g_player_activity[steamid] = PlayerActivity();
	}
	
	g_lastActiveCheck = g_Engine.time;
	
	g_Scheduler.SetInterval("updatePlayerActivity", 1.0f, -1);
}

void updatePlayerActivity() {
	float delta = g_Engine.time - g_lastActiveCheck;
	g_lastActiveCheck = g_Engine.time;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (g_playerStates[i].afkTime != 0) {
			continue;
		}
		
		PlayerActivity@ activity = cast<PlayerActivity@>(g_player_activity[getPlayerUniqueId(plr)]);
		
		if (activity !is null) {
			activity.totalActivity += delta;
		}
	}
}

string getPlayerDbPath(string steamid) {
	string safeid = steamid.Replace(":", "_");
	uint64 hash = hash_FNV1a(safeid) % MAX_DB_BUCKETS;
	
	return ROOT_DB_PATH + hash + "/" + safeid + ".txt";
}

void loadPlayerMapStats(string steamid, dict_callback@ callback, dictionary callbackArgs) {
	PlayerMapHistory@ history = null;
	
	if (g_player_map_history.exists(steamid)) {
		@history = cast<PlayerMapHistory@>( g_player_map_history[steamid] );
		
		if (history !is null && history.loaded) {
			//println("Skipping map history for player - already loaded");
			callback(callbackArgs);
			return;
		}
	}
	
	string path = getPlayerDbPath(steamid);
	
	if (history is null) {
		g_player_map_history.set(steamid, PlayerMapHistory());
		@history = cast<PlayerMapHistory@>( g_player_map_history[steamid] );
		
		@history.fileHandle = g_FileSystem.OpenFile(path, OpenFile::READ);
		
		if (history.fileHandle is null or !history.fileHandle.IsOpen()) {
			history.loaded = true;
			g_Log.PrintF("[RTV] player stat file not found: " + path + "\n");
			return;
		}
	}
	
	// limit lines loaded per server frame to prevent server freezing
	const int max_line_loads_per_frame = 32;
	int linesLoaded = 0; 
	
	while (!history.fileHandle.EOFReached() and linesLoaded < max_line_loads_per_frame) {
		string line;
		history.fileHandle.ReadLine(line);
		
		if (line.IsEmpty()) {
			continue;
		}
		
		array<string> parts = line.Split(" ");
		if (parts.size() != 4) {
			g_Log.PrintF("[RTV] player stat file malformed (line " + history.lineNum + "): " + path + "\n");
			continue;
		}
		
		MapStat stat;
		
		string map_name = parts[0];
		stat.last_played = atoi(parts[1]);
		stat.total_plays = atoi(parts[2]);
		stat.rating = atoi(parts[3]);
		history.stats.put(map_name, stat);

		history.lineNum += 1;
		linesLoaded += 1;
	}

	if (history.fileHandle.EOFReached()) {
		history.fileHandle.Close();
		history.loaded = true;
		
		callback(callbackArgs);
	} else {
		g_Scheduler.SetTimeout("loadPlayerMapStats", 0.0f, steamid, callback, callbackArgs);
	}
}

// find the map that has the highest minumum age across all players (age = time since last play)
// example:
// I played stadium4 1 hour ago, but no one else has ever played it. It will not be selected
// because there are other maps which none of us have played in the last hour.
// This also means that if you never played stadium4, you might have to play
// a map that you did last week because someone else played stadium4 recently.
void setFreshMapAsNextMap(array<SortableMap>@ maps) {	
	if (g_nextmap_players.size() == 0) {
		println("No players were active in the previous map. Selecting a random next map.");
		string nextmap = maps[Math.RandomLong(0, maps.size()-1)].map;
		g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextmap + "\n");
		return;
	}
	
	sortMapsByFreshness(maps, g_nextmap_players, 0, setNextMap, {});
}

void setNextMap(dictionary args) {
	
	// prevent the same maps always being shown for players who have little history
	uint maxUnplayed = 0;
	for (uint i = 0; i < g_randomCycleMaps.size(); i++) {
		if (g_randomCycleMaps[i].sort != 0) {
			maxUnplayed = i;
			break;
		}
	}

	string nextmap = g_randomCycleMaps[Math.RandomLong(0, maxUnplayed)].map;
	
	println("[RTV] Most fresh next map: " + nextmap);
	g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextmap + "\n");
}

uint insertSort(array<SortableMap>@ a, uint i) {
	int ops = 0; // limit operations per frame so server doesn't freeze
	
    for (i; i < a.size() && ops < 2000; i++) {
        SortableMap value = SortableMap(a[i]);
		int j;
		
        for (j = i - 1; j >= 0 && a[j].sort > value.sort; j--, ops++)
            a[j + 1] = a[j];
		
        a[j + 1] = value;
    }
	
	return i;
}

void insertion_sort_step(array<SortableMap>@ a, uint i, dict_callback@ callback, dictionary callbackArgs) {
	i = insertSort(a, i);
	
	if (i < a.size()) {
		g_Scheduler.SetTimeout("insertion_sort_step", 0.0f, @a, i, callback, callbackArgs);
	} else {
		callback(callbackArgs);
	}
}

void shuffle(array<SortableMap>@ arr) {
	for (int i = arr.size()-1; i >= 1; i--) {
		int j = Math.RandomLong(0, i);
		SortableMap temp = SortableMap(arr[j]);
		arr[j] = arr[i];
		arr[i] = temp;
	}
}

// sorts according to minimum play time of all players in the server
void sortMapsByFreshness(array<SortableMap>@ maps, array<SteamName>@ activePlayers, uint pidx, dict_callback@ callback, dictionary callbackArgs) {
	if (activePlayers.size() == 0) {
		g_Log.PrintF("[RTV] No one was active in the previous map. Using current players to sort maps by freshness.\n");
		activePlayers = getAllPlayers();
		
		if (activePlayers.size() == 0) {
			g_Log.PrintF("[RTV] No one is in the server. Skipping map sort.\n");
			callback(callbackArgs);
			return;
		}
	}
	
	array<bool> isSeriesMap(maps.size());
	
	for (uint k = 0; k < maps.size(); k++) {
		maps[k].sort = 0;
		isSeriesMap[k] = g_seriesMaps.exists(maps[k].map);
	}
	
	for ( pidx; pidx < activePlayers.size(); pidx++ ) {
		string steamid = activePlayers[pidx].steamid;
		
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
		if (history is null) {
			println(steamid + " has no map history yet");
			continue;
		}
		
		for (uint k = 0; k < maps.size(); k++) {
			if (isSeriesMap[k]) {
				uint64 lastplay = getLastSeriesPlayTime(history, maps[k].map);
				if (lastplay > maps[k].sort) {
					maps[k].sort = lastplay;
				}
			} else {
				MapStat@ stat = history.stats.get(maps[k].map, maps[k].hashKey);
	
				if (stat.last_played > maps[k].sort) {
					maps[k].sort = stat.last_played;
				}
			}
		}
	}
	
	if (pidx < activePlayers.size()) {
		g_Scheduler.SetTimeout("sortMapsByFreshness", 0.0f, @maps, @activePlayers, pidx, callback, callbackArgs);
	} else {
		insertion_sort_step(maps, 1, callback, callbackArgs);
	}
}

// used to prevent parallel sorts messing up the global map lists
array<SortableMap> copyArray(array<SortableMap>@ arr) {
	array<SortableMap> newArr;
	
	for (uint i = 0; i < arr.size(); i++) {
		newArr.insertLast(SortableMap(arr[i]));
	}
	
	return newArr;
}

uint64 getLastPlayTime(string steamid, SortableMap map) {
	PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
	if (history is null) {
		return 0;
	}
	
	if (g_seriesMaps.exists(map.map)) {
		return getLastSeriesPlayTime(history, map.map);
	}
	
	return history.stats.get(map.map, map.hashKey).last_played;
}

uint64 getLastSeriesPlayTime(PlayerMapHistory@ history, string mapname) {
	array<SortableMap>@ series = cast<array<SortableMap>@>(g_seriesMaps[mapname]);
	
	uint64 mostRecent = 0;
	
	for (uint i = 0; i < series.size(); i++) {
		uint64 lastPlay = history.stats.get(series[i].map, series[i].hashKey).last_played;
		mostRecent = Math.max(lastPlay, mostRecent);
	}
	
	return mostRecent;
}

void showFreshMaps(EHandle h_plr, int targetType, string targetName, string targetId, array<SortableMap>@ maps, bool reverse) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null) {
		return;
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Processing map list...\n");
	
	string header = "";

	if (!reverse) {
		header = "\n" + FRESH_MAP_LIMIT + " maps " + targetName + " played most recently\n\n";
	} else {
		header = "\n" + FRESH_MAP_LIMIT + " maps " + targetName + (targetType == TARGET_SELF ? " haven't" : " hasn't") + " played in a long time\n\n";
	}
	
	dictionary callbackArgs = {
		{'plr', h_plr},
		{'header', header},
		{'maps', maps},
		{'reverse', reverse}
	};
	
	if (targetType == TARGET_ALL) {
		sortMapsByFreshness(maps, getAllPlayers(), 0, showFreshMaps_afterSort, callbackArgs);
	}
	else {
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[targetId]);
		if (history is null) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, (targetType == TARGET_SELF ? "You have" : targetName + " has") + " no map history yet\n");
			return;
		}
		
		for (uint k = 0; k < maps.size(); k++) {
			MapStat@ stat = history.stats.get(maps[k].map, maps[k].hashKey);
			maps[k].sort = stat.last_played;
		}
		
		insertion_sort_step(maps, 1, showFreshMaps_afterSort, callbackArgs);
	}
}

void showFreshMaps_afterSort(dictionary args) {
	CBasePlayer@ plr = cast<CBasePlayer@>(EHandle(args['plr']).GetEntity());
	if (plr is null) {
		return;
	}
	
	array<SortableMap>@ maps = cast<array<SortableMap>@>(args['maps']);
	bool reverse = bool(args['reverse']);
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, string(args['header']));
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Map name                        Last played\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "----------------------------------------------------------\n");
	
	int listedMaps = 0;
	int numExclude = 0;
	for (uint m = 0; listedMaps < FRESH_MAP_LIMIT && m < maps.size(); m++) {		
		uint idx = reverse ? m : maps.size() - (m+1);
		string map = maps[idx].map;
		
		if (g_memeMapsHashed.exists(map)) {
			numExclude += 1;
			continue;
		}
		
		listedMaps++;
		
		int padding = 32;
		padding -= map.Length();
		string spad = "";
		for (int p = 0; p < padding; p++) spad += " ";
		
		int diff = int(DateTime().ToUnixTimestamp() - maps[idx].sort);
		string age = maps[idx].sort == 0 ? "never" : formatLastPlayedTime(diff) + " ago";
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, map + spad + age + "\n");
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "----------------------------------------------------------\n\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Hidden maps (maps with long cooldowns) are not included in this list.\n\n");
}

void showLastPlayedTimes(CBasePlayer@ plr, string mapname) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\nPrevious play times for \"" + mapname + "\"\n\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Player                          Last played      Total Plays    Previous activity\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "---------------------------------------------------------------------------------\n");
	
	array<LastPlay> allPlayers;
	
	for ( uint c = 0; c < g_nextmap_players.size(); c++ ) {
		allPlayers.insertLast(LastPlay(g_nextmap_players[c].steamid, g_nextmap_players[c].name, true));
	}
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		string steamid = getPlayerUniqueId(p);
		
		bool alreadyInList = false;
		for (uint k = 0; k < allPlayers.size(); k++) {
			if (allPlayers[k].steamid == steamid) {
				alreadyInList = true;
				break;
			}
		}
		
		if (!alreadyInList) {
			allPlayers.insertLast(LastPlay(getPlayerUniqueId(p), p.pev.netname,  false));
		}
	}
	
	uint64 hashKey = hash_FNV1a(mapname);
	
	for ( uint c = 0; c < allPlayers.size(); c++ ) {
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[allPlayers[c].steamid]);
		if (history is null) {
			allPlayers[c].last_played = 0;
		}	
		
		MapStat@ stat = history.stats.get(mapname, hashKey);
		allPlayers[c].last_played = stat.last_played;
		allPlayers[c].total_plays = stat.total_plays;
	}
	
	allPlayers.sort(function(a,b) { return a.last_played < b.last_played; });
	
	for ( uint c = 0; c < allPlayers.size(); c++ ) {
		string steamid = allPlayers[c].steamid;
		string name = allPlayers[c].name;
		
		string prefix = allPlayers[c].wasConsidered ? "[x] " : "[ ] ";
		
		int prc = allPlayers[c].previousPlayPercent;
		string prevPlay = "" + prc + "%%";
		if (prc < 100) prevPlay = " " + prevPlay;
		if (prc < 10) prevPlay = " " + prevPlay;
		prevPlay = prefix + prevPlay;
		
		{
			int padding = 32;
			padding -= name.Length();
			string spad = "";
			for (int p = 0; p < padding; p++) spad += " ";
			name += spad;
		}
		
		int64 diff = int64(DateTime().ToUnixTimestamp() - allPlayers[c].last_played);
		string age = allPlayers[c].last_played == 0 ? "never" : formatLastPlayedTime(diff) + " ago";
		
		{
			int padding = 17;
			padding -= age.Length();
			string spad = "";
			for (int p = 0; p < padding; p++) spad += " ";
			age += spad;
		}
		
		string totalPlays = "" + allPlayers[c].total_plays;
		{
			int padding = 15;
			padding -= totalPlays.Length();
			string spad = "";
			for (int p = 0; p < padding; p++) spad += " ";
			totalPlays += spad;
		}
		
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, name + age + totalPlays + prevPlay + "\n");
	}	
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "---------------------------------------------------------------------------------\n\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Previous play times are used to pick \"Next maps\" that have the highest minimum age.\n\n");
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\"Previous activity\" shows the percentage of activity in the previous map (" + g_previous_stats_map + ").\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Players with an [x] were considered when deciding the current \"Next Map\".\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "" + int(MIN_ACTIVE_TIME*100) + "%% is the minimum to be considered for map selection.\n\n");
}

// players who have been at least 50% active up until the current time
array<SteamName> getActivePlayers(bool connectedOnly=false) {
	array<SteamName> activePlayers;
	
	array<string>@ idKeys = g_player_activity.getKeys();	
	for (uint i = 0; i < idKeys.length(); i++) {
		string steamid = idKeys[i];
		PlayerActivity@ activity = cast<PlayerActivity@>(g_player_activity[steamid]);
		
		if (activity is null) {
			continue;
		}
		
		CBasePlayer@ plr = getPlayerById(steamid);
		string name = plr !is null ? string(plr.pev.netname) : "\\disconnected\\";
		
		if (connectedOnly and plr is null) {
			continue;
		}
		
		float levelTime = g_Engine.time - 60; // substract some time for loading/downloading
		float percentActive = activity.totalActivity / levelTime;
		
		if (activity.totalActivity > levelTime || percentActive > 1.0f) {
			percentActive = 1.0f;
		}
		
		bool wasActiveEnough = percentActive >= MIN_ACTIVE_TIME;
		g_prev_map_activity[steamid] = int(percentActive*100);
		
		if (wasActiveEnough) {
			activePlayers.insertLast(SteamName(steamid, name));
		}
	}
	
	return activePlayers;
}

array<SteamName> getAllPlayers() {
	array<SteamName> activePlayers;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		activePlayers.insertLast(SteamName(getPlayerUniqueId(plr), plr.pev.netname));
	}
	
	return activePlayers;
}

// logic here should be kept in sync with db_setup.py
void updatePlayerStats() {
	g_nextmap_players.resize(0);
	g_nextmap_players = getActivePlayers();

	for (uint i = 0; i < g_nextmap_players.size(); i++) {
		string steamid = g_nextmap_players[i].steamid;
			
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
		
		if (!history.loaded) { 
			println("Can't update stats for " + steamid + " yet. Still loading.");
			continue;
		}
		
		MapStat@ mapStat = history.stats.get(g_Engine.mapname);
		mapStat.total_plays += 1;
		mapStat.last_played = DateTime().ToUnixTimestamp();
	}
}

void writeActivePlayerStats() {
	if (!g_anyone_joined) {
		// map was probably double-loaded. Re-use the previous map choice.
		return;
	}
	
	print("Updating player map stats...");

	g_prev_map_activity.clear();

	g_previous_stats_map = g_Engine.mapname;
	updatePlayerStats();

	array<string>@ idKeys = g_player_activity.getKeys();	
	for (uint m = 0; m < idKeys.length(); m++) {
		string steamid = idKeys[m];
		
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
			
		if (history is null or !history.loaded) { 
			println("Can't write stats for " + steamid + " yet. Still loading.");
			continue;
		}
		
		string path = getPlayerDbPath(steamid);
		File@ f = g_FileSystem.OpenFile(path, OpenFile::WRITE);

		if (f is null or !f.IsOpen()) {
			println("Failed to open player map stats file: " + path + "\n");
			return;
		}
		
		array<array<HashMapEntryMapStat>>@ buckets = @history.stats.buckets;
		for (uint i = 0; i < buckets.size(); i++) {
			for (uint k = 0; k < buckets[i].size(); k++) {			
				MapStat@ stat = buckets[i][k].value;
			
				f.Write(buckets[i][k].key + " " + stat.last_played + " " + stat.total_plays + " " + stat.rating + "\n");
			}
		}
		
		f.Close();
		//println("Wrote player stat file: " + path);
	}
	
	println("DONE");
}

string formatLastPlayedTime(int seconds) {
	int daysPerMonth = 30; // accurate enough for a "time since played" message

	int minutes = (seconds / 60) % 60;
	int hours = (seconds / (60*60)) % 24;
	int days = (seconds / (60*60*24)) % daysPerMonth;
	int months = (seconds / (60*60*24*daysPerMonth));
	int years = (seconds / (60*60*24*365));
	
	if (years > 1) {
		if (months >= 6) {
			years += 1;
		}
		return "" + years + " year" + (years != 1 ? "s" : "");
	} else if (months > 3) {
		if (days >= daysPerMonth/2) {
			months += 1;
		}
		return "" + months + " month" + (months != 1 ? "s" : "");
	} else if (days > 0) {
		if (hours >= 12) {
			days += 1;
		}
		days += months*daysPerMonth;
		return "" + days + " day" + (days != 1 ? "s" : "");
	} else if (hours > 0) {
		if (minutes >= 30) {
			hours += 1;
		}
		return "" + hours + " hour" + (hours != 1 ? "s" : "");
	} else {
		return "" + minutes + " minute" + (minutes != 1 ? "s" : "");
	}
}

CBasePlayer@ getPlayerById(string targetId) {
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		string steamid = getPlayerUniqueId(plr);
		
		if (steamid == targetId) {
			return @plr;
		}
	}
	
	return null;
}