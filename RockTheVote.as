class RtvState {
	bool didRtv = false; // player wants to rock the vote?
	string nom; // what map this player nominated
	int voteOption = 0; // which option in the rtv menu was voted for
}

CClientCommand forcertv("forcertv", "Lets admin force a vote", @consoleCmd);
CClientCommand cancelrtv("cancelrtv", "Lets admin cancel an ongoing RTV vote", @consoleCmd);
CClientCommand pastmaplist("pastmaplist", "Show recently played maps (up to g_ExcludePrevMapsNom)", @consoleCmd);
CClientCommand pastmaplistfull("pastmaplistfull", "Show recently played maps (up to g_ExcludePrevMapsNomMeme)", @consoleCmd);
CClientCommand set_nextmap( "set_nextmap", "Set the next map cycle", @consoleCmd );

CCVar@ g_SecondsUntilVote;
CCVar@ g_MaxMapsToVote;
CCVar@ g_VotingPeriodTime;
CCVar@ g_PercentageRequired;
CCVar@ g_ExcludePrevMaps;			// limit before a map can be randomly added to the RTV menu again
CCVar@ g_ExcludePrevMapsNom;		// limit for nomming a regular map again
CCVar@ g_ExcludePrevMapsNomMeme;	// limit for nomming a hidden/meme map again

// maps that can be nominated with a normal cooldown
const string votelistFile = "scripts/plugins/cfg/mapvote.cfg"; 
array<string> g_normalMaps;

// maps that have a large nom cooldown and never randomly show up in the vote menu
const string hiddenMapsFile = "scripts/plugins/cfg/hidden_nom_maps.txt";
array<string> g_hiddenMaps;

// previously played maps, to prevent nom'ing maps that were played too recently
const string previousMapsFile = "scripts/plugins/store/previous_maps.txt";
array<string> g_previousMaps;

array<RtvState> g_playerStates;
array<string> g_everyMap; // sorted combination of normal and hidden maps
array<string> g_randomMapChoices; // normal maps which aren't in the previous map list
array<string> g_rtvList; // maps chosen for the vote menu
array<string> g_nomList; // maps nominated by players
dictionary g_prevMapPosition; // maps a map name to its position in the previous map list (for faster nom menus)
dictionary g_memeMapsHashed; // for faster meme map checks
bool g_voteInProgress = false;
bool g_voteEnded = false;
CTextMenu@ g_rtvMenu;
string g_lastMapName = "";
uint g_maxNomMapNameLength = 0; // used for even spacing in the full console map list
CScheduledFunction@ voteTimer = null;

// Menus need to be defined globally when the plugin is loaded or else paging doesn't work.
// Each player needs their own menu or else paging breaks when someone else opens the menu.
// These also need to be modified directly (not via a local var reference).
array<CTextMenu@> g_nomMenus = {
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null
};



void PluginInit() {

    g_Module.ScriptInfo.SetAuthor("w00tguy");
    g_Module.ScriptInfo.SetContactInfo("https://github.com/wootguy");
    g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientLeave);
    g_Hooks.RegisterHook(Hooks::Player::ClientSay, @ClientSay);
    g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);

    @g_SecondsUntilVote = CCVar("secondsUntilVote", 120, "Delay before players can RTV after map has started", ConCommandFlag::AdminOnly);
    @g_MaxMapsToVote = CCVar("iMaxMaps", 9, "How many maps can players nominate and vote for later", ConCommandFlag::AdminOnly);
    @g_VotingPeriodTime = CCVar("secondsToVote", 11, "How long can players vote for a map before a map is chosen", ConCommandFlag::AdminOnly);
    @g_PercentageRequired = CCVar("iPercentReq", 66, "0-100, percent of players required to RTV before voting happens", ConCommandFlag::AdminOnly);
    @g_ExcludePrevMaps = CCVar("iExcludePrevMaps", 800, "How many maps to previous maps to remember", ConCommandFlag::AdminOnly);
    @g_ExcludePrevMapsNom = CCVar("iExcludePrevMapsNomOnly", 20, "Exclude recently played maps from nominations", ConCommandFlag::AdminOnly);
    @g_ExcludePrevMapsNomMeme = CCVar("iExcludePrevMapsNomOnlyMeme", 400, "Exclude recently played maps from nominations (hidden maps)", ConCommandFlag::AdminOnly);

	reset();
	
	g_lastMapName = g_Engine.mapname;
}

void MapInit() {
    g_SoundSystem.PrecacheSound("fvox/one.wav");
    g_SoundSystem.PrecacheSound("fvox/two.wav");
    g_SoundSystem.PrecacheSound("fvox/three.wav");
    g_SoundSystem.PrecacheSound("fvox/four.wav");
    g_SoundSystem.PrecacheSound("fvox/five.wav");
    g_SoundSystem.PrecacheSound("gman/gman_choose1.wav");
    g_SoundSystem.PrecacheSound("gman/gman_choose2.wav");
	
	reset();
	
	string randomMap = g_randomMapChoices[Math.RandomLong(0, g_randomMapChoices.size()-1)];
	println("[RTV] Random next map: " + randomMap);
	g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + randomMap + "\n");
}

HookReturnCode MapChange() {
	writePreviousMapsList();
	g_Scheduler.RemoveTimer(voteTimer);
	return HOOK_CONTINUE;
}

void reset() {
	g_playerStates.resize(0);
	g_playerStates.resize(33);
	g_rtvList.resize(0);
	g_nomList.resize(0);
	g_voteInProgress = false;
	g_voteEnded = false;
	g_Scheduler.RemoveTimer(voteTimer);
	loadAllMapLists();
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

void change_map(string mapname) {
	g_EngineFuncs.ServerCommand("changelevel " + mapname + "\n");
}



int getCurrentRtvCount() {
	int count = 0;

	for (uint i = 0; i < g_playerStates.size(); i++) {
		count += g_playerStates[i].didRtv ? 1 : 0;
	}
	
	return count;
}

int getRequiredRtvCount() {
	uint playerCount = 0;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		playerCount++;
	}
	
	float percent = g_PercentageRequired.GetInt() / 100.0f;
	return int(Math.Ceil(percent * float(playerCount)));
}

int getOptionVotes(int option) {
	int voteCount = 0;
	
	for (uint k = 0; k < g_playerStates.size(); k++) {
		voteCount += (g_playerStates[k].voteOption == option) ? 1 : 0;
	}
	
	return voteCount;
}

void rtvMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected() or g_voteEnded or !g_voteInProgress) {
		return;
	}

	int option = 0;
	item.m_pUserData.retrieve(option);
	
	g_playerStates[plr.entindex()].voteOption = option;
	
	g_Scheduler.SetTimeout("updateVoteMenu", 0);
}

// return number of votes for the map with the most votes (for highlighting/tie-breaking)
int getHighestVotecount() {
	int bestVotes = -1;
	for (uint i = 0; i < g_rtvList.length(); i++) {
		int voteCount = getOptionVotes(i+1);
		
		if (voteCount == 0) {
			continue;
		}
		
		if (voteCount > bestVotes) {
			bestVotes = voteCount;
		}
	}
	
	return bestVotes;
}

void updateVoteMenu() {
	@g_rtvMenu = CTextMenu(@rtvMenuCallback);
    g_rtvMenu.SetTitle("\\yRTV Vote");
	
	int bestVotes = getHighestVotecount();
	bool anyoneVoted = bestVotes > -1;
	
	for (uint i = 0; i < g_rtvList.length(); i++) {
		int voteCount = 0;
		int thisOption = i+1;
		
		for (uint k = 0; k < g_playerStates.size(); k++) {
			voteCount += (g_playerStates[k].voteOption == thisOption) ? 1 : 0;
		}
	
		string label = g_rtvList[i];
		if (voteCount > 0) {
			if (voteCount == bestVotes) {
				label = "\\w" + label + "\\w";
			}
			label += "   \\d(" + voteCount + ")\\w";
		} else {
			label = (anyoneVoted ? "\\r" : "\\w") + label;
		}
		label += "\\y";
		
		g_rtvMenu.AddItem(label, any(thisOption));
    }

    g_rtvMenu.Register();

    for (int i = 1; i <= g_Engine.maxClients; i++) {
        CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);

        if (plr !is null) {
            g_rtvMenu.Open(0, 0, plr);
        }
    }
}

void fillRtvList() {
	g_rtvList.resize(0);
	
	for (uint i = 0; i < g_nomList.size(); i++) {
		g_rtvList.insertLast(g_nomList[i]);
	}
	
	while (int(g_rtvList.size()) < g_MaxMapsToVote.GetInt() && g_rtvList.size() < 1000 && g_randomMapChoices.size() > 0) {
		string randomMap = g_randomMapChoices[Math.RandomLong(0, g_randomMapChoices.size()-1)];
		
		if (g_rtvList.find(randomMap) == -1) {
			g_rtvList.insertLast(randomMap);
		}
	}
	
	if (g_randomMapChoices.size() == 0) {
		g_Log.PrintF("[RTV] All maps are excluded by the previous map list! Make sure g_ExcludePrevMaps value is less than the total nommable maps.\n");
	}
}

void startVote() {
	fillRtvList();
	g_voteInProgress = true;
	g_voteEnded = false;
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] You have " + g_VotingPeriodTime.GetInt() + " seconds to vote!\n");
	updateVoteMenu();
	@voteTimer = g_Scheduler.SetTimeout("voteThink", 0.0f, g_VotingPeriodTime.GetInt(), g_VotingPeriodTime.GetInt());
}

void voteThink(int secondsLeft, int startSeconds) {
	if (!g_voteInProgress) {
		return; // cancelled
	}

	if (secondsLeft == startSeconds)	{ playSoundGlobal("gman/gman_choose1.wav", 1.0f, 100); }
	else if (secondsLeft == 8)			{ playSoundGlobal("gman/gman_choose2.wav", 1.0f, 100); }
	else if (secondsLeft == 5)			{ playSoundGlobal("fvox/five.wav", 0.8f, 85); }
	else if (secondsLeft == 4)			{ playSoundGlobal("fvox/four.wav", 0.8f, 85); }
	else if (secondsLeft == 3)			{ playSoundGlobal("fvox/three.wav", 0.8f, 85); }
	else if (secondsLeft == 2)			{ playSoundGlobal("fvox/two.wav", 0.8f, 85); }
	else if (secondsLeft == 1)			{ playSoundGlobal("fvox/one.wav", 0.8f, 85); }

	g_PlayerFuncs.ClientPrintAll(HUD_PRINTCENTER, string(secondsLeft) + " seconds left to vote");
	
	if (secondsLeft > 1 && g_voteInProgress) {
		@voteTimer = g_Scheduler.SetTimeout("voteThink", 1.0f, secondsLeft-1, startSeconds);
	} else {
		@voteTimer = g_Scheduler.SetTimeout("finishVote", 1.0f);
	}
}

void finishVote() {
	if (!g_voteInProgress) {
		return; // vote cancelled
	}

	g_PlayerFuncs.ClientPrintAll(HUD_PRINTCENTER, "");
	g_voteEnded = true;
	
	array<string> bestOptions;
	
	int bestVotes = getHighestVotecount();	
	for (uint i = 0; i < g_rtvList.length(); i++) {
		int voteCount = getOptionVotes(i+1);
		
		if (voteCount >= bestVotes) {
			bestOptions.insertLast(g_rtvList[i]);
		}
	}
	
	string nextMap = bestOptions[0];
	
	if (bestOptions.size() > 1) {
		nextMap = bestOptions[Math.RandomLong(0, bestOptions.size()-1)];
		if (bestVotes == -1) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been randomly chosen since nobody picked.\n");
		} else {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been randomly chosen amongst the tied.\n");
		}
	} else {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" has been chosen!\n");
	}
	
	NetworkMessage message(MSG_ALL, NetworkMessages::SVC_INTERMISSION, null);
	message.End();
	
	@voteTimer = g_Scheduler.SetTimeout("change_map", 5.0f, nextMap);
}



void tryRtv(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	if (g_voteEnded) {
		return;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] RTV will enable in " + timeLeft + " seconds.");
		return;
	}

	if (g_voteInProgress) {
		g_rtvMenu.Open(0, 0, plr);
		return;
	}
	
	if (g_playerStates[eidx].didRtv) {
		g_PlayerFuncs.SayText(plr, "[RTV] You have already Rocked the Vote!\n");
		return;
	}
	
	g_playerStates[eidx].didRtv = true;
	
	if (getCurrentRtvCount() >= getRequiredRtvCount()) {
		startVote();
	} else {
		sayRtvCount();
	}
}

void sayRtvCount() {
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] " + getCurrentRtvCount() + " of " + getRequiredRtvCount() + " players until vote initiates!\n");
}

void cancelRtv(CBasePlayer@ plr) {
	if (!g_voteInProgress) {
		g_PlayerFuncs.SayText(plr, "[RTV] There is no vote to cancel.\n");
		return;
	}
	
	g_voteInProgress = false;
	g_voteEnded = false;
	for (uint i = 0; i < g_playerStates.size(); i++) {
		g_playerStates[i].didRtv = false;
		g_playerStates[i].voteOption = 0;
	}
	
	@g_rtvMenu = CTextMenu(@rtvMenuCallback);
	g_rtvMenu.SetTitle("\\yVote cancelled...");
	g_rtvMenu.AddItem(" ", any(""));
	g_rtvMenu.Register();

	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);

		if (p !is null) {
			g_rtvMenu.Open(2, 0, p);
		}
	}
	
	g_PlayerFuncs.SayTextAll(plr, "[RTV] The vote has been cancelled by " + plr.pev.netname + "!\n");
}

// returns number of maps needed to play before it can be nom'd
int getMapExcludeTime(string mapname, bool printMessage=false, CBasePlayer@ plr=null) {
	//if (g_previousMaps.find(mapname) >= 0) {
	if (g_prevMapPosition.exists(mapname)) {
		int lastPrevIdx = 0;
		g_prevMapPosition.get(mapname, lastPrevIdx);
		
		bool isMemeMap = g_memeMapsHashed.exists(mapname);
		int mapsAgo = g_previousMaps.size() - lastPrevIdx;

		if (isMemeMap && mapsAgo < g_ExcludePrevMapsNomMeme.GetInt()) {
			int leftToPlay = (g_ExcludePrevMapsNomMeme.GetInt() - mapsAgo) + 1;
			if (printMessage) {
				g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluded until " + leftToPlay + " other nom-able maps have been played with 4+ players (see .pastmaplistfull).\n");
			}
			return leftToPlay;
		}
		else if (!isMemeMap && mapsAgo < g_ExcludePrevMapsNom.GetInt()) {
			int leftToPlay = (g_ExcludePrevMapsNom.GetInt() - mapsAgo) + 1;
			if (printMessage) {
				g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluded until " + leftToPlay + " other nom-able maps have been played with 4+ players (see .pastmaplist).\n");
			}
			return leftToPlay;
		}
	}
	
	return 0;
}

void nomMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected() or g_voteEnded or g_voteInProgress) {
		return;
	}

	string nomChoice;
	item.m_pUserData.retrieve(nomChoice);
	tryNominate(plr, nomChoice);
}

bool tryNominate(CBasePlayer@ plr, string mapname) {
	if (g_voteInProgress || g_voteEnded) {
		return false;
	}

	bool dontAutoNom = int(mapname.Find("*")) != -1; // player just wants to search for maps with this string
	mapname.Replace("*", "");
	bool fullNomMenu = mapname.Length() == 0;

	if (fullNomMenu || dontAutoNom || (g_normalMaps.find(mapname) < 0 && g_hiddenMaps.find(mapname) < 0)) {
		array<string> similarNames;
		
		if (fullNomMenu) {
			similarNames = g_everyMap;
		}
		else {
			for (uint i = 0; i < g_everyMap.size(); i++) {
				if (int(g_everyMap[i].Find(mapname)) != -1) {
					similarNames.insertLast(g_everyMap[i]);
				}
			}
		}
		
		if (similarNames.size() > 1) {
			int eidx = plr.entindex();
			
			@g_nomMenus[eidx] = CTextMenu(@nomMenuCallback);
			
			string title = "\\yMaps containing \"" + mapname + "\"   ";
			if (fullNomMenu) {
				title = "\\yNominate...   ";
			}
			g_nomMenus[eidx].SetTitle(title);
			
			for (uint i = 0; i < similarNames.size(); i++) {
				string label = similarNames[i] + "\\y";
				
				int mapsLeft = getMapExcludeTime(similarNames[i]);
				if (mapsLeft > 0) {
					label = "\\r" + label + "   \\d(" + mapsLeft + ")\\y";
				} else {
					label = "\\w" + label;
				}
				
				g_nomMenus[eidx].AddItem(label, any(similarNames[i]));
			}
			
			if (!(g_nomMenus[eidx].IsRegistered()))
				g_nomMenus[eidx].Register();
				
			g_nomMenus[eidx].Open(0, 0, plr);
		}
		else if (similarNames.size() == 1) {
			tryNominate(plr, similarNames[0]);
		}
		else {
			g_PlayerFuncs.SayText(plr, "[RTV] No maps containing \"" + mapname + "\" exist.");
		}
		
		return false;
	}
	
	if (getMapExcludeTime(mapname, true, plr) > 0) {
		return false;
	}
	
	if (g_nomList.find(mapname) != -1) {
		g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" has already been nominated.\n");
		return false;
	}
	
	if (int(g_nomList.size()) >= g_MaxMapsToVote.GetInt()) {
		g_PlayerFuncs.SayText(plr, "[RTV] The max number of nominations has been reached!\n");
		return false;
	}
	
	int eidx = plr.entindex();
	string oldNomMap = g_playerStates[eidx].nom;
	g_playerStates[eidx].nom = mapname;
	
	g_nomList.insertLast(mapname);
	
	if (oldNomMap.IsEmpty()) {
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " has nominated \"" + mapname + "\".\n");
	} else {
		g_nomList.removeAt(g_nomList.find(oldNomMap));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " has changed their nomination to \"" + mapname + "\".\n");
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
			msg += g_everyMap[i + k];
			int padding = (g_maxNomMapNameLength + 1) - g_everyMap[i + k].Length();
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
       g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + ((i-start) + 1) +  ": "  + g_previousMaps[i] + "\n");
    }
    g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "-----------------------------\n");
}

void sendPastMapList_full(CBasePlayer@ plr) {
    g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "--Past maplist---------------\n");
    for (uint i = 0; i < g_previousMaps.length(); i++) {
       g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + (i + 1) +  ": "  + g_previousMaps[i] + "\n");
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
	g_randomMapChoices.resize(0);
	
	for (uint i = 0; i < g_normalMaps.size(); i++) {
        g_everyMap.insertLast(g_normalMaps[i]);
		
        if (g_normalMaps[i].Length() > g_maxNomMapNameLength) {
            g_maxNomMapNameLength = g_normalMaps[i].Length();
        }
		if (!g_prevMapPosition.exists(g_normalMaps[i])) {
			g_randomMapChoices.insertLast(g_normalMaps[i]);
		}
    }

    for (uint i = 0; i < g_hiddenMaps.size(); i++) {
        g_everyMap.insertLast(g_hiddenMaps[i]);
		g_memeMapsHashed[g_hiddenMaps[i]] = true;
		
        if (g_hiddenMaps[i].Length() > g_maxNomMapNameLength) {
            g_maxNomMapNameLength = g_hiddenMaps[i].Length();
        }
    }

    g_everyMap.sortAsc();
}

void writePreviousMapsList() {
    string mapname = string(g_Engine.mapname).ToLowercase();

    if (g_PlayerFuncs.GetNumPlayers() < 4 && false) {
        g_Log.PrintF("[RTV] Not writing previous map - less than 4 players\n");
        return;
    }
    if (g_normalMaps.find(mapname) < 0 && g_hiddenMaps.find(mapname) < 0) {
        g_Log.PrintF("[RTV] Not writing previous map - " + mapname + " not in vote list(s)\n");
        return; // prevent maps in a series from being added to the list
    }

    if (g_lastMapName == mapname) {
        g_Log.PrintF("[RTV] Not writing previous map - restarts are not counted\n");
        return; // don't count map restarts
    }
    g_lastMapName = mapname;

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




int doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	int eidx = plr.entindex();
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == "rtv") {
			tryRtv(plr);
			return 1;
		}
		else if (args[0] == "unrtv") {
			if (g_voteInProgress || g_voteEnded) {
				g_PlayerFuncs.SayText(plr, "[RTV] Too late for that now!\n");
			}
			else if (g_playerStates[eidx].didRtv) {
				g_playerStates[eidx].didRtv = false;
				sayRtvCount();
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] You haven't Rocked the Vote yet!\n");
			}
			return 1;
		}
		else if (args[0] == "nom" || args[0] == "nominate") {
			string mapname = args.ArgC() >= 2 ? args[1].ToLowercase() : "";
			tryNominate(plr, mapname);
			return 2;
		}
		else if (args[0] == "unnom") {
			RtvState@ state = g_playerStates[plr.entindex()];
			if (g_voteInProgress || g_voteEnded) {
				g_PlayerFuncs.SayText(plr, "[RTV] Too late for that now!\n");
			}
			else if (state.nom.Length() > 0) {
				g_nomList.removeAt(g_nomList.find(state.nom));
				g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " has revoked their \"" + state.nom + "\" nomination.\n");
				state.nom = "";
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] You haven't nominated anything yet!\n");
			}
			return 2;
		}
		else if (args[0] == "maplist" || args[0] == "listmaps") {
			sendMapList(plr);
			return 1;
		}
		else if (args[0] == ".pastmaplist") {
			sendPastMapList(plr);
			return 2;
		}
		else if (args[0] == ".pastmaplistfull") {
			sendPastMapList_full(plr);
			return 2;
		}
		else if (isAdmin && args[0] == ".forcertv") {
			g_PlayerFuncs.SayTextAll(plr, "[RTV] A vote has been forced by " + plr.pev.netname + "!\n");
			startVote();
			return 2;
		}
		else if (isAdmin && args[0] == ".cancelrtv") {
			cancelRtv(plr);
			return 2;
		}
		else if (isAdmin && args[0] == ".set_nextmap") {
			if (args.ArgC() < 2) {
				g_PlayerFuncs.SayText(plr, "Usage: .set_nextmap <mapname>\n");
				return 2;
			}
			
			string nextmap = args[1];
			if (!g_EngineFuncs.IsMapValid(nextmap)) {
				g_PlayerFuncs.SayText(plr, nextmap + " does not exist!\n");
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
	
	return 0;
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	int chatHandled = doCommand(plr, args, false);
	
	if (chatHandled > 0)
	{
		if (chatHandled == 2)
			pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {
	RtvState@ state = g_playerStates[plr.entindex()];
	state.didRtv = false;
	state.nom = "";
	state.voteOption = 0;
	
	if (g_voteInProgress) {
		updateVoteMenu();
	}
	else if (!g_voteEnded) {
		if (getCurrentRtvCount() >= getRequiredRtvCount()) {
			startVote();
		} else if (getCurrentRtvCount() > 0) {
			sayRtvCount();
		}
	}
	
	return HOOK_CONTINUE;
}

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}