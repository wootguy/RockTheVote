#include "MenuVote"
#include "GameVotes"
#include "Stats"
#include "HashMap"

// TODO:
// - dont show log message for <4 plaers on classic restart
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
CClientCommand pastmaplist("pastmaplist", "Show recently played maps (up to g_ExcludePrevMapsNom)", @consoleCmd);
CClientCommand pastmaplistfull("pastmaplistfull", "Show recently played maps (up to g_ExcludePrevMapsNomMeme)", @consoleCmd);
CClientCommand set_nextmap("set_nextmap", "Set the next map cycle", @consoleCmd);
CClientCommand map("map", "Force a map change", @consoleCmd);
CClientCommand vote("vote", "Start a vote or reopen the vote menu", @consoleCmd);
CClientCommand poll("poll", "Start a custom poll", @consoleCmd);
CClientCommand lastplay("lastplay", "Show previous play times for a map", @consoleCmd);
CClientCommand lastplays("lastplays", "Show previous play times for a map", @consoleCmd);
CClientCommand recentmaps("recentmaps", "Show recently played maps", @consoleCmd);
CClientCommand newmaps("newmaps", "Show maps that haven't been played for the longest time", @consoleCmd);

CCVar@ g_SecondsUntilVote;
CCVar@ g_MaxMapsToVote;
CCVar@ g_VotingPeriodTime;
CCVar@ g_PercentageRequired;
CCVar@ g_ExcludePrevMaps;			// limit before a map can be randomly added to the RTV menu again
CCVar@ g_ExcludePrevMapsNom;		// limit for nomming a regular map again
CCVar@ g_ExcludePrevMapsNomMeme;	// limit for nomming a hidden/meme map again
CCVar@ g_EnableGameVotes;			// enable text menu replacements for the default game votes
CCVar@ g_EnableForceSurvivalVotes;	// enable semi-survival vote (requires ForceSurvival plugin)

// maps that can be nominated with a normal cooldown
const string votelistFile = "scripts/plugins/cfg/mapvote.txt"; 
array<string> g_normalMaps;

// maps that have a large nom cooldown and never randomly show up in the vote menu
const string hiddenMapsFile = "scripts/plugins/cfg/hidden_nom_maps.txt";
array<string> g_hiddenMaps;

// previously played maps, to prevent nom'ing maps that were played too recently
const string previousMapsFile = "scripts/plugins/store/previous_maps.txt";
array<string> g_previousMaps;

array<RtvState> g_playerStates;
array<SortableMap> g_everyMap; // sorted combination of normal and hidden maps
array<SortableMap> g_randomRtvChoices; // normal votable maps which aren't in the previous map list
array<SortableMap> g_randomCycleMaps; // map cycle maps which aren't in the previous map list
array<string> g_nomList; // maps nominated by players
dictionary g_prevMapPosition; // maps a map name to its position in the previous map list (for faster nom menus)
dictionary g_memeMapsHashed; // for faster meme map checks
MenuVote::MenuVote g_rtvVote;
uint g_maxNomMapNameLength = 0; // used for even spacing in the full console map list
CScheduledFunction@ g_timer = null;
bool g_generating_rtv_list = false; // true while maps are being sorted for rtv menu

const float levelChangeDelay = 5.0f; // time in seconds intermission is shown for game_end



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
	@g_ExcludePrevMaps = CCVar("iExcludePrevMaps", 800, "How many maps to previous maps to remember", ConCommandFlag::AdminOnly);
	@g_ExcludePrevMapsNom = CCVar("iExcludePrevMapsNomOnly", 20, "Exclude recently played maps from nominations", ConCommandFlag::AdminOnly);
	@g_ExcludePrevMapsNomMeme = CCVar("iExcludePrevMapsNomOnlyMeme", 400, "Exclude recently played maps from nominations (hidden maps)", ConCommandFlag::AdminOnly);
	@g_EnableGameVotes = CCVar("gameVotes", 1, "Text menu replacements for the default game votes", ConCommandFlag::AdminOnly);
	@g_EnableForceSurvivalVotes = CCVar("forceSurvivalVotes", 0, "Enable semi-survival vote (requires ForceSurvival plugin)", ConCommandFlag::AdminOnly);

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
	
	setFreshMapAsNextMap(g_randomCycleMaps); // something most haven't played in the longest time
}

HookReturnCode MapChange() {
	writePreviousMapsList();
	writeActivePlayerStats();
	g_player_activity.clear();
	g_Scheduler.RemoveTimer(g_timer);
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
	g_lastGameVote = 0;
	g_anyone_joined = false;
	g_generating_rtv_list = false;
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
			g_playerStates[i].afkTime = 1;
		}
	}
}

void autoStartRtvCheck() {
	loadCrossPluginAfkState();

	if (canAutoStartRtv()) {
		startVote("(vote requirement lowered to " + getRequiredRtvCount() + " due to leaving/AFK players)");
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
		
		if (g_playerStates[i].afkTime > 0 && excludeAfks) {
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
			return !g_generating_rtv_list;
		}
	}
	
	return false;
}

funcdef void void_callback();

void createRtvMenu() {
	array<string> rtvList;
	if (!g_generating_rtv_list) {
		return; // game_end interrupted sort
	}
	g_generating_rtv_list = false;
	
	for (uint i = 0; i < g_nomList.size(); i++) {
		rtvList.insertLast(g_nomList[i]);
	}
	
	for (uint failsafe = 0; failsafe < g_randomRtvChoices.size(); failsafe++) {	
		if (int(rtvList.size()) >= g_MaxMapsToVote.GetInt() or int(rtvList.size()) >= 8) {
			break;
		}
		
		string randomMap = g_randomRtvChoices[failsafe].map;
		
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
	voteParams.forceOpen = false;
	@voteParams.optionCallback = @mapChosenCallback;
	@voteParams.thinkCallback = @voteThinkCallback;
	@voteParams.finishCallback = @voteFinishCallback;
	
	g_rtvVote.start(voteParams, null);
}

void startVote(string reason="") {
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] Vote starting! " + reason + "\n");
	
	if (g_randomRtvChoices.size() == 0) {
		g_Log.PrintF("[RTV] All maps are excluded by the previous map list! Make sure g_ExcludePrevMaps value is less than the total nommable maps.\n");
		createRtvMenu();
		return;
	}
	
	g_generating_rtv_list = true;
	sortMapsByFreshness(g_randomRtvChoices, getActivePlayers(), function() { createRtvMenu(); });
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
	
	if (g_rtvVote.status == MVOTE_IN_PROGRESS || g_generating_rtv_list) {
		g_rtvVote.reopen(plr);
		return 2;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] RTV will enable in " + timeLeft + " seconds.  -" + plr.pev.netname + "\n");
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
	
	g_PlayerFuncs.SayTextAll(plr, "[RTV] Vote cancelled by " + plr.pev.netname + "!\n");
}

// returns number of maps needed to play before it can be nom'd
int getMapExcludeTime(string mapname, bool printMessage=false, CBasePlayer@ plr=null) {
	if (!g_prevMapPosition.exists(mapname)) {
		return 0;
	}

	int lastPrevIdx = 0;
	g_prevMapPosition.get(mapname, lastPrevIdx);
	
	bool isMemeMap = g_memeMapsHashed.exists(mapname);
	int mapsAgo = g_previousMaps.size() - lastPrevIdx;

	if (isMemeMap && mapsAgo < g_ExcludePrevMapsNomMeme.GetInt()) {
		int leftToPlay = (g_ExcludePrevMapsNomMeme.GetInt() - mapsAgo) + 1;
		if (printMessage) {
			g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluded until " + leftToPlay + " other nom-able maps have been played with 4+ players.\n");
		}
		return leftToPlay;
	}
	else if (!isMemeMap && mapsAgo < g_ExcludePrevMapsNom.GetInt()) {
		int leftToPlay = (g_ExcludePrevMapsNom.GetInt() - mapsAgo) + 1;
		if (printMessage) {
			g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluded until " + leftToPlay + " other nom-able maps have been played with 4+ players.\n");
		}
		return leftToPlay;
	}
	
	return 0;
}

void nomMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected() or g_rtvVote.status != MVOTE_NOT_STARTED) {
		return;
	}

	string nomChoice;
	item.m_pUserData.retrieve(nomChoice);
	tryNominate(plr, nomChoice);
}

void openNomMenu(CBasePlayer@ plr, string mapfilter, array<string> maps) {
	int eidx = plr.entindex();
			
	@g_menus[eidx] = CTextMenu(@nomMenuCallback);
	
	string title = "\\yMaps containing \"" + mapfilter + "\"	 ";
	if (mapfilter.Length() == 0) {
		title = "\\yNominate...	  ";
	}
	g_menus[eidx].SetTitle(title);
	
	for (uint i = 0; i < maps.size(); i++) {
		string label = maps[i] + "\\y";
		
		int mapsLeft = getMapExcludeTime(maps[i]);
		if (mapsLeft > 0) {
			label = "\\r" + label + "	\\d(" + mapsLeft + ")\\y";
		} else {
			label = "\\w" + label;
		}
		
		g_menus[eidx].AddItem(label, any(maps[i]));
	}
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, plr);
}

bool tryNominate(CBasePlayer@ plr, string mapname) {
	if (g_rtvVote.status != MVOTE_NOT_STARTED) {
		return false;
	}

	int eidx = plr.entindex();
	bool dontAutoNom = int(mapname.Find("*")) != -1; // player just wants to search for maps with this string
	mapname.Replace("*", "");
	bool fullNomMenu = mapname.Length() == 0;
	
	bool mapExists = false;
	for (uint i = 0; i < g_everyMap.size(); i++) {
		if (g_everyMap[i].map == mapname) {
			mapExists = true;
		}
	}

	if (fullNomMenu || dontAutoNom || !mapExists) {
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
		
		if (similarNames.size() == 0) {
			g_PlayerFuncs.SayText(plr, "[RTV] No maps containing \"" + mapname + "\" exist.");
		}
		else if (similarNames.size() > 1 || dontAutoNom) {
			openNomMenu(plr, mapname, similarNames);
		}
		else if (similarNames.size() == 1) {
			return tryNominate(plr, similarNames[0]);
		}
		
		return false;
	}
	
	if (mapname == g_Engine.mapname) {
		g_PlayerFuncs.SayText(plr, "[RTV] Can't nominate the current map!\n");
		return false;
	}
	
	int mapExcludeTime = getMapExcludeTime(mapname);
	if (getMapExcludeTime(mapname, true, plr) > 0) {
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
	
	string oldNomMap = g_playerStates[eidx].nom;
	g_playerStates[eidx].nom = mapname;
	
	g_nomList.insertLast(mapname);
	
	if (oldNomMap.IsEmpty()) {
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " nominated \"" + mapname + "\".\n");
	} else {
		g_nomList.removeAt(g_nomList.find(oldNomMap));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " changed their nomination to \"" + mapname + "\".\n");
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

void sendPastMapList(CBasePlayer@ plr) {
	int start = 0;
	if (int(g_previousMaps.length()) > g_ExcludePrevMapsNom.GetInt()) {
		start = g_previousMaps.length() - g_ExcludePrevMapsNom.GetInt();
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "--Past maplist---------------\n");
	for (uint i = start; i < g_previousMaps.length(); i++) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + ((i-start) + 1) +	 ": "  + g_previousMaps[i] + "\n");
	}
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "-----------------------------\n");
}

void sendPastMapList_full(CBasePlayer@ plr) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "--Past maplist---------------\n");
	for (uint i = 0; i < g_previousMaps.length(); i++) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + (i + 1) +	 ": "  + g_previousMaps[i] + "\n");
	}
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "-----------------------------\n");
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

void loadAllMapLists() {
	g_normalMaps = loadMapList(votelistFile);
	g_hiddenMaps = loadMapList(hiddenMapsFile);
	g_previousMaps = loadMapList(previousMapsFile, true);
	
	g_prevMapPosition.clear();
	g_memeMapsHashed.clear();
	
	// use a dictionary to check for maps to exclude faster
	for (uint i = 0; i < g_previousMaps.size(); i++) {
		g_prevMapPosition[g_previousMaps[i]] = i;
	}
	
	g_everyMap.resize(0);
	g_randomRtvChoices.resize(0);
	g_randomCycleMaps.resize(0);
	
	for (uint i = 0; i < g_hiddenMaps.size(); i++) {
		g_everyMap.insertLast(SortableMap(g_hiddenMaps[i]));
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
		
		if (g_normalMaps[i].Length() > g_maxNomMapNameLength) {
			g_maxNomMapNameLength = g_normalMaps[i].Length();
		}
		if (!g_prevMapPosition.exists(g_normalMaps[i]) and g_normalMaps[i] != g_Engine.mapname) {
			g_randomRtvChoices.insertLast(SortableMap(g_normalMaps[i]));
		}
	}
	
	array<string> mapCycleMaps = g_MapCycle.GetMapCycle();
	for (uint i = 0; i < mapCycleMaps.size(); i++) {
		if (!g_prevMapPosition.exists(mapCycleMaps[i]) and mapCycleMaps[i] != g_Engine.mapname) {
			g_randomCycleMaps.insertLast(SortableMap(mapCycleMaps[i]));
		}
	}

	g_everyMap.sort(function(a,b) { return a.map.Compare(b.map) < 0; });
}

void writePreviousMapsList() {
	string mapname = string(g_Engine.mapname).ToLowercase();

	if (g_PlayerFuncs.GetNumPlayers() < 4) {
		g_Log.PrintF("[RTV] Not writing previous map - less than 4 players\n");
		return;
	}
	if (g_normalMaps.find(mapname) < 0 && g_hiddenMaps.find(mapname) < 0) {
		g_Log.PrintF("[RTV] Not writing previous map - " + mapname + " not in vote list(s)\n");
		return; // prevent maps in a series from being added to the list
	}

	if (g_previousMaps.size() > 0 and g_previousMaps[g_previousMaps.size()-1] == mapname) {
		g_Log.PrintF("[RTV] Not writing previous map - restarts are not counted\n");
		return; // don't count map restarts
	}

	g_previousMaps.insertLast(string(g_Engine.mapname).ToLowercase());
	while ((int(g_previousMaps.length()) > g_ExcludePrevMaps.GetInt())) {
		g_previousMaps.removeAt(0);
	}

	File@ f = g_FileSystem.OpenFile(previousMapsFile, OpenFile::WRITE);

	if (f.IsOpen()) {
		int numWritten = 0;
		for (uint i = 0; i < g_previousMaps.size(); i++) {
			string name = g_previousMaps[i];
			name.Trim();
			if (name.Length() == 0) {
				continue;
			}

			f.Write(name + "\n");
		}
		f.Close();
	}
	else
		g_Log.PrintF("Failed to open previous maps file: " + previousMapsFile + "\n");
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

// return 0 = chat not handled, 1 = handled and show chat, 2 = handled and hide chat
int doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == ".newmaps" || args[0] == ".recentmaps") {
			bool reverse = args[0] == ".recentmaps";

			if (args[1].ToLowercase() == "\\all") {
				showFreshMaps(EHandle(plr), EHandle(null), g_everyMap, reverse);
			} else {
				CBasePlayer@ target = args[1].Length() > 0 ? getPlayerByName(plr, args[1]) : plr;
				if (target !is null)
					showFreshMaps(EHandle(plr), target, g_everyMap, reverse);
			}
				
			return 2;
		}
		else if (args[0] == ".lastplay" || args[0] == ".lastplays") {
			showLastPlayedTimes(plr, args.ArgC() == 1 ? string(g_Engine.mapname) : args[1].ToLowercase());
			return 2;
		}
		else if (args[0] == "rtv" and args.ArgC() == 1) {
			return tryRtv(plr);
		}
		else if (args[0] == "nom" || args[0] == "nominate") {
			string mapname = args.ArgC() >= 2 ? args[1].ToLowercase() : "";
			tryNominate(plr, mapname);
			return 2;
		}
		else if (args[0] == "unnom" || args[0] == "unom" || args[0] == "denom") {
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
		else if (args[0] == "listnom" || args[0] == "nomlist" || args[0] == "lnom" || args[0] == "noms") {
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
		else if (args[0] == "maplist" || args[0] == "listmaps") {
			sendMapList(plr);
			return 2;
		}
		else if (args[0] == ".pastmaplist") {
			sendPastMapList(plr);
			return 2;
		}
		else if (args[0] == ".pastmaplistfull") {
			sendPastMapList_full(plr);
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
			
			g_PlayerFuncs.SayTextAll(plr, "" + plr.pev.netname + " changed map to: " + nextmap + "\n");
			
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
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " changed the next map: " + old + " -> " + nextmap + "\n");
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
	loadPlayerMapStats(steamid);
	
	if (g_player_activity.exists(steamid)) {
		PlayerActivity@ activity = cast<PlayerActivity@>(g_player_activity[steamid]);
		activity.lastActivity = g_Engine.time;
	} else {
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
	
	if (g_player_activity.exists(steamid)) {
		PlayerActivity@ activity = cast<PlayerActivity@>(g_player_activity[steamid]);
		activity.lastActivity = g_Engine.time;		
	}
	
	return HOOK_CONTINUE;
}

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}
