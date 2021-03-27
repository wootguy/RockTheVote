MenuVote::MenuVote g_gameVote;
float g_lastGameVote = 0;
string g_lastVoteStarter; // used to prevent a single player from spamming votes by doubling their cooldown

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

void optionChosenCallback(MenuOption chosenOption, CBasePlayer@ plr) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Voted " + chosenOption.label + "\n\nSay \".vote\" to reopen the menu.\n");
}

void voteKillFinishCallback(MenuOption chosenOption, int resultReason) {
	array<string> parts = chosenOption.value.Split("\\");
	string name = parts[1];
	
	if (chosenOption.label == "No") {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + name + "\" failed (" + required + "%% required).\n");
	} else {
		CBasePlayer@ target = findPlayer(parts[0]);
		if (target !is null) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote killing \"" + name + "\".\n");
			if (target.IsAlive()) {
				g_EntityFuncs.Remove(target);
			}
			target.m_flRespawnDelayTime = g_EngineFuncs.CVarGetFloat("mp_votekill_respawndelay");
			
		} else {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + name + "\" failed (player not found).\n");
		}
	}
}

void survivalVoteFinishCallback(MenuOption chosenOption, int resultReason) {	
	if (chosenOption.value == "enable") {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to enable survival mode passed.\n");
		g_SurvivalMode.VoteToggle();
	} else if (chosenOption.value == "disable") {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to disable survival mode passed.\n");
		g_SurvivalMode.VoteToggle();
	} else {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to toggle survival mode failed (" + required + "%% required).\n");
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
	}
}

void voteKillMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	string option;
	item.m_pUserData.retrieve(option);
	
	tryStartVotekill(plr, option);
}

void openGameVoteMenu(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	@g_menus[eidx] = CTextMenu(@gameVoteMenuCallback);
	g_menus[eidx].SetTitle("\\yVote Menu");
	
	g_menus[eidx].AddItem("\\wKill Player\\y", any("kill"));
	
	bool canVoteSurvival = g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") != 0 &&
						   g_EngineFuncs.CVarGetFloat("mp_survival_supported") != 0;
	g_menus[eidx].AddItem((canVoteSurvival ? "\\w" : "\\r") + "Toggle Survival\\y", any("survival"));
	
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
		
		if (g_SurvivalMode.IsEnabled() && !plr.IsAlive()) {
			continue;
		}
		
		MenuOption option;
		option.label = "\\w" + plr.pev.netname;
		option.value = getPlayerUniqueId(plr);
		targets.insertLast(option);
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
		g_PlayerFuncs.SayText(plr, "[Vote] Another vote is already in progress.");
		return false;
	}
	
	float voteDelta = g_Engine.time - g_lastGameVote;
	float cooldown = g_EngineFuncs.CVarGetFloat("mp_votetimebetween");
	
	// prevent single voter spamming and preventing others from voting
	if (g_lastVoteStarter == getPlayerUniqueId(plr)) {
		cooldown *= 2;
	}
	
	if (g_lastGameVote > 0 and voteDelta < cooldown) {
		g_PlayerFuncs.SayText(plr, "[Vote] Wait " + int((cooldown - voteDelta) + 0.99f) + " seconds before starting another vote.");
		return false;
	}
	
	return true;
}

void tryStartVotekill(CBasePlayer@ plr, string uniqueId) {
	if (!tryStartGameVote(plr)) {
		return;
	}
	
	CBasePlayer@ target = findPlayer(uniqueId);
	
	if (target is null) {
		g_PlayerFuncs.SayTextAll(plr, "[Vote] Player not found.");
		return;
	}
	
	array<MenuOption> options = {
		MenuOption("Yes", uniqueId + "\\" + target.pev.netname),
		MenuOption("No", uniqueId + "\\" + target.pev.netname)
	};
	
	MenuVoteParams voteParams;
	voteParams.title = "Kill \"" + target.pev.netname + "\"?";
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
	@voteParams.finishCallback = @voteKillFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams);
	
	g_lastGameVote = g_Engine.time;
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + target.pev.netname + "\" started by \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartSurvivalVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null) {
		return;
	}
	
	if (!tryStartGameVote(plr)) {
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_supported") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Survival mode is not supported on this map");
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
		MenuOption("No", "no")
	};
	
	MenuVoteParams voteParams;
	voteParams.title = title;
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
	@voteParams.finishCallback = @survivalVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams);
	
	g_lastGameVote = g_Engine.time;
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	string enableDisable = survivalEnabled ? "disable" : "enable";
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to " + enableDisable + " survival mode started by \"" + plr.pev.netname + "\".\n");
	
	return;
}

int doGameVote(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == ".vote") {
			if (g_EnableGameVotes.GetInt() == 0) {
				g_PlayerFuncs.SayText(plr, "[Vote] Command disabled.");
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