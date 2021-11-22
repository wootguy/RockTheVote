import struct, os

def parse_keyvalue(line):
	if line.find("//") != -1:
		line = line[:line.find("//")]
		
	quotes = [idx for idx, c in enumerate(line) if c == '"']
	
	if len(quotes) < 4:
		return None
	
	key   = line[quotes[0]+1 : quotes[1]]
	value = line[quotes[2]+1 : quotes[3]]
	
	return (key, value)

def parse_ents(path, ent_text):
	ents = []

	lineNum = 0
	lastBracket = -1
	ent = None
	
	for line in ent_text.splitlines():
		lineNum += 1
		
		if len(line) < 1 or line[0] == '\n':
			continue
			
		if line[0] == '{':
			if lastBracket == 0:
				print("\n%s.bsp ent data (line %d): Unexpected '{'\n" % (path, lineNum));
				continue
			lastBracket = 0

			ent = {}

		elif line[0] == '}':
			if lastBracket == 1:
				print("\n%s.bsp ent data (line %d): Unexpected '}'\n" % (path, lineNum));
			lastBracket = 1

			if ent == None:
				continue

			ents.append(ent)
			ent = None

			# a new ent can start on the same line as the previous one ends
			if line.find("{") != -1:
				ent = {}
				lastBracket = 0

		elif lastBracket == 0 and ent != None: # currently defining an entity
			keyvalue = parse_keyvalue(line)
			if keyvalue:
				ent[keyvalue[0]] = keyvalue[1]
	
	return ents

def load_entities(bsp_path):
	with open(bsp_path, mode='rb') as f:
		bytes = f.read()
		version = struct.unpack("i", bytes[:4])
		
		offset = struct.unpack("i", bytes[4:4+4])[0]
		length = struct.unpack("i", bytes[8:8+4])[0]
		
		ent_text = bytes[offset:offset+length].decode("ascii", "ignore")
		
		return parse_ents(bsp_path, ent_text)
	
	print("\nFailed to open %s" % bsp_path)
	return None
	
def get_all_maps(maps_dir):
	all_maps = []
	
	for file in os.listdir(maps_dir):
		if not file.lower().endswith('.bsp'):
			continue
		if '@' in file:
			continue # ignore old/alternate versions of maps (w00tguy's scmapdb content pool)
			
		all_maps.append(os.path.join(maps_dir, file))
		
	return sorted(all_maps, key=lambda v: v.upper())



list_file = 'series_maps.txt'

all_maps = []
for dir in ["../../../../svencoop/maps", "../../../../svencoop_addon/maps", "../../../../svencoop_downloads/maps"]:
	if os.path.exists(dir):
		all_maps += get_all_maps(dir)


series_ignore = []
with open('series_ignore.txt', mode='r') as f:
	for map in f.readlines():
		map = map[:map.find('/')]
		series_ignore.append(map.lower().strip())

map_changes = {}
all_nextmaps = set({})

last_progress_str = ''
for idx, map_path in enumerate(all_maps):
	map_name = os.path.basename(map_path).lower().replace('.bsp', '')
	
	if map_name in series_ignore:
		continue

	progress_str = "Progress: %s / %s  (%s)" % (idx, len(all_maps), map_name)
	padded_progress_str = progress_str
	if len(progress_str) < len(last_progress_str):
		padded_progress_str += ' '*(len(last_progress_str) - len(progress_str))
	last_progress_str = progress_str
	print(padded_progress_str, end='\r')
	
	all_ents = load_entities(map_path)
	
	for ent in all_ents:
		if 'classname' in ent and 'trigger_changelevel' in ent['classname'] and 'map' in ent:
			nextmap = ent['map'].lower()
			if map_name in map_changes:
				map_changes[map_name].append(nextmap)
			else:
				map_changes[map_name] = [nextmap]
			
			all_nextmaps.add(nextmap)

first_maps = []

for map, nextmap in map_changes.items():
	if map not in all_nextmaps:
		first_maps.append(map)

with open(list_file, 'w') as f:
	for map in first_maps:
		if map in map_changes:
			maplist = [map]
			
			nextmaps = map_changes[map]
			
			while len(nextmaps):
				next_next_maps = []
				
				for nextmap in nextmaps:
					if nextmap in maplist:
						continue # cyclic map change
					
					maplist.append(nextmap)
				
					if nextmap in map_changes:
						next_next_maps += map_changes[nextmap]	
				
				nextmaps = next_next_maps
			
			f.write(' '.join(maplist) + '\n')