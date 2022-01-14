# RockTheVote
A rewrite of the [RockTheVote plugin by MrOats](https://github.com/MrOats/AngelScript_SC_Plugins/wiki/RockTheVote.as), with new features.  


This plugin will choose rarely played maps as the next map and as RTV menu options, depending on who is in the server. Maps also have cooldowns before they can be nominated again to prevent overplaying them. There are also text-menu alternatives to the built-in game votes. These are much less annoying as they don't take control of your mouse.

# Chat commands

Everyone can use these commands.

| Command | Description |
| --- | --- |
| rtv | Rock the vote! If a vote has already started, then this reopens the vote menu. |
| nom/nominate | Open the nomination menu. Maps that are colored red can't be nominated until other maps have been played (noted in paretheses next to the map name) |
| nom [map] | Nominate a map. `[map]` can be a partial map name (e.g. "coldburn" instead of "coldburn_beta123"). If multiple maps contain `[map]`, then a nomination menu will be opened so you can select which map you wanted. |
| nom [map]* | Search for a map without accidentally nominating one. |
| unnom/unom/denom | Undo your nomination. |
| listnom/lnom/nomlist/noms | List the current nominations. |
| maplist/listmaps | Get a list of all votable maps. |
| series? | Show how much progress has been made in the current map series. |

# Console commands

These commands also work in chat.

| Command | Admin only? | Description |
| --- | --- | --- |
| .forcertv | Yes | Force a map vote now. |
| .cancelrtv | Yes | Cancels an active map vote. |
| .map [map] | Yes | Force a map change. |
| .set_nextmap [map] | Yes | Set the next map for when the current map ends. This doesn't work for maps in a series (which use trigger_changelevel instead of game_end) |
| .mapstats [map] | No | Show previous play times for the current map or the specified map. |
| .newmaps [player] | No | Show a list of maps that were not played in a long time. Player name is optional and can be a steam id or '\all' for all players. Add '\cycle' as an arugment to show only maps in the map cycle. |
| .recentmaps [player] | No | Show list of maps that were played recently. Player name is optional and can be a steam id or '\all' for all players. |
| .vote | No | Open the vote menu (requires `rtv.gameVotes 1` CVar). |

# CVars
| CVar | Description |
| --- | --- |
| secondsUntilVote | Prevents rtv'ing until this many seconds after the map starts (without this a single person could start a vote before anyone else joins). |
| iMaxMaps | The max number of maps shown in the vote menu. 8 is the maximum. |
| secondsToVote | How long the vote menu will be shown. |
| iPercentReq | Percentage of players needed to `rtv` before a vote starts (rounded up to the nearest whole number). |
| NormalMapCooldown | Time in hours before a map can be nominated again. |
| MemeMapCooldown | Time in hours before a map in hidden_nom_maps.txt can be nominated again. |
| gameVotes | If set to 1, enables the `.vote` command to replace the built-in game votes. Currently only killing and survival mode votes are supported. |
| forceSurvivalVotes | If set to 1, enables the Semi-Survival game vote (players respawn when everyone dies). Requires [ForceSurvival](https://github.com/wootguy/ForceSurvival) to be installed. |
| restartVotes | If set to 1, enables map restart votes. |

# Installation
1. Download all the files in this repo and save them to this folder: `scripts/plugins/RockTheVote/`
1. Add this to default_plugins.txt
```
    "plugin"
    {
        "name" "RockTheVote"
        "script" "RockTheVote/RockTheVote"
        "concommandns" "rtv"
    }
```
1. Add these CVars to your `server.cfg` file. The values listed here are the defaults.
```
as_command rtv.secondsUntilVote 120
as_command rtv.iMaxMaps 5
as_command rtv.secondsToVote 25
as_command rtv.iPercentReq 66
as_command rtv.NormalMapCooldown 24
as_command rtv.MemeMapCooldown 240
as_command rtv.gameVotes 1
as_command rtv.forceSurvivalVotes 0
```
1. Create a file for the normal votable maps, or symlink your `mapvote.cfg` file here: `scripts/plugins/cfg/mapvote.txt`.  
Maps listed here can be nominated with the normal cooldown (`NormalMapCooldown`). The `addvotemap` text is optional in this list.
1. Create the hidden map list file: `scripts/plugins/cfg/hidden_nom_maps.txt`  
Maps listed here have a large nom cooldown (`MemeMapCooldown`) and never randomly show up in the vote menu or as the next map.
1. Install Python 3 and run `db_setup.py`. This will create the folders needed to track player map stats. If you don't do this, the map cycle will be random instead of based on previous map play times of the players currently in the server.
1. **[Optional]** Run `series_maps.py` to update series_maps.txt. Then, check the file to undo/fix any bad series maps detections. Use something like TortoiseDiff to compare the before/after files. If you don't follow this step, the `series?` command may not work properly, as well as map cooldowns for map series. The file included here is accurate for the TWLZ server but maybe not yours.
3. **[Optional]** Install the [ForceSurvival](https://github.com/wootguy/ForceSurvival) plugin if you want to enable `forceSurvivalVotes`.

## Keeping up-to-date
There are 4 map lists that are used by this plugin:
1. `mapcycle.txt` - This is the default map cycle file. This file is used to select the "Next map".
2. `scripts/plugins/cfg/mapvote.txt` - This is a new file which lists votable maps, except for maps you don't want anyone to play normally. It can be a copy of the default `mapvote.cfg` file or symlinked to it.
3. `scripts/plugins/cfg/hidden_nom_maps.txt` - This is a new file which holds votable maps which should only rarely be played because they're really bad or overplayed and you question why they're on the server at all.
4. `scripts/plugins/RockTheVote/series_maps.txt` - This file lists all map series. Each line represents an ordered list of maps in a single series.

As you add new maps, you'll need to decide which lists to put them in.
- Is the map good? Add it to **both** the mapcycle.txt and mapvote.txt
- Is the map kinda bad? Add it to mapvote.txt.
- Is the map garbage? Add it to hidden_nom_maps.txt.
- Is the map a series? Add it to series_maps.txt as well.

Check the angelscript logs for [RTV] messages. You'll see warnings about maps being in the wrong combination of lists, if you messed that up.
