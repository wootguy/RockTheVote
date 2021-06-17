MenuVote::MenuVote g_gameVote;
float g_lastGameVote = 0;
string g_lastVoteStarter; // used to prevent a single player from spamming votes by doubling their cooldown

const int VOTE_FAILS_UNTIL_BAN = 2; // if a player keeps starting votes that fail, they're banned from starting more votes
const int VOTE_FAIL_IGNORE_TIME = 60; // number of minutes to remember failed votes
const int VOTING_BAN_DURATION = 24*60; // number of minutes a ban lasts (banned from starting votes, not from the server)
const int GLOBAL_VOTE_COOLDOWN = 5; // just enough time to read results of the previous vote.
const int RESTART_MAP_PERCENT_REQ = 75;

class PlayerVoteState
{
	array<DateTime> failedVoteTimes; // times that this player started a vote which failed
	DateTime voteBanExpireTime;
	bool isBanned = false;
	int killedCount = 0; // kill for longer duration if keep getting votekilled
	DateTime nextVoteAllow = DateTime(); // next time this player can start a vote
	
	PlayerVoteState() {}
	
	void handleVoteFail() {		
		// clear failed votes from long ago
		for (int i = int(failedVoteTimes.size())-1; i >= 0; i--) {
			int diff = int(TimeDifference(DateTime(), failedVoteTimes[i]).GetTimeDifference());
			
			if (diff > VOTE_FAIL_IGNORE_TIME*60) {
				failedVoteTimes.removeAt(i);
			}
		}
		
		failedVoteTimes.insertLast(DateTime());
		
		// this player wasted other's time. Punish.
		nextVoteAllow = DateTime() + TimeDifference(g_EngineFuncs.CVarGetFloat("mp_playervotedelay"));
		
		if (failedVoteTimes.size() >= VOTE_FAILS_UNTIL_BAN) {
			// player continues to start votes that fail. REALLY PUNISH.
			isBanned = true;
			failedVoteTimes.resize(0);
			voteBanExpireTime = DateTime() + TimeDifference(VOTING_BAN_DURATION*60);
		}
	}
	
	void handleVoteSuccess() {
		// player knows what the people want. Keep it up! But give someone else a chance to start a vote
		nextVoteAllow = DateTime() + TimeDifference(GLOBAL_VOTE_COOLDOWN*2);
		failedVoteTimes.resize(0);
	}
}

void reduceKillPenalties() {
	array<string>@ state_keys = g_voting_ban_states.getKeys();
	
	for (uint i = 0; i < state_keys.length(); i++)
	{
		PlayerVoteState@ state = cast<PlayerVoteState@>(g_voting_ban_states[state_keys[i]]);
		if (state.killedCount > 0) {
			state.killedCount -= 1;
		}
	}
}

dictionary g_voting_ban_states;

PlayerVoteState getPlayerVoteState(string steamId) {	
	if ( !g_voting_ban_states.exists(steamId) )
	{
		PlayerVoteState state;
		g_voting_ban_states[steamId] = state;
	}
	
	return cast<PlayerVoteState@>( g_voting_ban_states[steamId] );
}

string getPlayerUniqueId(CBasePlayer@ plr) {	
	string steamId = g_EngineFuncs.GetPlayerAuthId( plr.edict() );
	
	if (steamId == 'STEAM_ID_LAN') {
		steamId = plr.pev.netname;
	}
	
	return steamId;
}

CBasePlayer@ findPlayer(string uniqueId) {
	CBasePlayer@ target = null;
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (getPlayerUniqueId(plr) == uniqueId) {
			@target = @plr;
			break;
		}
	}
	
	return target;
}

void optionChosenCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, CBasePlayer@ plr) {
	if (chosenOption !is null) {
		if (chosenOption.label == "\\d(exit)") {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Say \".vote\" to reopen the menu\n");
			voteMenu.closeMenu(plr);
		}
		else {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Voted " + chosenOption.label + "\n\nSay \".vote\" to reopen the menu\n");
		}
	}
}

string yesVoteFailStr(int got, int req) {
	if (got > 0) {
		return "(" + got + "%% voted yes but " + req + "%% is required)";
	}
	
	return "(nobody voted yes)";
}

void voteKillFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {
	array<string> parts = chosenOption.value.Split("\\");
	string name = parts[1];
	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);
	
	if (chosenOption.label == "No") {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
		int got = voteMenu.getOptionVotePercent("Yes");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + name + "\" failed " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	} else {
		string steamId = parts[0];
		CBasePlayer@ target = findPlayer(steamId);
		PlayerVoteState@ victimState = getPlayerVoteState(getPlayerUniqueId(target));
		string victimName = steamId;
		
		int killTime = 30;
		string timeStr = "30 seconds";
		
		if (victimState.killedCount >= 3) {
			killTime = 60*5;
			timeStr = "5 minutes";
		}
		else if (victimState.killedCount >= 2) {
			killTime = 60*2;
			timeStr = "2 minutes";
		} else if (victimState.killedCount >= 1) {
			killTime = 60;
			timeStr = "1 minute";
		}
		
		if (target !is null) {
			if (target.IsAlive()) {
				g_EntityFuncs.Remove(target);
			}
			target.m_flRespawnDelayTime = killTime;
			victimName = target.pev.netname;
		}
		
		voterState.handleVoteSuccess();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote killing \"" + victimName + "\" for " + timeStr + ".\n");
		keep_votekilled_player_dead(steamId, victimName, DateTime(), killTime);
		victimState.killedCount += 1;
	}
}

void keep_votekilled_player_dead(string targetId, string targetName, DateTime killTime, int killDuration) {
	int diff = int(TimeDifference(DateTime(), killTime).GetTimeDifference());
	
	if (diff > killDuration) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votekill expired for \"" + targetName + "\".\n");
		return;
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}

		string steamId = getPlayerUniqueId( plr );
		
		if (steamId == targetId) {
			if (plr.IsAlive()) {
				g_EntityFuncs.Remove(plr);
				plr.m_flRespawnDelayTime = killDuration - diff;
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Killing \"" + plr.pev.netname + "\" again. " + int(plr.m_flRespawnDelayTime) + " seconds left in votekill penalty.\n");
			}
			
		}
	}
	
	g_Scheduler.SetTimeout("keep_votekilled_player_dead", 1, targetId, targetName, killTime, killDuration);
}

void survivalVoteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);

	if (chosenOption.value == "enable" || chosenOption.value == "disable") {
		voterState.handleVoteSuccess();
		
		if (chosenOption.value == "enable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to enable survival mode passed.\n");
			g_SurvivalMode.VoteToggle();
		} else if (chosenOption.value == "disable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to disable survival mode passed.\n");
			g_SurvivalMode.VoteToggle();
		}
	}
	else {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
		int got = voteMenu.getOptionVotePercent("Yes");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to toggle survival mode failed " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	}
}

void restartVoteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);

	if (chosenOption.label == "Yes") {
		voterState.handleVoteSuccess();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to restart map passed. Restarting in 5 seconds.\n");
		@g_timer = g_Scheduler.SetTimeout("change_map", MenuVote::g_resultTime + (5-MenuVote::g_resultTime), "" + g_Engine.mapname);
	}
	else {
		int required = RESTART_MAP_PERCENT_REQ;
		int got = voteMenu.getOptionVotePercent("Yes");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to restart map failed " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	}
}

void gameVoteMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	string option;
	item.m_pUserData.retrieve(option);
	
	if (option == "kill") {
		g_Scheduler.SetTimeout("openVoteKillMenu", 0.0f, EHandle(plr));
	} else if (option == "survival") {
		g_Scheduler.SetTimeout("tryStartSurvivalVote", 0.0f, EHandle(plr));
	} else if (option == "restartmap") {
		g_Scheduler.SetTimeout("tryStartRestartVote", 0.0f, EHandle(plr));
	}
}

void voteKillMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	string option;
	item.m_pUserData.retrieve(option);
	
	g_Scheduler.SetTimeout("tryStartVotekill", 0.0f, EHandle(plr), option);
}

void openGameVoteMenu(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	@g_menus[eidx] = CTextMenu(@gameVoteMenuCallback);
	g_menus[eidx].SetTitle("\\yVote Menu");
	
	string killReq = "\\d(" + int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired")) + "% needed)";
	string survReq = "\\d(" + int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired")) + "% needed)";
	string restartReq = "\\d(" + RESTART_MAP_PERCENT_REQ + "% needed)";
	
	g_menus[eidx].AddItem("\\wKill Player " + killReq + "\\y", any("kill"));
	
	bool canVoteSurvival = g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") != 0 &&
						   g_EngineFuncs.CVarGetFloat("mp_survival_supported") != 0;
	g_menus[eidx].AddItem((canVoteSurvival ? "\\w" : "\\r") + "Toggle Survival " + survReq + "\\y", any("survival"));
	g_menus[eidx].AddItem((g_SurvivalMode.IsActive() ? "\\w" : "\\r") + "Restart Map " + restartReq + "\\y", any("restartmap"));
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, plr);
}

void openVoteKillMenu(EHandle h_plr) {
	CBasePlayer@ user = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (user is null) {
		return;
	}
	
	int eidx = user.entindex();
	
	array<MenuOption> targets;
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (!plr.IsAlive()) {
			continue;
		}
		
		MenuOption option;
		option.label = "\\w" + plr.pev.netname;
		option.value = getPlayerUniqueId(plr);
		targets.insertLast(option);
	}
	
	if (targets.size() == 0) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[Vote] Can't vote kill. No one is alive.\n");
	}
	
	targets.sort(function(a,b) { return a.label > b.label; });
	
	@g_menus[eidx] = CTextMenu(@voteKillMenuCallback);
	g_menus[eidx].SetTitle("\\yKill who?   ");
	
	for (uint i = 0; i < targets.size(); i++) {
		g_menus[eidx].AddItem(targets[i].label + "\\y", any(targets[i].value));
	}
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, user);
}

bool tryStartGameVote(CBasePlayer@ plr) {
	if (g_rtvVote.status != MVOTE_NOT_STARTED or g_gameVote.status == MVOTE_IN_PROGRESS) {
		g_PlayerFuncs.SayText(plr, "[Vote] Another vote is already in progress.\n");
		return false;
	}
	
	// global cooldown
	float voteDelta = g_Engine.time - g_lastGameVote;
	float cooldown = GLOBAL_VOTE_COOLDOWN;
	if (g_lastGameVote > 0 and voteDelta < cooldown) {
		g_PlayerFuncs.SayText(plr, "[Vote] Wait " + int((cooldown - voteDelta) + 0.99f) + " seconds before starting another vote.\n");
		return false;
	}
	
	// player-specific cooldown
	PlayerVoteState@ voterState = getPlayerVoteState(getPlayerUniqueId(plr));
	int nextVoteDelta = int(TimeDifference(voterState.nextVoteAllow, DateTime()).GetTimeDifference());
	if (nextVoteDelta > 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Wait " + int(nextVoteDelta + 0.99f) + " seconds before starting another vote.\n");
		return false;
	}
	
	if (voterState.isBanned) {
		int diff = int(TimeDifference(voterState.voteBanExpireTime, DateTime()).GetTimeDifference());
		if (diff > 0) {
			string timeleft = "" + ((diff + 59) / 60) + " minutes";
			if (diff > 60) {
				timeleft = "" + ((diff + 3599) / (60*60)) + " hours";
			}
			g_PlayerFuncs.SayText(plr, "[Vote] You've started too many votes which failed. Wait " + timeleft + " before starting another vote.\n");
			return false;
		} else {
			voterState.isBanned = false;
		}
	}
	
	
	return true;
}

void tryStartVotekill(EHandle h_plr, string uniqueId) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null) {
		return;
	}
	
	if (!tryStartGameVote(plr)) {
		return;
	}
	
	CBasePlayer@ target = findPlayer(uniqueId);
	
	if (target is null) {
		g_PlayerFuncs.SayTextAll(plr, "[Vote] Player not found.\n");
		return;
	}	
	
	array<MenuOption> options = {
		MenuOption("Yes", uniqueId + "\\" + target.pev.netname),
		MenuOption("No", uniqueId + "\\" + target.pev.netname),
		MenuOption("\\d(exit)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = "Kill \"" + target.pev.netname + "\"?";
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
	@voteParams.finishCallback = @voteKillFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastGameVote = g_Engine.time;
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + target.pev.netname + "\" started by \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartSurvivalVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null or !tryStartGameVote(plr)) {
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_supported") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Survival mode is not supported on this map.\n");
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Survival votes are disabled");
		return;
	}
	
	bool survivalEnabled = g_SurvivalMode.IsEnabled();
	string title = (survivalEnabled ? "Disable" : "Enable") + " survival mode?   ";
	
	array<MenuOption> options = {
		MenuOption("Yes", survivalEnabled ? "disable" : "enable"),
		MenuOption("No", "no"),
		MenuOption("\\d(exit)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = title;
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
	@voteParams.finishCallback = @survivalVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastGameVote = g_Engine.time;
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	string enableDisable = survivalEnabled ? "disable" : "enable";
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to " + enableDisable + " survival mode started by \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartRestartVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null or !tryStartGameVote(plr)) {
		return;
	}
	
	if (!g_SurvivalMode.IsActive()) {
		g_PlayerFuncs.SayText(plr, "[Vote] Restarts are only allowed during survival.\n");
		return;
	}
	
	array<MenuOption> options = {
		MenuOption("Yes", "yes"),
		MenuOption("No", "no"),
		MenuOption("\\d(exit)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = "Restart map?";
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = RESTART_MAP_PERCENT_REQ;
	@voteParams.finishCallback = @restartVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastGameVote = g_Engine.time;
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to restart map started by \"" + plr.pev.netname + "\".\n");
	
	return;
}

int doGameVote(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == ".vote") {
			if (g_EnableGameVotes.GetInt() == 0) {
				g_PlayerFuncs.SayText(plr, "[Vote] Command disabled.\n");
				return 2;
			}
			
			if (g_gameVote.status == MVOTE_IN_PROGRESS) {
				g_gameVote.reopen(plr);
				return 2;
			}
			
			if (tryStartGameVote(plr)) {
				openGameVoteMenu(plr);
			}
			
			return 2;
		}
	}
	
	return 0;
}