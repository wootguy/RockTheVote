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
	MVOTE_RESULT_NO_VOTES		// option was randomly chosen because no one voted
}

funcdef void MenuVoteFinishCallback(string, int);
funcdef void MenuVoteThinkCallback(int);

class MenuVoteParams {
	string title = "Vote";
	array<string> options;
	int voteTime = 10;
	
	MenuVoteThinkCallback@ thinkCallback = null;
	MenuVoteFinishCallback@ finishCallback = null;
}

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
	
	private int secondsLeft;
	private string selectedOption;
	private int blinkTime = 0;
	
	MenuVote() {}
	
	void reset() {
		playerVotes.resize(0);
		playerVotes.resize(33);
		status = MVOTE_NOT_STARTED;
		blinkTime = 0;
		selectedOption = "";
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
		update();
	}
	
	void handlePlayerLeave(CBasePlayer@ plr) {
		playerVotes[plr.entindex()] = 0;
		update();
	}
	
	void update() {
		@voteMenu = CTextMenu(@voteMenuCallback);
		voteMenu.SetTitle("\\y" + voteParams.title);
		
		int bestVotes = getHighestVotecount();
		bool anyoneVoted = bestVotes > -1;
		bool shouldBlinkSelectedOption = status == MVOTE_FINISHED && (blinkTime++ % 2 == 0);
		
		for (uint i = 0; i < voteParams.options.length(); i++) {
			int voteCount = 0;
			int thisOption = i+1;
			
			for (uint k = 0; k < playerVotes.size(); k++) {
				voteCount += (playerVotes[k] == thisOption) ? 1 : 0;
			}
			
			string label = voteParams.options[i];
			bool blinkThisOption = shouldBlinkSelectedOption && selectedOption == label;
			
			if (voteCount > 0 || blinkThisOption) {
				if (blinkThisOption) {
					label = "\\d" + label;
				} else if (voteCount == bestVotes) {
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
				voteMenu.Open(0, 0, plr);
			}
		}
	}
	
	void reopen(CBasePlayer@ plr) {
		voteMenu.Open(0, 0, plr);
	}
	
	void cancel() {
		@voteMenu = CTextMenu(@voteMenuCallback);
		voteMenu.SetTitle("\\yVote cancelled...");
		voteMenu.AddItem(" ", any(""));
		voteMenu.Register();

		for (int i = 1; i <= g_Engine.maxClients; i++) {
			CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);

			if (p !is null) {
				voteMenu.Open(2, 0, p);
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
		array<string> bestOptions;
		
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
		
		// blink the selected option
		int b = 0;
		for (float d = 0; d < g_resultTime; d += 0.25f) {
			//g_Scheduler.SetTimeout("updateVoteMenu", d, b++ % 2 == 0 ? selectedOption : "");
			g_Scheduler.SetTimeout("voteThink", d);
		}
		playSoundGlobal("buttons/blip3.wav", 1.0f, 70);
		
		status = MVOTE_FINISHED;
		
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTCENTER, "");
		
		if (voteParams.finishCallback !is null) {
			voteParams.finishCallback(selectedOption, selectReason);
		}
	}
}

}