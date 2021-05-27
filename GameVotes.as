MenuVote::MenuVote g_gameVote;
float g_lastGameVote = 0;
string g_lastVoteStarter; // used to prevent a single player from spamming votes by doubling their cooldown

const int VOTE_FAILS_UNTIL_BAN = 2; // if a player keeps starting votes that fail, they're banned from starting more votes
const int VOTE_FAIL_IGNORE_TIME = 60; // number of minutes to remember failed votes
const int VOTING_BAN_DURATION = 24*60; // number of minutes a ban lasts (banned from starting voties, not from the server)

class PlayerVoteState
{
	array<DateTime> failedVoteTimes; // times that this player started a vote which failed
	DateTime voteBanExpireTime;
	bool isBanned = false;
	
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
		
		if (failedVoteTimes.size() >= VOTE_FAILS_UNTIL_BAN) {
			// player keeps starting votes that not enough people agree with. Stop it.
			isBanned = true;
			failedVoteTimes.resize(0);
			voteBanExpireTime = DateTime() + TimeDifference(VOTING_BAN_DURATION*60);
		}
	}
	
	void handleVoteSuccess() {
		failedVoteTimes.resize(0); // player must not be spamming, if others want the same thing they do
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
		CBasePlayer@ target = findPlayer(parts[0]);
		if (target !is null) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote killing \"" + name + "\".\n");			
			string steamId = getPlayerUniqueId( target );
			
			if (target.IsAlive()) {
				g_EntityFuncs.Remove(target);
			}
			target.m_flRespawnDelayTime = g_EngineFuncs.CVarGetFloat("mp_votekill_respawndelay");
			
			keep_votekilled_player_dead(steamId, DateTime());
			voterState.handleVoteSuccess();
		} else {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote to kill \"" + name + "\" failed (player not found).\n");
		}
	}
}

void keep_votekilled_player_dead(string targetId, DateTime killTime) {
	int diff = int(TimeDifference(DateTime(), killTime).GetTimeDifference());
	
	if (diff > g_EngineFuncs.CVarGetFloat("mp_votekill_respawndelay")) {
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
				plr.m_flRespawnDelayTime = g_EngineFuncs.CVarGetFloat("mp_votekill_respawndelay") - diff;
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Killing \"" + plr.pev.netname + "\" again. Votekill respawn delay not finished.\n");
			}
		}
	}
	
	g_Scheduler.SetTimeout("keep_votekilled_player_dead", 1, targetId, killTime);
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
	
	g_Scheduler.SetTimeout("tryStartVotekill", 0.0f, EHandle(plr), option);
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
		g_PlayerFuncs.SayText(plr, "[Vote] Another vote is already in progress.\n");
		return false;
	}
	
	float voteDelta = g_Engine.time - g_lastGameVote;
	float cooldown = g_EngineFuncs.CVarGetFloat("mp_votetimebetween");
	
	// prevent single voter spamming and preventing others from voting
	if (g_lastVoteStarter == getPlayerUniqueId(plr)) {
		cooldown = g_EngineFuncs.CVarGetFloat("mp_playervotedelay");
	}
	
	if (g_lastGameVote > 0 and voteDelta < cooldown) {
		g_PlayerFuncs.SayText(plr, "[Vote] Wait " + int((cooldown - voteDelta) + 0.99f) + " seconds before starting another vote.\n");
		return false;
	}
	
	PlayerVoteState@ voterState = getPlayerVoteState(getPlayerUniqueId(plr));
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
	if (plr is null) {
		return;
	}
	
	if (!tryStartGameVote(plr)) {
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