ArrayList Parse_KeyValueFile(const char[] path)
{
	char effects_path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, effects_path, sizeof(effects_path), path);
	
	KeyValues kv = new KeyValues("effects");
	kv.SetEscapeSequences(true);
	
	if (!kv.ImportFromFile(effects_path))
	{
		SetFailState("Could not open %s", effects_path);
	}
	if (!kv.GotoFirstSubKey())
	{
		SetFailState("Where the effects at?");
	}
	
	ArrayList effects = new ArrayList();
	do
	{
		StringMap effect = new StringMap();
		char buffer[255];
		
		
		kv.GetSectionName(buffer, sizeof(buffer));
		effect.SetString("name", buffer);
		
		kv.GetString("start", buffer, sizeof(buffer));
		effect.SetString("start", buffer);
		
		kv.GetString("end", buffer, sizeof(buffer));
		effect.SetString("end", buffer);

		kv.GetString("disable_on_maps", buffer, sizeof(buffer), "");
		if (strlen(buffer) != 0)
		{
			int no_maps = CountCharInString(buffer, ',') + 1;
			char[][] maps_buffer = new char[no_maps][64];
			ExplodeString(buffer, ",", maps_buffer, no_maps, 64);

			ArrayList maps = new ArrayList(64, no_maps);
			for (int i = 0; i < no_maps; i++)
			{
				maps.SetString(i, maps_buffer[i]);
			}
			
			effect.SetValue("disable_on_maps", maps);
		}
		
		kv.GetString("active_time", buffer, sizeof(buffer));
		float active_time = Parse_ActiveTime(buffer);
		if (active_time < 0)
		{
			effect.GetString("name", buffer, sizeof(buffer));
			SetFailState("Invalid active time for effect: %s", buffer);
		}
		effect.SetString("active_time", buffer);

		kv.GetString("cool_down_time", buffer, sizeof(buffer));
		active_time = Parse_ActiveTime(buffer);
		if (active_time < 0)
		{
			effect.GetString("name", buffer, sizeof(buffer));
			SetFailState("Invalid cool down time for effect: %s", buffer);
		}
		effect.SetString("cool_down_time", buffer);

		
		kv.GetString("extent_type", buffer, sizeof(buffer));
		effect.SetString("extent_type", buffer);
		
		effects.Push(effect);
	} while (kv.GotoNextKey());
	delete kv;
	
	LogMessage("Successfully loaded %d effects", effects.Length);
	#if defined DEBUG
		for (int i = 0; i < effects.Length; i++)
		{
			char effect_name[255];
			StringMap effect = view_as<StringMap>(effects.Get(i));
			effect.GetString("name", effect_name, sizeof(effect_name));
			LogMessage("Loaded effect \"%s\"", effect_name);
		}
	#endif

	return effects;
}

float Parse_ActiveTime(const char[] active_time)
{
	StringMapSnapshot durations = g_EFFECT_DURATIONS.Snapshot();
	for (int i = 0; i < durations.Length; i++)
	{
		char duration_name[255];
		durations.GetKey(i, duration_name, sizeof(duration_name));
		if (StrEqual(active_time, duration_name, false))
		{
			delete durations;
			ConVar c;
			g_EFFECT_DURATIONS.GetValue(duration_name, c);
			return c.FloatValue;
		}
	}
	delete durations;
	
	float f = StringToFloat(active_time);
	if (f < 0.01)
	{
		return -1.0;
	}
	return f;
}

/**
 * Counts the number of occurences of a character in a string.
 *
 * @param str        String.
 * @param c            Character to count.
 * @return            The number of occurences of the character in the string.
 */
int CountCharInString(const char[] str, char c) {
	int i = 0;
	int count = 0;

	while (str[i] != '\0') {
		if (str[i] == c) {
			count += 1;
		}
		i += 1;
	}

	return count;
} 