// using the filesystem as a database. Shouldn't be a problem until sven has millions of players (never)
// DB size for TWLZ is about 30 MB (50k unique players, mostly short visitors)
const string ROOT_DB_PATH = "scripts/plugins/store/rtv/";

// Use bucket folders to keep filesystem lookups fast.
// For 50k unique players, 256 buckets would have 195 files each, on average
// Make sure to keep this in sync with the db_setup.py script
const uint MAX_DB_BUCKETS = 256;

dictionary g_player_map_history; // maps steam id to PlayerMapHistory
dictionary g_active_players; // maps steam id to time they joined the map. used to track play time for the previous map
dictionary g_steam_id_names;

// temp vars for loading all stats
array<string> g_all_ids;
bool g_stats_ready = false;
uint g_load_idx = 0;

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
	float firstActivity;
	float lastActivity;
	
	PlayerActivity() {
		firstActivity = 0;
		lastActivity = g_Engine.time;
	}
}

void initStats() {
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		string steamid = getPlayerUniqueId(plr);
		
		loadPlayerMapStats(steamid);
		g_active_players[steamid] = PlayerActivity();
	}
}

string getPlayerDbPath(string steamid) {
	string safeid = steamid.Replace(":", "_");
	uint64 hash = hash_FNV1a(safeid) % MAX_DB_BUCKETS;
	
	return ROOT_DB_PATH + hash + "/" + safeid + ".txt";
}

void loadPlayerMapStats(string steamid) {
	PlayerMapHistory@ history = null;
	
	if (g_player_map_history.exists(steamid)) {
		@history = cast<PlayerMapHistory@>( g_player_map_history[steamid] );
		
		if (history !is null && history.loaded) {
			//println("Skipping map history for player - already loaded");
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
	} else {
		g_Scheduler.SetTimeout("loadPlayerMapStats", 0.0f, steamid);
	}
}

void getMostPlayedMap(CBasePlayer@ plr) {
	string steamid = getPlayerUniqueId(plr);
	
	PlayerMapHistory@ history = cast<PlayerMapHistory@>( g_player_map_history[steamid] );
	if (history is null || !history.loaded) {
		return;
	}
	
	string bestMap;
	uint bestTotal = 0;
	
	array<array<HashMapEntryMapStat>>@ buckets = @history.stats.buckets;
	for (uint i = 0; i < buckets.size(); i++) {
		for (uint k = 0; k < buckets[i].size(); k++) {			
			MapStat@ stat = buckets[i][k].value;
		
			if (stat.total_plays > bestTotal) {
				bestTotal = stat.total_plays;
				bestMap = buckets[i][k].key;
			}
		}
	}
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTCONSOLE, "Most played map: " + bestMap + " (" + bestTotal + " plays)\n");
}

// Maps that no one has played in a while are at the top. Overplayed maps at the bottom. Sorted by:
// 1) time since it was last played by the players currently in the server
// 2) total number of plays by each player in the server
void sortMapsByFreshness(array<SortableMap>@ maps) {
	
	array<CBasePlayer@> players;
	
	println("Determining the best next map...");
	
	for (uint k = 0; k < maps.size(); k++) {
		maps[k].sort = 0;
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (g_playerStates[i].afkTime != 0) { // don't cater to afk players
			println("Skipping AFK player " + plr.pev.netname);
			continue;
		}
		
		string steamid = getPlayerUniqueId(plr);
		
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
		if (history is null) {
			println("" + plr.pev.netname + " has no map history yet");
			continue;
		}
		
		for (uint k = 0; k < maps.size(); k++) {
			MapStat@ stat = history.stats.get(maps[k].map);
			
			if (stat is null) {
				continue;
			}
			
			int diff = int(TimeDifference(DateTime(), DateTime(stat.last_played)).GetTimeDifference());
			maps[k].sort += diff;
			
			if (stat.last_played == 0) {
				println("" + plr.pev.netname + " has never played " + maps[k].map);
			} else {
				println("" + plr.pev.netname + " last played " + maps[k].map + " " + formatLastPlayedTime(diff) + " ago");
			}
		}
	}
	
	maps.sort(function(a,b) { return a.sort > b.sort; });
}

// logic here should be kept in sync with db_setup.py
void updatePlayerStats() {
	array<string>@ idKeys = g_active_players.getKeys();	
	for (uint i = 0; i < idKeys.length(); i++) {
		string steamid = idKeys[i];
		PlayerActivity@ activity = cast<PlayerActivity@>(g_active_players[steamid]);
		CBasePlayer@ plr = getPlayerById(steamid);
		
		bool isActiveNow = plr !is null;
		
		if (isActiveNow) {
			activity.lastActivity = g_Engine.time;
		}
		
		float levelTime = g_Engine.time - 60; // substract some time for loading/downloading
		float activeTime = activity.lastActivity - activity.firstActivity;
		float percentActive = activeTime / levelTime;
		bool wasActiveEnough = percentActive >= 0.5f || activeTime > levelTime;
		
		println("" + plr.pev.netname + " activity percent: " + percentActive*100 + " (" + activity.firstActivity + " to " + activity.lastActivity + ")");
		
		if (wasActiveEnough) {
			PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
			
			if (!history.loaded) { 
				println("Can't update stats for " + steamid + " yet. Still loading.");
				continue;
			}
			
			MapStat@ mapStat = history.stats.get(g_Engine.mapname);
			mapStat.total_plays += 1;
			mapStat.last_played = DateTime().ToUnixTimestamp();
		}
		
		g_steam_id_names[steamid] = "" + plr.pev.netname;
	}
}

void writeMapStats() {
	if (g_steam_id_names.size() == 0) {
		println("Can't write stats yet. Loading not finished");
		return;
	}
	
	updatePlayerStats();
	writeActivePlayerStats();
	
	string path = ROOT_DB_PATH + "/steam_ids_test.txt";
	File@ f = g_FileSystem.OpenFile( path, OpenFile::WRITE);

	if (!f.IsOpen()) {
		println("Failed to steam id name file: " + path + "\n");
		return;
	}
	
	array<string>@ idKeys = g_steam_id_names.getKeys();	
	for (uint i = 0; i < idKeys.length(); i++)
	{
		string name;
		g_steam_id_names.get(idKeys[i], name);
		f.Write(idKeys[i].Replace("STEAM_0:", "") + "\\" + name + "\n");
	}
	
	f.Close();

	println("Wrote steam id name mapping");
}	

void writeActivePlayerStats() {
	array<string>@ idKeys = g_active_players.getKeys();	
	for (uint m = 0; m < idKeys.length(); m++) {
		string steamid = idKeys[m];
		
		PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
			
		if (!history.loaded) { 
			println("Can't write stats for " + steamid + " yet. Still loading.");
			continue;
		}
		
		string path = getPlayerDbPath(steamid) + ".new";
		File@ f = g_FileSystem.OpenFile(path, OpenFile::WRITE);

		if (!f.IsOpen()) {
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
		println("Wrote player stat file: " + path);
	}
}

string formatLastPlayedTime(int seconds) {
	int daysPerMonth = 30; // accurate enough for a "time since played" message

	int minutes = (seconds / 60) % 60;
	int hours = (seconds / (60*60)) % 24;
	int days = (seconds / (60*60*24)) % daysPerMonth;
	int months = (seconds / (60*60*24*daysPerMonth));
	int years = (seconds / (60*60*24*365));
	
	if (years > 0) {
		if (months >= 6) {
			years += 1;
		}
		return "" + years + " years";
	} else if (months > 0) {
		if (days >= daysPerMonth/2) {
			months += 1;
		}
		return "" + months + " months";
	} else if (days > 0) {
		if (hours >= 12) {
			days += 1;
		}
		return "" + days + " days";
	} else if (hours > 0) {
		if (minutes >= 30) {
			hours += 1;
		}
		return "" + hours + " hours";
	} else {
		return "" + minutes + " minutes";
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