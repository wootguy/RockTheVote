#include "MenuVote"
#include "GameVotes"
#include "Stats"
#include "HashMap"

// TODO:
// - play 50% of a series for it to count as a play, not just a sinle map
// - configurable min active time and min series map plays
// - reopen menu should close again or not show messsage

class RtvState {
	bool didRtv = false;	// player wants to rock the vote?
	string nom; 			// what map this player nominated
	int afkTime = 0;		// AFK players ignored for rtv requirement
}

class SortableMap {
	string map;
	uint64 hashKey; // pre-hashed key for faster lookups
	uint64 sort; // value used for sorting
	
	SortableMap() {}
	
	SortableMap(SortableMap@ other) {
		map = other.map;
		hashKey = other.hashKey;
		sort = other.sort;
	}
	
	SortableMap(string map) {
		this.map = map;
		hashKey = hash_FNV1a(map);
	}
}

CClientCommand forcertv("forcertv", "Lets admin force a vote", @consoleCmd);
CClientCommand cancelrtv("cancelrtv", "Lets admin cancel an ongoing RTV vote", @consoleCmd);
CClientCommand set_nextmap("set_nextmap", "Set the next map cycle", @consoleCmd);
CClientCommand map("map", "Force a map change", @consoleCmd);
CClientCommand vote("vote", "Start a vote or reopen the vote menu", @consoleCmd);
CClientCommand poll("poll", "Start a custom poll", @consoleCmd);
CClientCommand mapstats("mapstats", "Show previous play times for a map", @consoleCmd);
CClientCommand recentmaps("recentmaps", "Show recently played maps", @consoleCmd);
CClientCommand newmaps("newmaps", "Show maps that haven't been played for the longest time", @consoleCmd);
CClientCommand mapinfo("mapinfo", "Show maps that haven't been played for the longest time", @consoleCmd);

CCVar@ g_SecondsUntilVote;
CCVar@ g_MaxMapsToVote;
CCVar@ g_VotingPeriodTime;
CCVar@ g_PercentageRequired;
CCVar@ g_NormalMapCooldown;
CCVar@ g_MemeMapCooldown;
CCVar@ g_EnableGameVotes;			// enable text menu replacements for the default game votes
CCVar@ g_EnableForceSurvivalVotes;	// enable semi-survival vote (requires ForceSurvival plugin)
CCVar@ g_EnableRestartVotes;
CCVar@ g_EnableDiffVotes;
CCVar@ g_EnableAfkKickVotes;

// maps that can be nominated with a normal cooldown
const string votelistFile = "scripts/plugins/cfg/mapvote.txt"; 
array<string> g_normalMaps;

// maps that have a large nom cooldown and never randomly show up in the vote menu
const string hiddenMapsFile = "scripts/plugins/cfg/hidden_nom_maps.txt";
array<string> g_hiddenMaps;

// maps that are split into multiple bsp files
const string seriesMapsFile = "scripts/plugins/RockTheVote/series_maps.txt";
dictionary g_seriesMaps; // maps a votable map to a list of maps
string g_previous_map = "";
array<SortableMap>@ g_current_series_maps = null;
array<SortableMap>@ g_previous_series_maps = null;

array<RtvState> g_playerStates;
array<SortableMap> g_everyMap; // sorted combination of normal and hidden maps
array<SortableMap> g_randomRtvChoices; // normal votable maps (all maps besides the meme ones)
array<SortableMap> g_randomCycleMaps; // map cycle maps (only the "good" maps)
array<string> g_nomList; // maps nominated by players
dictionary g_memeMapsHashed; // for faster meme map checks
dictionary g_everyMapHashed; // for faster votable map checks
MenuVote::MenuVote g_rtvVote;
uint g_maxNomMapNameLength = 0; // used for even spacing in the full console map list
CScheduledFunction@ g_timer = null;
bool g_generating_rtv_list = false; // true while maps are being sorted for rtv menu
bool g_autostart_allowed = true;

const float levelChangeDelay = 5.0f; // time in seconds intermission is shown for game_end

dictionary g_lastLaggyCommands;
float g_lastQuestion = 0;
const int LAGGY_COMAND_COOLDOWN = 3; // not laggy when run a few at a time, but the server would freeze if spammed
const int QUESTION_COOLDOWN = 60;

void PluginInit() {

	g_Module.ScriptInfo.SetAuthor("w00tguy");
	g_Module.ScriptInfo.SetContactInfo("https://github.com/wootguy");
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientLeave);
	g_Hooks.RegisterHook(Hooks::Player::ClientSay, @ClientSay);
	g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);

	@g_SecondsUntilVote = CCVar("secondsUntilVote", 0, "Delay before players can RTV after map has started", ConCommandFlag::AdminOnly);
	@g_MaxMapsToVote = CCVar("iMaxMaps", 6, "How many maps can players nominate and vote for later", ConCommandFlag::AdminOnly);
	@g_VotingPeriodTime = CCVar("secondsToVote", 25, "How long can players vote for a map before a map is chosen", ConCommandFlag::AdminOnly);
	@g_PercentageRequired = CCVar("iPercentReq", 66, "0-100, percent of players required to RTV before voting happens", ConCommandFlag::AdminOnly);
	@g_NormalMapCooldown = CCVar("NormalMapCooldown", 12, "Time in hours before a map can be nommed again", ConCommandFlag::AdminOnly);
	@g_MemeMapCooldown = CCVar("MemeMapCooldown", 24*5, "Time in hours before a meme map can be nommed again", ConCommandFlag::AdminOnly);
	@g_EnableGameVotes = CCVar("gameVotes", 1, "Text menu replacements for the default game votes", ConCommandFlag::AdminOnly);
	@g_EnableForceSurvivalVotes = CCVar("forceSurvivalVotes", 0, "Enable semi-survival vote (requires ForceSurvival plugin)", ConCommandFlag::AdminOnly);
	@g_EnableRestartVotes = CCVar("restartVotes", 0, "Enable map restart votes", ConCommandFlag::AdminOnly);
	@g_EnableDiffVotes = CCVar("diffVotes", 0, "Enable dynamic difficulty votes", ConCommandFlag::AdminOnly);
	@g_EnableAfkKickVotes = CCVar("afkKickVotes", 1, "Enable AFK kick votes", ConCommandFlag::AdminOnly);

	reset();
	
	initStats();
	
	g_Scheduler.SetInterval("autoStartRtvCheck", 1.0f, -1);
	g_Scheduler.SetInterval("reduceKillPenalties", 60*60, -1);
}

void MapInit() {
	g_SoundSystem.PrecacheSound("fvox/one.wav");
	g_SoundSystem.PrecacheSound("fvox/two.wav");
	g_SoundSystem.PrecacheSound("fvox/three.wav");
	g_SoundSystem.PrecacheSound("fvox/four.wav");
	g_SoundSystem.PrecacheSound("fvox/five.wav");
	g_SoundSystem.PrecacheSound("gman/gman_choose1.wav");
	g_SoundSystem.PrecacheSound("gman/gman_choose2.wav");
	g_SoundSystem.PrecacheSound("buttons/blip3.wav");
	
	reset();
	
	@g_previous_series_maps = @g_current_series_maps;
	@g_current_series_maps = getMapSeriesMaps(g_Engine.mapname);
	string next_series_map = getNextSeriesMap(g_current_series_maps);
	
	SemiSurvivalMapInit();

	if (next_series_map.Length() > 0 and g_EngineFuncs.IsMapValid(next_series_map)) {
		g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + next_series_map + "\n");
	} else {
		setFreshMapAsNextMap(g_randomCycleMaps); // something most haven't played in the longest time
	}
}

void MapStart() {
	DiffMapStart();
}

HookReturnCode MapChange() {
	writeActivePlayerStats();
	g_player_activity.clear();
	g_Scheduler.RemoveTimer(g_timer);
	g_previous_map = g_Engine.mapname;
	return HOOK_CONTINUE;
}

void reset() {
	g_playerStates.resize(0);
	g_playerStates.resize(33);
	g_nomList.resize(0);
	g_Scheduler.RemoveTimer(g_timer);
	loadAllMapLists();
	g_rtvVote.reset();
	g_gameVote.reset();
	g_lastLaggyCommands.clear();
	g_lastGameVote = 0;
	g_anyone_joined = false;
	g_generating_rtv_list = false;
	g_autostart_allowed = true;
	g_lastQuestion = -999;
}

void loadCrossPluginAfkState() {
	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		return;
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CustomKeyvalue key = customKeys.GetKeyvalue("$i_afk" + i);
		if (key.Exists()) {
			g_playerStates[i].afkTime = key.GetInteger();
		}
		
		// don't count loading/disconnected players either
		CustomKeyvalue key2 = customKeys.GetKeyvalue("$i_state" + i);
		if (key2.Exists() && key2.GetInteger() > 0 && g_playerStates[i].afkTime == 0) {
			g_playerStates[i].afkTime = 999;
		}
	}
}

void autoStartRtvCheck() {
	loadCrossPluginAfkState();

	if (canAutoStartRtv()) {
		startVote("(vote requirement lowered due to leaving/AFK players)");
	}
}



void print(string text) { g_Game.AlertMessage( at_console, text); }

void println(string text) { print(text + "\n"); }

void delay_print(EHandle h_plr, string message) {
	CBasePlayer @ plr = cast < CBasePlayer @ > (h_plr.GetEntity());
	if (plr !is null) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, message);
	}
}

void delay_print(EHandle h_plr, array<string> messages) {
	CBasePlayer @ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr !is null) {
		for (uint i = 0; i < messages.size(); i++) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, messages[i]);
		}
	}
}

void playSoundGlobal(string file, float volume, int pitch) {
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		g_SoundSystem.PlaySound(plr.edict(), CHAN_VOICE, file, volume, ATTN_NONE, 0, pitch, plr.entindex());
	}
}

void game_end(string nextMap) {
	// using a game_end instead of changelevel command so that game_end detection works here and in other plugins
	g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextMap + "\n");
	CBaseEntity@ endEnt = g_EntityFuncs.CreateEntity("game_end");
	endEnt.Use(null, null, USE_TOGGLE);
	g_Log.PrintF("[RTV] level change to " + nextMap + "\n");
}



int getCurrentRtvCount(bool excludeAfks=true) {
	int count = 0;

	for (uint i = 0; i < g_playerStates.size(); i++) {
		count += g_playerStates[i].didRtv and (g_playerStates[i].afkTime == 0 || !excludeAfks) ? 1 : 0;
	}
	
	return count;
}

int getRequiredRtvCount(bool excludeAfks=true) {
	uint playerCount = 0;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		if (g_playerStates[i].afkTime >= 60 && excludeAfks) {
			continue; // PlayerStatus plugin says this player is afk
		}
		
		playerCount++;
	}
	
	float percent = g_PercentageRequired.GetInt() / 100.0f;
	return int(Math.Ceil(percent * float(playerCount)));
}

bool canAutoStartRtv() {
	if (g_rtvVote.status == MVOTE_NOT_STARTED && g_Engine.time > g_SecondsUntilVote.GetInt()) {
		if (getCurrentRtvCount() >= getRequiredRtvCount() and getCurrentRtvCount() > 0) {
			return !g_generating_rtv_list and g_autostart_allowed;
		}
	}
	
	return false;
}

void createRtvMenu(dictionary args) {
	array<string> rtvList;
	if (!g_generating_rtv_list) {
		return; // game_end interrupted sort
	}
	g_generating_rtv_list = false;
	
	for (uint i = 0; i < g_nomList.size(); i++) {
		rtvList.insertLast(g_nomList[i]);
	}
	
	uint maxMenuItems = Math.min(g_MaxMapsToVote.GetInt(), 8);
	
	if (rtvList.size() < maxMenuItems and g_nomList.find(g_MapCycle.GetNextMap()) == -1) {
		rtvList.insertLast(g_MapCycle.GetNextMap());
	}
	
	array<string> shuffleChoices;
	uint firstPlayedMapIdx = 0;
	int mapsNeeded = maxMenuItems - rtvList.size();
	
	// prevent the same maps always being shown for players who have little history
	for (uint i = 0; i < g_randomRtvChoices.size(); i++) {
		if (g_randomRtvChoices[i].sort != 0 and int(shuffleChoices.size()) > mapsNeeded) {
			break;
		}
		
		shuffleChoices.insertLast(g_randomRtvChoices[i].map);
	}
	println("Shuffling " + shuffleChoices.size() + " maps");
	
	for (uint failsafe = 0; failsafe < g_randomRtvChoices.size(); failsafe++) {	
		if (rtvList.size() >= maxMenuItems or shuffleChoices.size() == 0) {
			break;
		}
		
		int idx = Math.RandomLong(0, shuffleChoices.size()-1);
		string randomMap = shuffleChoices[idx];
		shuffleChoices.removeAt(idx);
		
		if (rtvList.find(randomMap) == -1 && g_EngineFuncs.IsMapValid(randomMap)) {
			rtvList.insertLast(randomMap);
		}
	}
	
	array<MenuOption> menuOptions;
	
	menuOptions.insertLast(MenuOption("\\d(exit)"));
	menuOptions[0].isVotable = false;
	
	for (uint i = 0; i < rtvList.size(); i++) {
		menuOptions.insertLast(MenuOption(rtvList[i]));
	}

	MenuVoteParams voteParams;
	voteParams.title = "RTV Vote";
	voteParams.options = menuOptions;
	voteParams.voteTime = g_VotingPeriodTime.GetInt();
	@voteParams.optionCallback = @mapChosenCallback;
	@voteParams.thinkCallback = @voteThinkCallback;
	@voteParams.finishCallback = @voteFinishCallback;
	
	g_rtvVote.start(voteParams, null);
}

void disable_level_changes() {
	// TODO: this will break if a once-only trigger is activated during rtv and then rtv is cancelled or fails.
	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "trigger_changelevel");
		if (ent !is null) {
			ent.pev.solid = SOLID_NOT;
		}
	} while (ent !is null);
	
	@ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "game_end");
		if (ent !is null) {
			ent.pev.targetname = "RTV_" + ent.pev.targetname;
		}
	} while (ent !is null);
}

void enable_level_changes() {
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "trigger_changelevel");
		if (ent !is null) {
			ent.pev.solid = SOLID_TRIGGER;
		}
	} while (ent !is null);
	
	@ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "game_end");
		if (ent !is null) {
			if (string(ent.pev.targetname).Find("RTV_") == 0) {
				ent.pev.targetname = string(ent.pev.targetname).SubString(4);
			}
		}
	} while (ent !is null);
}

void startVote(string reason="") {
	
	if (g_gameVote.status == MVOTE_IN_PROGRESS) {
		g_gameVote.cancel();
	} else if (g_gameVote.status == MVOTE_FINISHED) {
		println("Waiting for game vote to end...");
		g_Scheduler.SetTimeout("startVote", 1.0f, reason);
		g_generating_rtv_list = true; // prevent auto-start starting rtv
		return;
	}
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] Vote starting! " + reason + "\n");
	
	if (g_randomRtvChoices.size() == 0) {
		g_Log.PrintF("[RTV] All maps are excluded by the previous map list! Make sure g_ExcludePrevMaps value is less than the total nommable maps.\n");
		createRtvMenu({});
		return;
	}
	
	g_autostart_allowed = false;
	g_generating_rtv_list = true;
	disable_level_changes();
	sortMapsByFreshness(g_randomRtvChoices, getActivePlayers(), 0, createRtvMenu, {});
}

void voteThinkCallback(MenuVote::MenuVote@ voteMenu, int secondsLeft) {
	int voteTime = g_VotingPeriodTime.GetInt();
	
	if (secondsLeft == voteTime)	{ playSoundGlobal("gman/gman_choose1.wav", 1.0f, 100); }
	else if (secondsLeft == 8)		{ playSoundGlobal("gman/gman_choose2.wav", 1.0f, 100); }
	else if (secondsLeft == 5)		{ playSoundGlobal("fvox/five.wav", 0.8f, 85); }
	else if (secondsLeft == 4)		{ playSoundGlobal("fvox/four.wav", 0.8f, 85); }
	else if (secondsLeft == 3)		{ playSoundGlobal("fvox/three.wav", 0.8f, 85); }
	else if (secondsLeft == 2)		{ playSoundGlobal("fvox/two.wav", 0.8f, 85); }
	else if (secondsLeft == 1)		{ playSoundGlobal("fvox/one.wav", 0.8f, 85); }
}

void voteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {
	string nextMap = chosenOption.value;
	
	if (resultReason == MVOTE_RESULT_TIED) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been randomly chosen amongst the tied.\n");
	} else if (resultReason == MVOTE_RESULT_NO_VOTES) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been randomly chosen since nobody picked.\n");
	} else {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been chosen!\n");
	}
	
	playSoundGlobal("buttons/blip3.wav", 1.0f, 70);
	
	g_Log.PrintF("[RTV] chose " + nextMap + "\n");
	
	g_Scheduler.SetTimeout("game_end", MenuVote::g_resultTime, nextMap);
	g_Scheduler.SetTimeout("reset_failsafe", MenuVote::g_resultTime + levelChangeDelay + 0.1f);
}

void reset_failsafe() {
	g_rtvVote.reset();
	g_gameVote.reset();
	g_lastGameVote = 0;
	g_playerStates.resize(0);
	g_playerStates.resize(33);
	g_nomList.resize(0);
	g_generating_rtv_list = false;
	g_autostart_allowed = true;
}

void mapChosenCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, CBasePlayer@ plr) {
	if (chosenOption !is null) {
		if (chosenOption.label == "\\d(exit)") {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Say \"rtv\" to reopen the menu\n");
			voteMenu.closeMenu(plr);
		}
	}
}


// return 1 = show chat, 2 = hide chat
int tryRtv(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	if (g_rtvVote.status == MVOTE_FINISHED) {
		return 1;
	}
	
	if (g_generating_rtv_list) {
		return 2;
	}
	
	if (g_rtvVote.status == MVOTE_IN_PROGRESS) {
		g_rtvVote.reopen(plr);
		return 2;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayText(plr, "[RTV] RTV will enable in " + timeLeft + " seconds.\n");
		return 2;
	}
	
	if (g_playerStates[eidx].didRtv) {
		g_PlayerFuncs.SayText(plr, "[RTV] " + getCurrentRtvCount() + " of " + getRequiredRtvCount() + " players until vote starts! You already rtv'd.\n");
		return 2;
	}
	
	g_playerStates[eidx].didRtv = true;	
	
	if (getCurrentRtvCount() >= getRequiredRtvCount()) {
		sayRtvCount(plr);
		startVote();
	} else {
		sayRtvCount(plr);
	}
	
	return 2;
}

int unRtv(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	if (g_rtvVote.status == MVOTE_FINISHED) {
		return 1;
	}
	
	if (g_generating_rtv_list) {
		return 2;
	}
	
	if (g_rtvVote.status == MVOTE_IN_PROGRESS) {
		g_rtvVote.reopen(plr);
		return 2;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayText(plr, "[RTV] RTV will enable in " + timeLeft + " seconds.\n");
		return 2;
	}
	
	if (!g_playerStates[eidx].didRtv) {
		g_PlayerFuncs.SayText(plr, "[RTV] " + getCurrentRtvCount() + " of " + getRequiredRtvCount() + " players until vote starts! You haven't rtv'd yet.\n");
		return 2;
	}
	
	g_playerStates[eidx].didRtv = false;
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] " + plr.pev.netname + " took their \"rtv\" back.\n");
	
	return 2;
}

void sayRtvCount(CBasePlayer@ plr=null) {
	string msg = "[RTV] " + getCurrentRtvCount() + " of " + getRequiredRtvCount() + " players until vote starts!";
	
	if (plr !is null) {
		msg += "  -" + plr.pev.netname;
		if (g_playerStates[plr.entindex()].afkTime > 0) {
			msg += " (AFK)";
		}
	}
		
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, msg + "\n");
}

void cancelRtv(CBasePlayer@ plr) {
	if (g_rtvVote.status != MVOTE_IN_PROGRESS) {
		g_PlayerFuncs.SayText(plr, "[RTV] There is no vote to cancel.\n");
		return;
	}
	
	for (uint i = 0; i < g_playerStates.size(); i++) {
		g_playerStates[i].didRtv = false;
	}
	
	g_rtvVote.cancel();
	enable_level_changes();
	
	g_PlayerFuncs.SayTextAll(plr, "[RTV] Vote cancelled by " + plr.pev.netname + "!\n");
}

// returns true if someone in the server played the map too recently for it to be nominated again
bool isMapExcluded(string mapname, array<SteamName> activePlayers, CBasePlayer@ plr) {
	bool isMemeMap = g_memeMapsHashed.exists(mapname);
	int cooldown = (isMemeMap ? g_MemeMapCooldown.GetInt() : g_NormalMapCooldown.GetInt()) * 60*60;
	int recentCount = 0;
	string recentName;
	
	string steamid = getPlayerUniqueId(plr);

	for (uint i = 0; i < activePlayers.size(); i++) {
		if (steamid == activePlayers[i].steamid) {
			continue;
		}
		
		uint64 lastPlay = getLastPlayTime(activePlayers[i].steamid, mapname);
		int diff = int(DateTime().ToUnixTimestamp() - lastPlay);
		
		if (diff < cooldown) {
			recentCount += 1;
			recentName = activePlayers[i].name;
		}
	}
	
	if (recentCount > 0) {
		string splr = recentCount == 1 ?  recentName : "" + recentCount + " people here";
		string smap = g_seriesMaps.exists(mapname) ? "that map series" : "that map";
		g_PlayerFuncs.SayText(plr, "[RTV] Can't nom \"" + mapname + "\" yet. " + splr + " played " + smap + " less than " + formatLastPlayedTime(cooldown) + " ago.\n");
	}
	
	return recentCount > 0;
}

void nomMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected() or g_rtvVote.status != MVOTE_NOT_STARTED) {
		return;
	}

	string nomChoice;
	item.m_pUserData.retrieve(nomChoice);
	
	array<string> parts = nomChoice.Split(":");
	string mapname = parts[0];
	string mapfilter = parts[1];
	int itempage = atoi(parts[2]);
	
	if (!tryNominate(plr, mapname, false)) {
		array<string> similarNames = generateNomMenu(mapfilter);
		g_Scheduler.SetTimeout("openNomMenu", 0.0f, EHandle(plr), mapfilter, similarNames, itempage);
	}
}

void openNomMenu(EHandle h_plr, string mapfilter, array<string> maps, int page) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null) {
		return;
	}
	
	int eidx = plr.entindex();
	
	@g_menus[eidx] = CTextMenu(@nomMenuCallback);
	
	string title = "\\yMaps containing \"" + mapfilter + "\"	 ";
	if (mapfilter.Length() == 0) {
		title = "\\yNominate...	  ";
	}
	g_menus[eidx].SetTitle(title);
	
	array<SteamName> activePlayers = getActivePlayers();
	
	for (uint i = 0; i < maps.size(); i++) {
		int itempage = i / 7;
		string label = maps[i] + "\\y";
		label = "\\w" + label;
		g_menus[eidx].AddItem(label, any(maps[i] + ":" + mapfilter + ":" + itempage));
	}
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, page, plr);
}

array<string> generateNomMenu(string mapname) {
	bool fullNomMenu = mapname.Length() == 0;
	array<string> similarNames;
	
	if (fullNomMenu) {
		for (uint i = 0; i < g_everyMap.size(); i++) {
			similarNames.insertLast(g_everyMap[i].map);
		}
	}
	else {
		for (uint i = 0; i < g_everyMap.size(); i++) {
			if (int(g_everyMap[i].map.Find(mapname)) != -1) {
				similarNames.insertLast(g_everyMap[i].map);
			}
		}
	}
	
	return similarNames;
}

bool tryNominate(CBasePlayer@ plr, string mapname, bool isRandom) {
	if (g_rtvVote.status != MVOTE_NOT_STARTED) {
		return false;
	}

	int eidx = plr.entindex();
	bool dontAutoNom = int(mapname.Find("*")) != -1; // player just wants to search for maps with this string
	mapname.Replace("*", "");
	mapname.Replace(":", ""); // used as delimiter in nom menu option data
	bool fullNomMenu = mapname.Length() == 0;
	
	bool mapExists = false;
	for (uint i = 0; i < g_everyMap.size(); i++) {
		if (g_everyMap[i].map == mapname) {
			mapExists = true;
		}
	}

	if (fullNomMenu || dontAutoNom || !mapExists) {
		array<string> similarNames = generateNomMenu(mapname);
		
		if (similarNames.size() == 0) {
			g_PlayerFuncs.SayText(plr, "[RTV] No maps containing \"" + mapname + "\" exist.");
		}
		else if (similarNames.size() > 1 || dontAutoNom) {
			openNomMenu(plr, mapname, similarNames, 0);
		}
		else if (similarNames.size() == 1) {
			return tryNominate(plr, similarNames[0], isRandom);
		}
		
		return false;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayText(plr, "[RTV] Nominations will enable in " + timeLeft + " seconds.\n");
		return false;
	}
	
	if (mapname == g_Engine.mapname) {
		g_PlayerFuncs.SayText(plr, "[RTV] Can't nominate the current map!\n");
		return false;
	}
	
	if (g_nomList.find(mapname) != -1) {
		g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" has already been nominated.\n");
		return false;
	}
	
	if (int(g_nomList.size()) >= g_MaxMapsToVote.GetInt() && g_playerStates[eidx].nom == "") {
		g_PlayerFuncs.SayText(plr, "[RTV] The max number of nominations has been reached!\n");
		return false;
	}
	
	if (!g_EngineFuncs.IsMapValid(mapname)) {
		g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" does not exist! Why is it in the nom list???\n");
		return false;
	}
	
	if (isMapExcluded(mapname, getActivePlayers(true), plr)) {
		return false;
	}
	
	string oldNomMap = g_playerStates[eidx].nom;
	g_playerStates[eidx].nom = mapname;
	
	g_nomList.insertLast(mapname);
	
	if (oldNomMap.IsEmpty()) {
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + (isRandom ? " randomly" : "") + " nominated \"" + mapname + "\".\n");
	} else {
		g_nomList.removeAt(g_nomList.find(oldNomMap));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + (isRandom ? " randomly" : "") + " changed their nomination to \"" + mapname + "\".\n");
	}
	
	return true;
}




void sendMapList(CBasePlayer@ plr) {
	const float delayStep = 0.1f; // chunks might arrive out of order any faster than this
	const uint chunkSize = 12;
	float delay = 0;
	array<string> buffer;
	
	g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), "\n--Map list---------------\n");
	delay += delayStep;
	
	// send in chunks to prevent overflows
	for (uint i = 0; i < g_everyMap.length(); i += 4) {
		string msg = "";
		for (uint k = 0; k < 4 && i + k < g_everyMap.length(); k++) {
			msg += g_everyMap[i + k].map;
			int padding = (g_maxNomMapNameLength + 1) - g_everyMap[i + k].map.Length();
			for (int p = 0; p < padding; p++) {
				msg += " ";
			}
		}

		buffer.insertLast(msg + "\n");
		if (buffer.size() >= chunkSize) {
			g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), buffer);
			buffer = array<string>();
			delay += delayStep;
		}
	}
	
	if (buffer.size() > 0) {
		g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), buffer);
		buffer = array<string>();
		delay += delayStep;
	}
	
	delay += delayStep;
	g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), "----------------------------- (" + g_everyMap.length() +" maps)\n\n");

	g_PlayerFuncs.SayText(plr, "[RTV] Map list written to console");
}

array<string> loadMapList(string path, bool ignoreDuplicates=false) {
	array<string> maplist;

	File@ file = g_FileSystem.OpenFile(path, OpenFile::READ);

	dictionary unique;

	if (file !is null && file.IsOpen()) {
		while (!file.EOFReached()) {
			string line;
			file.ReadLine(line);
			line.Trim();
			
			int commentIdx = line.Find("//");
			if (commentIdx != -1) {
				line = line.SubString(0, commentIdx);
				line.Trim();
			}

			if (line.IsEmpty())
				continue;

			array<string> parts = line.Split(" ");

			// allow either mapcycle or mapvote format
			string mapname;
			if (parts[0] == "addvotemap" && parts.size() > 1) {
				mapname = parts[1].ToLowercase();
			} else {
				mapname = parts[0].ToLowercase();
			}
			mapname.Trim(); // TODO: doesn't work on linux for some reason. Tabs are not stripped. Replacing tabs also doesn't work.
			
			if (!ignoreDuplicates && unique.exists(mapname)) {
				g_Log.PrintF("[RTV] duplicate map " + mapname + " in list: " + path + "\n");
				continue;
			}
			
			unique[mapname] = true;
			maplist.insertLast(mapname);
		}

		file.Close();
	} else {
		g_Log.PrintF("[RTV] map list file not found: " + path + "\n");
	}
	
	return maplist;
}

void loadSeriesMaps() {
	g_seriesMaps.clear();
	
	File@ file = g_FileSystem.OpenFile(seriesMapsFile, OpenFile::READ);

	dictionary unique;

	if (file !is null && file.IsOpen()) {
		while (!file.EOFReached()) {
			string line;
			file.ReadLine(line);
			line.Trim();
			
			int commentIdx = line.Find("//");
			if (commentIdx != -1) {
				line = line.SubString(0, commentIdx);
				line.Trim();
			}

			if (line.IsEmpty())
				continue;

			array<string> maps = line.Split(" ");
			array<SortableMap> sortableMaps;

			for (uint i = 0; i < maps.size(); i++) {
				sortableMaps.insertLast(SortableMap(maps[i]));
			}

			bool foundAnyVotable = false;
			for (uint i = 0; i < maps.size(); i++) {
				if (g_everyMapHashed.exists(maps[i])) {
					g_seriesMaps[maps[i]] = sortableMaps;
					foundAnyVotable = true;
				}
			}
			
			if (!foundAnyVotable) {
				g_seriesMaps[maps[0]] = sortableMaps;
			}
		}

		file.Close();
	} else {
		g_Log.PrintF("[RTV] map list file not found: " + seriesMapsFile + "\n");
	}
}

void loadAllMapLists() {
	g_normalMaps = loadMapList(votelistFile);
	g_hiddenMaps = loadMapList(hiddenMapsFile);
	
	g_memeMapsHashed.clear();
	g_everyMapHashed.clear();
	
	g_everyMap.resize(0);
	g_randomRtvChoices.resize(0);
	g_randomCycleMaps.resize(0);
	
	for (uint i = 0; i < g_hiddenMaps.size(); i++) {
		g_everyMap.insertLast(SortableMap(g_hiddenMaps[i]));
		g_everyMapHashed[g_hiddenMaps[i]] = true;
		g_memeMapsHashed[g_hiddenMaps[i]] = true;
		
		if (g_hiddenMaps[i].Length() > g_maxNomMapNameLength) {
			g_maxNomMapNameLength = g_hiddenMaps[i].Length();
		}
	}
	
	for (uint i = 0; i < g_normalMaps.size(); i++) {
		if (g_memeMapsHashed.exists(g_normalMaps[i])) {
			g_Log.PrintF("[RTV] Map \"" + g_normalMaps[i] + "\" should either be in mapvote.cfg or hidden_nom_maps.txt, but not both.\n");
			continue;
		}
	
		g_everyMap.insertLast(SortableMap(g_normalMaps[i]));
		g_everyMapHashed[g_normalMaps[i]] = true;
		
		if (g_normalMaps[i].Length() > g_maxNomMapNameLength) {
			g_maxNomMapNameLength = g_normalMaps[i].Length();
		}
		if (g_normalMaps[i] != g_Engine.mapname) {
			g_randomRtvChoices.insertLast(SortableMap(g_normalMaps[i]));
		}
	}
	
	array<string> mapCycleMaps = g_MapCycle.GetMapCycle();
	for (uint i = 0; i < mapCycleMaps.size(); i++) {
		if (mapCycleMaps[i] != g_Engine.mapname) {
			g_randomCycleMaps.insertLast(SortableMap(mapCycleMaps[i]));
		}
		if (!g_everyMapHashed.exists(mapCycleMaps[i])) {
			g_Log.PrintF("[RTV] Map \"" + mapCycleMaps[i] + "\" should also be in mapvote.cfg if it's good enough to be in map cycle.\n");
		}
	}
	
	loadSeriesMaps();

	g_everyMap.sort(function(a,b) { return a.map.Compare(b.map) < 0; });
}

array<SortableMap>@ getMapSeriesMaps(string thismap) {
	string mapname = thismap.ToLowercase();
	
	array<string>@ mapKeys = g_seriesMaps.getKeys();
	for (uint i = 0; i < mapKeys.length(); i++) {
		array<SortableMap>@ maps = cast<array<SortableMap>@>(g_seriesMaps[mapKeys[i]]);
		
		for (uint k = 0; k < maps.size(); k++) {
			if (maps[k].map == mapname) {
				return maps;
			}
		}
	}
	
	return null;
}

string getNextSeriesMap(array<SortableMap>@ maps) {
	string mapname = string(g_Engine.mapname).ToLowercase();
	
	if (maps !is null) {
		for (uint i = 0; i < maps.size(); i++) {
			if (maps[i].map == mapname) {
				if (i + 1 >= maps.size()) {
					return "";
				}
				return maps[i+1].map;
			}
		}
	}
	
	return "";
}

// return the first map in the series, if the current map is a series map
void printSeriesInfo() {
	string mapname = string(g_Engine.mapname).ToLowercase();
	
	array<string>@ mapKeys = g_seriesMaps.getKeys();
	for (uint i = 0; i < mapKeys.length(); i++) {
		array<SortableMap>@ maps = cast<array<SortableMap>@>(g_seriesMaps[mapKeys[i]]);
		
		for (uint k = 0; k < maps.size(); k++) {
			if (maps[k].map == mapname) {
				int prc = int((k / float(maps.size()))*100);
				string msg = "This is map " + (k+1) + " of " + maps.size() + " in the \"" + maps[0].map + "\" series.";
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, msg + "\n");
				return;
			}
		}
	}
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "This is not a map series.");
}

bool rejectNonAdmin(CBasePlayer@ plr) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (!isAdmin) {
		g_PlayerFuncs.SayText(plr, "[RTV] Admins only >:|\n");
		return true;
	}
	
	return false;
}

// find a player by name or partial name
CBasePlayer@ getPlayerByName(CBasePlayer@ caller, string name) {
	name = name.ToLowercase();
	int partialMatches = 0;
	CBasePlayer@ partialMatch;
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null) {
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			string plrName = string(plr.pev.netname).ToLowercase();
			if (plrName == name)
				return plr;
			else if (plrName.Find(name) != uint(-1))
			{
				@partialMatch = plr;
				partialMatches++;
			}
		}
	} while (ent !is null);
	
	if (partialMatches == 1) {
		return partialMatch;
	} else if (partialMatches > 1) {
		g_PlayerFuncs.SayText(caller, 'There are ' + partialMatches + ' players that have "' + name + '" in their name. Be more specific.\n');
	} else {
		g_PlayerFuncs.SayText(caller, 'There is no player named "' + name + '".\n');
	}
	
	return null;
}

bool shouldLaggyCmdCooldown(CBasePlayer@ plr) {
	string steamid = getPlayerUniqueId(plr);
	float lastCommand = float(g_lastLaggyCommands[steamid]);

	if (g_Engine.time - lastCommand < LAGGY_COMAND_COOLDOWN) {
		int cooldown = LAGGY_COMAND_COOLDOWN - int(g_Engine.time - lastCommand);
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Wait " + cooldown + " seconds\n");
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Wait " + cooldown + " seconds\n");
		return true;
	}
	
	g_lastLaggyCommands[steamid] = g_Engine.time;
	
	return false;
}

bool shouldQuestionCooldown(CBasePlayer@ plr) {
	string steamid = getPlayerUniqueId(plr);

	if (g_Engine.time - g_lastQuestion < QUESTION_COOLDOWN) {
		int cooldown = QUESTION_COOLDOWN - int(g_Engine.time - g_lastQuestion);
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Wait " + cooldown + " seconds\n");
		return true;
	}
	
	g_lastQuestion = g_Engine.time;
	
	return false;
}

// return 0 = chat not handled, 1 = handled and show chat, 2 = handled and hide chat
int doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == ".mapinfo") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}			
			
			for (int i = 1; i <= g_Engine.maxClients; i++) {
				CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
				
				if (p is null or !p.IsConnected()) {
					continue;
				}
				
				string steamid = getPlayerUniqueId(p);
				
				PlayerMapHistory@ history = cast<PlayerMapHistory@>(g_player_map_history[steamid]);
				if (history is null) {
					continue;
				}
				
				MapStat@ stat = history.stats.get(g_Engine.mapname);
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "" + p.pev.netname + " " + g_Engine.mapname + " " + stat.last_played + " " + getPlayerDbPath(steamid) + "\n");
			}
			
			return 2;
		}
		if (args[0] == "series?") {
			if (shouldQuestionCooldown(plr)) {
				return 2;
			}
			printSeriesInfo();
			
			return 0;
		}
		else if (args[0] == ".newmaps" || args[0] == ".recentmaps") {
			bool reverse = args[0] == ".newmaps";
			bool cycleMapsOnly = args[1] == '\\cycle' || args[2] == '\\cycle';
			array<SortableMap>@ maps = cycleMapsOnly ? @g_randomCycleMaps : @g_everyMap;

			if (args[1].ToLowercase() == "\\all") {
				if (shouldLaggyCmdCooldown(plr)) {
					return 2;
				}
			
				showFreshMaps(EHandle(plr), TARGET_ALL, "anyone", "STEAM_0:????", copyArray(maps), reverse);
			} else {
				string nameUpper = args[1].ToUppercase();
				if (nameUpper.Find("STEAM_0:") == 0) {
					if (shouldLaggyCmdCooldown(plr)) {
						return 2;
					}
				
					dictionary freshArgs = {
						{'plr', EHandle(plr)},
						{'steamId', nameUpper},
						{'reverse', reverse},
						{'maps', maps}
					};
					
					loadPlayerMapStats(nameUpper, function(args) {
						string steamid = string(args['steamId']);
						array<SortableMap>@ maps = cast<array<SortableMap>@>(args['maps']);
						showFreshMaps(EHandle(args['plr']), TARGET_PLAYER, steamid, steamid, copyArray(maps), bool(args['reverse']));
					}, freshArgs);
				} else {
					if (shouldLaggyCmdCooldown(plr)) {
						return 2;
					}
				
					CBasePlayer@ target = plr;
					if (nameUpper.Length() > 0 and args[1] != '\\cycle') {
						@target = @getPlayerByName(plr, args[1]);
					}
				
					if (target !is null) {
						string targetName = "you";
						string targetId = getPlayerUniqueId(plr);
						int targetType = TARGET_SELF;
						
						if (target.entindex() != plr.entindex()) {
							targetName = '"' + target.pev.netname + '"';
							targetId = getPlayerUniqueId(plr);
							targetType = TARGET_PLAYER;
						}
						
						showFreshMaps(EHandle(plr), targetType, targetName, targetId, copyArray(maps), reverse);
					}
				}
			}
				
			return 2;
		}
		else if (args[0] == ".mapstats") {
			string mapname = args.ArgC() == 1 ? string(g_Engine.mapname) : args[1].ToLowercase();
			
			if (!g_EngineFuncs.IsMapValid(mapname)) {
				g_PlayerFuncs.SayText(plr, "Map \"" + mapname + "\" does not exist!\n");
				return 2;
			}
			
			showLastPlayedTimes(plr, mapname);
			return 2;
		}
		else if (args[0] == "rtv" and args.ArgC() == 1) {
			return tryRtv(plr);
		}
		else if (args[0] == "unrtv" and args.ArgC() == 1) {
			return unRtv(plr);
		}
		else if (args[0] == "nom" || args[0] == "nominate" || args[0] == ".nom" || args[0] == ".nominate") {
			string mapname = args.ArgC() >= 2 ? args[1].ToLowercase() : "";
			tryNominate(plr, mapname, false);
			return 2;
		}
		else if (args[0] == "rnom") {
			tryNominate(plr, g_everyMap[Math.RandomLong(0, g_everyMap.size())].map, true);
			return 2;
		}
		else if (args[0] == "unnom" || args[0] == "unom" || args[0] == "denom" ||
				 args[0] == ".unnom" || args[0] == ".unom" || args[0] == ".denom") {
			RtvState@ state = g_playerStates[plr.entindex()];
			if (g_rtvVote.status != MVOTE_NOT_STARTED || g_generating_rtv_list) {
				g_PlayerFuncs.SayText(plr, "[RTV] Too late for that now!\n");
			}
			else if (state.nom.Length() > 0) {
				g_nomList.removeAt(g_nomList.find(state.nom));
				g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " removed their \"" + state.nom + "\" nomination.\n");
				state.nom = "";
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] You haven't nominated anything yet!\n");
			}
			return 2;
		}
		else if (args[0] == "listnom" || args[0] == "nomlist" || args[0] == "lnom" || args[0] == "noms" ||
				 args[0] == ".listnom" || args[0] == ".nomlist" || args[0] == ".lnom" || args[0] == ".noms") {
			if (g_nomList.size() > 0) {
				string msg = "[RTV] Current nominations: ";
				
				for (uint i = 0; i < g_nomList.size(); i++) {
					msg += (i != 0 ? ", " : "") + g_nomList[i];
				}
				
				g_PlayerFuncs.SayText(plr, msg + "\n");
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] Nothing has been nominated yet.\n");
			}
			
			return 2;
		}
		else if (args[0] == "maplist" || args[0] == "listmaps" || args[0] == ".maplist" || args[0] == ".listmaps") {
			sendMapList(plr);
			return 2;
		}
		else if (args[0] == ".forcertv") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (g_rtvVote.status != MVOTE_NOT_STARTED) {
				g_PlayerFuncs.SayText(plr, "[RTV] A vote is already in progress!\n");
			} else {
				startVote("(forced by " + plr.pev.netname + ")");
			}
			return 2;
		}
		else if (args[0] == ".cancelrtv") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			cancelRtv(plr);
			return 2;
		}
		else if (args[0] == ".map") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (args.ArgC() < 2) {
				g_PlayerFuncs.SayText(plr, "Usage: .map <mapname>\n");
				return 2;
			}
			
			string nextmap = args[1].ToLowercase();
			if (!g_EngineFuncs.IsMapValid(nextmap)) {
				g_PlayerFuncs.SayText(plr, "Map \"" + nextmap + "\" does not exist!\n");
				return 2;
			}
			
			game_end(nextmap);
			
			string msg = "" + plr.pev.netname + " changed map to: " + nextmap + "\n";
			g_PlayerFuncs.SayTextAll(plr, msg);
			g_Log.PrintF(msg);
			
			return 2;
		}
		else if (args[0] == ".set_nextmap") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (args.ArgC() < 2) {
				g_PlayerFuncs.SayText(plr, "Usage: .set_nextmap <mapname>\n");
				return 2;
			}
			
			string nextmap = args[1].ToLowercase();
			if (!g_EngineFuncs.IsMapValid(nextmap)) {
				g_PlayerFuncs.SayText(plr, "Map \"" + nextmap + "\" does not exist!\n");
				return 2;
			}
			
			string old = g_MapCycle.GetNextMap();
			if (old == nextmap) {
				g_PlayerFuncs.SayText(plr, old + " is already set as the next map!\n");
			} else {
				g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextmap + "\n");
				string msg = "" + plr.pev.netname + " changed the next map: " + old + " -> " + nextmap + "\n";
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, msg);
				g_Log.PrintF(msg);
			}
			
			return 2;
		}
	}
	
	return doGameVote(plr, args, inConsole);
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	int chatHandled = doCommand(plr, args, false);
	
	if (chatHandled == 2) {
		pParams.ShouldHide = true;
	}
	return HOOK_CONTINUE;
}

HookReturnCode ClientJoin( CBasePlayer@ plr ) {	
	string steamid = getPlayerUniqueId(plr);
	loadPlayerMapStats(steamid, function(args){}, {});
	
	if (!g_player_activity.exists(steamid)) {
		g_player_activity[steamid] = PlayerActivity();
	}
	
	g_anyone_joined = true;
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {
	string steamid = getPlayerUniqueId(plr);
	RtvState@ state = g_playerStates[plr.entindex()];
	state.didRtv = false;
	state.afkTime = 0;
	
	if (state.nom.Length() > 0) {
		g_nomList.removeAt(g_nomList.find(state.nom));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] \"" + state.nom + "\" is no longer nominated.\n");
		state.nom = "";
	}
	
	return HOOK_CONTINUE;
}

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}
