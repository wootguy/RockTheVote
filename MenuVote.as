//
// Helper class for creating custom votes
//

enum MENU_VOTE_STATES {
	MVOTE_NOT_STARTED,
	MVOTE_IN_PROGRESS,
	MVOTE_FINISHED
}

// reason an option was chosen
enum MENU_VOTE_RESULT_REASONS {
	MVOTE_RESULT_NORMAL,		// option was chosen because it had the most votes
	MVOTE_RESULT_TIED,			// option was randomly chosen between tied options
	MVOTE_RESULT_NO_VOTES,		// option was randomly chosen because no one voted
	MVOTE_RESULT_PERCENT_FAIL,	// vote failed because no option had the percentage of votes required
}

funcdef void MenuVoteFinishCallback(MenuOption chosenOption, int resultReason);
funcdef void MenuVoteThinkCallback(int secondsLeft);
funcdef void MenuVoteOptionCallback(MenuOption chosenOption, CBasePlayer@ plr);

class MenuOption {
	string label;
	string value;
	
	MenuOption() {}
	
	MenuOption(string label) {
		this.label = label;
		this.value = label;
	}
	
	MenuOption(string label, string value) {
		this.label = label;
		this.value = value;
	}
}

class MenuVoteParams {
	string title = "Vote";					// Menu title
	array<MenuOption> options = {			// Custom options
		MenuOption("Yes"),
		MenuOption("No")
	};
	int voteTime = 10;						// Time in seconds to display the vote
	bool forceOpen = false;					// force the menu to stay open after the player votes
	
	int percentNeeded = -1;							// Percentage of votes needed for an option to be chosen (0-100)
	MenuOption percentFailOption = options[1];		// Default option chosen if no option has enough percentage of votes
	
	MenuVoteThinkCallback@ thinkCallback = null;
	MenuVoteFinishCallback@ finishCallback = null;		
	MenuVoteOptionCallback@ optionCallback = null;		
}

// Menus need to be defined globally when the plugin is loaded or else paging doesn't work.
// Each player needs their own menu or else paging breaks when someone else opens the menu.
// These also need to be modified directly (not via a local var reference).
array<CTextMenu@> g_menus = {
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null
};


namespace MenuVote
{

CScheduledFunction@ g_menuTimer = null;
MenuVote@ g_activeVote = null;
bool g_hooks_registered = false;

float g_resultTime = 1.5f;

void voteMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	int option = 0;
	item.m_pUserData.retrieve(option);
	
	// game crash if menu reopend on the same frame
	g_Scheduler.SetTimeout("handleVoteDelay", 0.0f, EHandle(plr), option);
}

void handleVoteDelay(EHandle h_plr, int option) {
	if (g_activeVote !is null and h_plr.IsValid()) {
		g_activeVote.handleVote(cast<CBasePlayer@>(h_plr.GetEntity()), option);
	}
}

void voteThink() {
	if (g_activeVote !is null) {
		g_activeVote.think();
	}
}

HookReturnCode MapChange() {
	g_Scheduler.RemoveTimer(g_menuTimer);
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {	
	if (g_activeVote !is null && g_activeVote.status == MVOTE_IN_PROGRESS) {
		g_activeVote.handlePlayerLeave(plr);
	}
	return HOOK_CONTINUE;
}

class MenuVote {
	int status = MVOTE_NOT_STARTED;
	
	private CTextMenu@ voteMenu;
	private MenuVoteParams voteParams;
	private array<int> playerVotes;
	private array<bool> playerWatching; // players who reopened the menu
	
	private int secondsLeft;
	private MenuOption selectedOption;
	private int blinkTime = 0;
	
	MenuVote() {}
	
	void reset() {
		playerVotes.resize(0);
		playerVotes.resize(33);
		playerWatching.resize(0);
		playerWatching.resize(33);
		status = MVOTE_NOT_STARTED;
		blinkTime = 0;
		selectedOption = MenuOption();
		g_Scheduler.RemoveTimer(g_menuTimer);
	}
	
	void start(MenuVoteParams voteParams) {
		this.voteParams = voteParams;

		if (!g_hooks_registered) {
			g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);
			g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientLeave);
			g_hooks_registered = true;
		}
		
		if (g_activeVote !is null) {
			g_activeVote.cancel();
		}
		
		reset();
		status = MVOTE_IN_PROGRESS;
		
		@g_activeVote = @this;
		
		update();
		secondsLeft = voteParams.voteTime;
		@g_menuTimer = g_Scheduler.SetTimeout("voteThink", 0.0f);
	}
	
	void handleVote(CBasePlayer@ plr, int option) {
		if (status != MVOTE_IN_PROGRESS) {
			return;
		}
		
		playerVotes[plr.entindex()] = option;
		playerWatching[plr.entindex()] = false;
		update();
		
		if (voteParams.optionCallback !is null) {
			voteParams.optionCallback(voteParams.options[option-1], plr);
		}
	}
	
	void handlePlayerLeave(CBasePlayer@ plr) {
		playerVotes[plr.entindex()] = 0;
		playerWatching[plr.entindex()] = false;
		update();
	}
	
	void update() {
		@voteMenu = CTextMenu(@voteMenuCallback);
		voteMenu.SetTitle("\\y" + voteParams.title);
		
		int bestVotes = getHighestVotecount();
		bool anyoneVoted = bestVotes > -1;
		bool shouldBlinkSelectedOption = status == MVOTE_FINISHED && (blinkTime++ % 2 == 0);
		
		bool percentBased = voteParams.percentNeeded >= 0;
		int totalVotes = getTotalVotes();
		
		for (uint i = 0; i < voteParams.options.length(); i++) {
			int thisOption = i+1;
			int voteCount = getOptionVotes(thisOption);
			
			string label = voteParams.options[i].label;
			bool blinkThisOption = shouldBlinkSelectedOption && selectedOption.label == label;
			int percent = getVotePercent(voteCount);
			bool isBestOption = percentBased ? (percent >= voteParams.percentNeeded) : (voteCount == bestVotes);
			
			if (percentBased) {
				label = (blinkThisOption ? "\\d" : "\\w") + label;
				
				if (voteCount > 0) {
					label += "  \\d(" + percent + "%)\\w";
				}
			}
			else if (voteCount > 0 || blinkThisOption) {
				if (blinkThisOption) {
					label = "\\d" + label;
				} else if (isBestOption) {
					label = "\\w" + label;
				} else {
					label = "\\r" + label;
				}
				label += "  \\d(" + voteCount + ")\\w";
			} else {
				label = (anyoneVoted ? "\\r" : "\\w") + label;
			}
			
			label += "\\y";
			
			voteMenu.AddItem(label, any(thisOption));
		}

		voteMenu.Register();

		for (int i = 1; i <= g_Engine.maxClients; i++) {
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);

			if (plr !is null and plr.IsConnected()) {
				int menuTime = status == MVOTE_FINISHED ? 1 : 0;
				if (isPlayerWatching(plr)) {
					voteMenu.Open(menuTime, 0, plr);
				}
			}
		}
	}
	
	bool isPlayerWatching(CBasePlayer@ plr) {
		return voteParams.forceOpen or playerVotes[plr.entindex()] == 0 or playerWatching[plr.entindex()];
	}
	
	void reopen(CBasePlayer@ plr) {
		voteMenu.Open(0, 0, plr);
		playerWatching[plr.entindex()] = true;
	}
	
	void cancel() {
		@voteMenu = CTextMenu(@voteMenuCallback);
		voteMenu.SetTitle("\\yVote cancelled...");
		voteMenu.AddItem(" ", any(""));
		voteMenu.Register();

		for (int i = 1; i <= g_Engine.maxClients; i++) {
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);

			if (plr !is null) {
				if (isPlayerWatching(plr)) {
					voteMenu.Open(2, 0, plr);
				}
			}
		}
		
		reset();
	}
	
	void think() {
		if (status == MVOTE_NOT_STARTED) {
			return; // cancelled
		}
		
		if (status == MVOTE_FINISHED) {
			update(); // blink the selected option
			
			if (voteParams.thinkCallback !is null) {
				voteParams.thinkCallback(0);
			}
			
			return;
		}
		
		if (secondsLeft == 0) {
			finishVote();
			return;
		}
		
		if (voteParams.thinkCallback !is null) {
			voteParams.thinkCallback(secondsLeft);
		}
		
		@g_menuTimer = g_Scheduler.SetTimeout("voteThink", 1.0f);
		secondsLeft--;
	}
	
	int getOptionVotes(int option) {
		int voteCount = 0;
		
		for (uint k = 0; k < playerVotes.size(); k++) {
			voteCount += (playerVotes[k] == option) ? 1 : 0;
		}
		
		return voteCount;
	}
	
	int getTotalVotes() {
		int voteCount = 0;
		
		for (uint k = 0; k < playerVotes.size(); k++) {
			voteCount += (playerVotes[k] != 0) ? 1 : 0;
		}
		
		return voteCount;
	}
	
	int getVotePercent(int votes) {
		int totalVotes = getTotalVotes();
		
		if (totalVotes == 0) {
			return 0;
		}
		
		return int((float(votes) / float(totalVotes))*100);
	}

	// return number of votes for the map with the most votes (for highlighting/tie-breaking)
	int getHighestVotecount() {
		int bestVotes = -1;
		for (uint i = 0; i < voteParams.options.length(); i++) {
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
	
	void finishVote() {
		array<MenuOption> bestOptions;
		
		int bestVotes = getHighestVotecount();	
		for (uint i = 0; i < voteParams.options.length(); i++) {
			int voteCount = getOptionVotes(i+1);
			
			if (voteCount >= bestVotes) {
				bestOptions.insertLast(voteParams.options[i]);
			}
		}
		
		selectedOption = bestOptions[0];
		int selectReason = MVOTE_RESULT_NORMAL;
		
		if (bestOptions.size() > 1) {
			selectedOption = bestOptions[Math.RandomLong(0, bestOptions.size()-1)];
			selectReason = bestVotes == -1 ? MVOTE_RESULT_NO_VOTES : MVOTE_RESULT_TIED;
		}
		
		if (voteParams.percentNeeded >= 0) {
			if (getVotePercent(bestVotes) < voteParams.percentNeeded) {
				selectedOption = voteParams.percentFailOption;
				selectReason = MVOTE_RESULT_PERCENT_FAIL;
			}
		}
		
		// blink the selected option
		int b = 0;
		for (float d = 0; d < g_resultTime; d += 0.25f) {
			g_Scheduler.SetTimeout("voteThink", d);
		}
		
		status = MVOTE_FINISHED;
		
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTCENTER, "");
		
		if (voteParams.finishCallback !is null) {
			voteParams.finishCallback(selectedOption, selectReason);
		}
	}
}

}