import os, sys, re, datetime
from dateutil.tz import tzoffset

MAX_BUCKETS = 256 # should match the value in Database.as
logs_path = 'logs_2021_06_11'
logs_utc_offset = 1 # when parsing logs, use this timezone offset (hours)

store_path = "../../../../svencoop/scripts/plugins/store"
rtv_db_path = os.path.join(store_path, 'rtv')

if not os.path.exists(store_path):
	print("The store folder can't be found: " + store_path)
	print("The script failed. Check where you installed RockTheVote and if the store folder exists")
	sys.exit()

print("Creating database folders...")
if not os.path.exists(rtv_db_path):
	os.mkdir(rtv_db_path)

for x in range(0, MAX_BUCKETS):
	bucket_path = os.path.join(rtv_db_path, "%s" % x)
	if not os.path.exists(bucket_path):
		os.mkdir(bucket_path)

def find_single_match(regex, text):
	matches = re.findall(regex, text)
	
	if len(matches) == 1:
		return matches[0]
	elif len(matches) != 0:
		#raise(Exception("got multiple results for %s in line %s" % (regex, text)))
		print("got multiple results for %s in line %s" % (regex, text))
	
	return None
	
def hash_FNV1a(key):
	hash = 14695981039346656037

	for c in range(0, len(key)):
		hash = (hash * 1099511628211) ^ ord(key[c]);

	return hash
	
def build_db():
	if not os.path.exists(logs_path):
		print("\n'%s' folder not found. Database will not be rebuilt.\n" % logs_path)
		print("If you want to scan server log files to build the map history database, then:")
		print("  1. create a folder named '%s' in the same folder as this script" % logs_path)
		print("  2. copy all log files to the new '%s' folder" % logs_path)
		print("  3. run this script again")
	
	x = input("Server logs folder detected. Do you want to rebuild the stats database? This will overwrite existing files. (y/n): ")
	if x.lower() != 'y':
		print("aborting log scan")
		return
	
	logs_utc_offset = int(input("At which UTC offset are the log timestamps (ex: '-8' for -8 hours)? "))
		
	log_prefix_re = 'L \d\d/\d\d/\d\d\d\d - \d\d:\d\d:\d\d: ' # matches the beginning of a log line
	
	current_map = None
	map_start_time = None
	map_players = {} # join/leave times for the current map
	player_map_stats = {} # play stats across entire server logs
	all_logs = os.listdir(logs_path)
	
	for idx, file in enumerate(all_logs):
		lines = open(os.path.join(logs_path, file), encoding='utf-8', errors='replace').readlines()
		
		total_map_plays = 0
		total_maps = 0
		
		for line in lines:
			# convert log time to epoch time
			log_time = re.findall(log_prefix_re, line)
			if len(log_time) != 1:
				continue # broken log line or debug message
			if log_time:
				# convert log time to unix timestamp
				log_time = datetime.datetime.strptime(log_time[0], 'L %d/%m/%Y - %H:%M:%S: ')
				log_time = int( log_time.replace(tzinfo=tzoffset(None, logs_utc_offset*60*60)).timestamp() )
			
			# map load log line found?
			map_load = find_single_match(log_prefix_re + 'Loading map ', line)
			if map_load:
				map_name = find_single_match('\".*\"', line)
				
				if not map_name:
					raise("Found map load line with no map name")
				
				# process stats for previous map
				if current_map:
					previous_map_duration = (log_time - map_start_time) - 60 # remove some time for server loading and downloads
					#print("Map %s ended after %.1f minutes" % (current_map, (previous_map_duration / 60)))
					
					if previous_map_duration == 0:
						continue
					
					for player, stats in map_players.items():
						if previous_map_duration > 60*2:
							if 'end' not in stats:
								#print("%s wasnt in long enough (<1 minute)" % player)
								continue # was only connected for a short time (<1 minute)
								
							play_time = stats['end'] - stats['start']
							percent_played = (play_time / previous_map_duration)*100
							
							if percent_played < 50 and play_time < previous_map_duration:
								#print("%s wasnt in long enough (%d%% of map)" % (player, percent_played))
								continue
						else:
							# short map or fast rtv - not long enough for anyone to have complete stats
							pass
							
						if player not in player_map_stats:
							player_map_stats[player] = {'maps': {}}
						
						if current_map not in player_map_stats[player]['maps']:
							player_map_stats[player]['maps'][current_map] = {'total_plays': 0}
							
						player_map_stats[player]['maps'][current_map]['total_plays'] += 1
						player_map_stats[player]['maps'][current_map]['last_play_time'] = map_start_time
						player_map_stats[player]['name'] = stats['name']
						total_map_plays += 1
					total_maps += 1
						
				# start logging stats for this map
				map_name = map_name.strip('"').lower()
				current_map = map_name
				map_start_time = log_time
				map_players = {}
				#print("New map %s" % map_name)
			
			# player stat line found?
			if '><STEAM_' in line and '>" stats: frags=' in line and '>" say: ' not in line:
				steamid = find_single_match('<STEAM_\d:\d:\d+>', line)
				
				if not steamid:
					print("Found player stat line with no steam id. Ignoring.")
					continue
					
				steamid = steamid.strip("<>")
				name = line[26:line.index('><STEAM_')]
				name = name[:name.rindex('<')]
					
				if steamid in map_players:
					map_players[steamid]['end'] = log_time
				else:
					map_players[steamid] = {'name': name}
					map_players[steamid]['start'] = log_time
				
		
		print("[%s / %s] Parsed %s. %s maps loaded. %s play stats collected" % (idx, len(all_logs), file, total_maps, total_map_plays))
	
	print("Writing %s player stat files..." % len(player_map_stats))
	
	steam_ids_path = os.path.join(rtv_db_path, "steam_ids.txt")
	
	with open(steam_ids_path, "w") as all_ids:
		for player, player_stats in player_map_stats.items():
			steamid = player.replace(":", "_")
			hash = hash_FNV1a(steamid) % MAX_BUCKETS
			
			all_ids.write("%s\\%s\n" % (player.replace('STEAM_0:', ''), player_stats['name'].encode("ascii", 'replace').decode('ascii')))
			
			player_stat_path = os.path.join(rtv_db_path, "%s" % hash, steamid + ".txt")
			
			with open(player_stat_path, "w") as f:
				for map in player_stats['maps'].keys():
					f.write('%s %s %s 0\n' % (map, player_stats['maps'][map]['last_play_time'], player_stats['maps'][map]['total_plays']))

build_db()

print("\nFinished!")