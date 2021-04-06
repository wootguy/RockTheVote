# RockTheVote
A rewrite of the [RockTheVote plugin by MrOats](https://github.com/MrOats/AngelScript_SC_Plugins/wiki/RockTheVote.as), with features from the RandomNextMap plugin by takedeppo, and some other new features.  


This plugin will randomize the map cycle and prevent maps from being played again until most other maps on the server have been played, or if someone specifically nominates a repeat map.
There's also a new map list for maps that can only be played once a month or so because they're horrible, overplayed, or just don't fit the normal gameplay of sven.

This plugin also adds text-menu alternatives to the built-in game votes. These are much less annoying as they don't take control of your mouse.

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

# Console commands

Note: These commands also work in chat.

| Command | Admin only? | Description |
| --- | --- | --- |
| .forcertv | Yes | Force a map vote now. |
| .cancelrtv | Yes | Cancels an active map vote. |
| .map [map] | Yes | Force a map change. |
| .set_nextmap [map] | Yes | Set the next map for when the current map ends. This doesn't work for maps in a series (which use trigger_changelevel instead of game_end) |
| .pastmaplist | No | Show the recently played maps that can't be nominated yet. |
| .pastmaplistfull | No | Show all maps in `previous_maps.txt`. |
| .vote | No | Open the vote menu (requires `rtv.gameVotes 1` CVar). |

# CVars
| CVar | Description |
| --- | --- |
| secondsUntilVote | Prevents rtv'ing until this many seconds after the map starts (without this a single person could start a vote before anyone else joins). |
| iMaxMaps | The max number of maps shown in the vote menu. 9 is the max before options are split into pages. |
| secondsToVote | How long the vote menu will be shown. |
| iPercentReq | Percentage of players needed to `rtv` before a vote starts (rounded up to the nearest whole number). |
| iExcludePrevMaps | Number of maps to remember in the `previous_maps.txt` file. Maps in this list will never be chosen randomly for the next map or in the vote menu. Maps are not written to the previous maps list if the server population is low (less than 4 players), or if a map isn't found in `mapvote.cfg` or `hidden_nom_maps.txt`. <br /><br /> For the least amount of repeat maps, set this to the number of maps in your `mapcycle.txt` file, minus about 50 or so. You'll want there to be maybe 50 potential options for the next map because the server won't update the previous map list when there are less than 4 players. The map cycle might also be too predictable without enough possibilities. |
| iExcludePrevMapsNomOnly | Number of maps needed to play before the same map can be nominated again. |
| iExcludePrevMapsNomOnlyMeme | Number of maps needed to play before a map in `hidden_nom_maps.txt` can be nominated again. |
| gameVotes | If set to 1, enables the `.vote` command to replace the built-in game votes. Currently only killing and survival mode votes are supported. |

# Installation
1. Download the script and save it to `scripts/plugins/RockTheVote.as`
1. Add this to default_plugins.txt
```
    "plugin"
    {
        "name" "RockTheVote"
        "script" "RockTheVote"
        "concommandns" "rtv"
    }
```
3. Add these CVars to your `server.cfg` file. The values listed here are the defaults. You might need to change the `iExclude*` values depending on how many maps you have on the server.  
```
as_command rtv.secondsUntilVote 120
as_command rtv.iMaxMaps 5
as_command rtv.secondsToVote 25
as_command rtv.iPercentReq 66
as_command rtv.iExcludePrevMaps 800
as_command rtv.iExcludePrevMapsNomOnly 20
as_command rtv.iExcludePrevMapsNomOnlyMeme 400
```
4. Create a file for the normal votable maps, or symlink your `mapvote.cfg` file here: `scripts/plugins/cfg/mapvote.txt`.  
Maps listed here can be nominated with the normal cooldown (`iExcludePrevMapsNomOnly`). The `addvotemap` text is optional in this list.
5. Create the hidden map list file: `scripts/plugins/cfg/hidden_nom_maps.txt`  
Maps listed here have a large nom cooldown (`iExcludePrevMapsNomOnlyMeme`) and never randomly show up in the vote menu or as the next map.
6. Make sure your `mapcycle.txt` file is up-to-date with what you have installed on the server, and that the number of maps in that file is larger than the `iExcludePrevMaps` CVar.
