
// angelscript dictionaries in sven lag like shit when they have a lot of keys,
// even when not accessing them. They just generate lag without being used somehow.
// So, this is a temporary replacement.

uint64 hash_FNV1a(string key) 
{
	uint64 hash = 14695981039346656037;

	for (uint c = 0; c < key.Length(); c++) {
		hash = (hash * 1099511628211) ^ key[c];
	}

	return hash;
}

class HashMapEntryMapStat {
	string key;
	MapStat@ value;
	
	HashMapEntryMapStat() {}
	
	HashMapEntryMapStat(string key, MapStat@ value) {
		this.key = key;
		@this.value = @value;
	}
}

// round up to the nearest power of 2
uint32 ceil_pot(uint32 v)
{
	// http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
	v -= 1;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v += 1;
	return v;
}

class HashMapMapStat
{
	array<array<HashMapEntryMapStat>> buckets;
	
	HashMapMapStat() {
		buckets.resize(1024);
	}
	
	HashMapMapStat(int size) {
		buckets.resize(size);
	}
	
	MapStat@ get(string key) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				return @buckets[idx][i].value;
			}
		}
		
		MapStat newStat;
		put(key, newStat);
		
		return @newStat;
	}
	
	array<string> getKeys() {
		array<string> allKeys;
		
		for (uint i = 0; i < buckets.size(); i++) {
			for (uint k = 0; k < buckets[i].size(); k++) {
				allKeys.insertLast(buckets[i][k].key);
			}
		}
		
		return allKeys;
	}
	
	array<HashMapEntryMapStat@> getItems() {
		array<HashMapEntryMapStat@> items;
		
		for (uint i = 0; i < buckets.size(); i++) {
			for (uint k = 0; k < buckets[i].size(); k++) {
				items.insertLast(@buckets[i][k]);
			}
		}
		
		return items;
	}
	
	void put(string key, MapStat@ value) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				@buckets[idx][i].value = @value;
				return;
			}
		}
		
		buckets[idx].insertLast(HashMapEntryMapStat(key, value));
	}
	
	bool exists(string key) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				return true;
			}
		}
		return false;
	}
	
	void clear(int newSize) {
		buckets.resize(0);
		buckets.resize(newSize);
	}
	
	int countItems() {
		int total = 0;
		
		for (uint i = 0; i < buckets.size(); i++) {
			total += buckets[i].size();
		}
		
		return total;
	}
	
	// resize to the smallest amount of buckets with low average depth
	void resize() {
		int targetBucketSize = Math.max(uint(1), ceil_pot(countItems() / 2));
		
		HashMapMapStat newMap(targetBucketSize);
		
		for (uint i = 0; i < buckets.size(); i++) {
			for (uint k = 0; k < buckets[i].size(); k++) {
				newMap.put(buckets[i][k].key, buckets[i][k].value);
			}
		}
		
		this.buckets = newMap.buckets;
	}
	
	void stats() {
		int total_collisions = 0;
		float avg_bucket_depth = 0;
		int total_filled_buckets = 0;
		uint max_bucket_depth = 0;
		
		for (uint i = 0; i < buckets.size(); i++) {
			if (buckets[i].size() > 0) {
				total_collisions += buckets[i].size()-1;
				total_filled_buckets += 1;
				avg_bucket_depth += buckets[i].size();
				max_bucket_depth = Math.max(max_bucket_depth, buckets[i].size());
			}
		}
		
		float bucket_filled_percent = float(total_filled_buckets) / buckets.size();
		
		println("Total collisions: " + total_collisions);
		println("Buckets filled: " + total_filled_buckets + " / " + buckets.size() + " (" + int(bucket_filled_percent*100) + "%%)");
		println("Average bucket depth: " + (avg_bucket_depth / float(total_filled_buckets)));
		println("Max bucket depth: " + max_bucket_depth);
	}
}