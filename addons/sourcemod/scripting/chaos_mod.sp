#pragma semicolon 1
#pragma newdecls required

#define DEBUG

#define PLUGIN_AUTHOR "T0M50N & SauceMaster"
#define PLUGIN_VERSION "1.3"

#include <sourcemod>
#include <sdktools>

/* Make the admin menu plugin optional */
#undef REQUIRE_PLUGIN
#include <adminmenu>

public Plugin myinfo = 
{
	name = "L4D2 Chaos Mod Alternative",
	author = PLUGIN_AUTHOR,
	description = "Activates a random effect every 30 seconds.",
	version = PLUGIN_VERSION,
	url = "github.com/wtf420/L4D2ChaosMod"
};

#define EFFECTS_PATH "configs/effects.cfg"
#define P_BAR_LENGTH 36
#define PANEL_UPDATE_RATE 1.0
#define VOTE_DURATION 20
#define EFFECT_CHOOSE_ATTEMPTS 20

ArrayList g_effects;
ArrayList g_active_effects;
ArrayList g_cooling_down_effects;
StringMap g_EFFECT_DURATIONS;

// Handle g_effect_timer = INVALID_HANDLE;
Handle g_panel_timer = INVALID_HANDLE;

TopMenu g_admin_menu = null;

ConVar g_enabled;
ConVar g_time_between_effects;
ConVar g_short_time_duration;
ConVar g_normal_time_duration;
ConVar g_long_time_duration;

bool bChaosModStarted = false;

#include "parse.sp"

public void OnPluginStart()
{
	LoadTranslations("l4d2_chaos_mod.phrases");

	CreateConVar("chaosmod_version", PLUGIN_VERSION, " Version of Chaos Mod on this server ", FCVAR_SPONLY|FCVAR_DONTRECORD);
	g_enabled = CreateConVar("chaosmod_enabled", "1", "Enable/Disable Chaos Mod", FCVAR_NOTIFY);
	g_time_between_effects = CreateConVar("chaosmod_time_between_effects", "30", "How long to wait in seconds between activating effects", FCVAR_NOTIFY, true, 0.1);
	g_short_time_duration = CreateConVar("chaosmod_short_time_duration", "15", "A short effect will be enabled for this many seconds", FCVAR_NOTIFY, true, 0.1);
	g_normal_time_duration = CreateConVar("chaosmod_normal_time_duration", "60", "A normal effect will be enabled for this many seconds", FCVAR_NOTIFY, true, 0.1);
	g_long_time_duration = CreateConVar("chaosmod_long_time_duration", "120", "A long effect will be enabled for this many seconds", FCVAR_NOTIFY, true, 0.1);

	g_active_effects = new ArrayList();
	g_cooling_down_effects = new ArrayList();
	g_EFFECT_DURATIONS = new StringMap();
	g_EFFECT_DURATIONS.SetValue("none", g_normal_time_duration);
	g_EFFECT_DURATIONS.SetValue("short", g_short_time_duration);
	g_EFFECT_DURATIONS.SetValue("normal", g_normal_time_duration);
	g_EFFECT_DURATIONS.SetValue("long", g_long_time_duration);
	g_effects = Parse_KeyValueFile(EFFECTS_PATH);
	FilterAvailableEffect(g_effects);

	RegAdminCmd("chaosmod_vote", Command_Vote, ADMFLAG_GENERIC, "Starts vote to enable/disable chaosmod");
	RegAdminCmd("chaosmod_refresh", Command_Refresh, ADMFLAG_GENERIC, "Reloads effects from config");
	RegAdminCmd("chaosmod_stop", Command_StopAllActiveEffect, ADMFLAG_GENERIC, "Stop all currently active effects");
	RegAdminCmd("chaosmod_reset_cooldown", Command_ResetCoolDown, ADMFLAG_GENERIC, "Stop all currently active effects");
	g_time_between_effects.AddChangeHook(Cvar_TimeBetweenEffectsChanged);
	g_enabled.AddChangeHook(Cvar_EnabledChanged);
	HookEvent("server_cvar", Event_Cvar, EventHookMode_Pre);
	
	bChaosModStarted = false;
	// on map transition, disable chaos mod and does not enable it until exit the next safe room
	HookEvent("round_start", Event_RoundStart);
	// try start chaos mods when player start campaign and exit the starting area, this does not fire if you die and have to restart the map
	HookEvent("player_left_start_area", Event_RoundStart);
	// try start chaos mods when player start round and exit safe room, this does fire if you die and have to restart the map, so both event is needed
	HookEvent("player_left_safe_area", Event_RoundStart);
	// on map transition, disable chaos mod and does not enable it until exit the next safe room
	HookEvent("round_end", Event_RoundEnd);

	/* See if the menu plugin is already ready */
	TopMenu topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
	{
		/* If so, manually fire the callback */
		OnAdminMenuReady(topmenu);
	}
	
	AutoExecConfig(true);
	
	#if defined DEBUG
		RegAdminCmd("chaosmod_effect", Command_Start_Effect, ADMFLAG_GENERIC, "Activates a specific effect");
	#endif
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "adminmenu", false))
	{
		g_admin_menu = null;
	}
}

public void OnAdminMenuReady(Handle aTopMenu)
{
	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
 
	/* Block us from being called twice */
	if (topmenu == g_admin_menu)
	{
		return;
	}
 
	g_admin_menu = topmenu;
 
	/* If the category is third party, it will have its own unique name. */
	TopMenuObject voting_commands = FindTopMenuCategory(g_admin_menu, ADMINMENU_VOTINGCOMMANDS);
 
	if (voting_commands == INVALID_TOPMENUOBJECT)
	{
		/* Error! */
		return;
	}

	g_admin_menu.AddItem("chaosmod_vote", AdminMenu_ChaosModVote, voting_commands, "chaosmod_vote", ADMFLAG_VOTE);
}

public void AdminMenu_ChaosModVote(TopMenu topmenu, 
			TopMenuAction action,
			TopMenuObject object_id,
			int param,
			char[] buffer,
			int maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "Chaos Mod Vote");
	}
	else if (action == TopMenuAction_SelectOption)
	{
		Command_Vote(param, 0);
	}
	else if (action == TopMenuAction_DrawOption)
	{	
		/* disable this option if a vote is already running */
		buffer[0] = !IsNewVoteAllowed() ? ITEMDRAW_IGNORE : ITEMDRAW_DEFAULT;
	}
}

/*
	Blocks cvar changes being announced while chaosmod is enabled
*/
public Action Event_Cvar(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_enabled.BoolValue)
	{
		return Plugin_Continue;
	}
	return Plugin_Handled;
}

public void OnMapStart()
{
	g_active_effects.Clear();
	g_cooling_down_effects.Clear();
	if (g_panel_timer != INVALID_HANDLE) delete g_panel_timer;
	bChaosModStarted = false;
}

public void OnMapEnd()
{
	if (bChaosModStarted)
	{
		EndChaosMod();
	}
}

public void StartChaosMod()
{
	g_active_effects.Clear();
	g_cooling_down_effects.Clear();
	if (g_panel_timer != INVALID_HANDLE) delete g_panel_timer;
	ShowActivity2(0, "[SM] ", "Chaos Mod have started!");
	// g_effect_timer = CreateTimer(g_time_between_effects.FloatValue, Timer_StartRandomEffect, _, TIMER_REPEAT);
	g_panel_timer = CreateTimer(PANEL_UPDATE_RATE, Timer_UpdatePanel, _, TIMER_REPEAT);
	bChaosModStarted = true;
}

public void EndChaosMod()
{
	StopAllActiveEffects();
	g_active_effects.Clear();
	g_cooling_down_effects.Clear();
	// delete g_effect_timer;
	delete g_panel_timer;
	bChaosModStarted = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!bChaosModStarted)
	{
		StartChaosMod();
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) 
{
	if (bChaosModStarted)
	{
		EndChaosMod();
	}
}

public void Cvar_TimeBetweenEffectsChanged(ConVar convar, char[] oldValue, char[] newValue)
{
	ShowActivity2(0, "[SM] ", "TimeBetweenEffectsChanged!");
	if (!g_enabled.BoolValue)
	{
		return;
	}
	// delete g_effect_timer;
	delete g_panel_timer;
	// g_effect_timer = CreateTimer(g_time_between_effects.FloatValue, Timer_StartRandomEffect, _, TIMER_REPEAT);
	g_panel_timer = CreateTimer(PANEL_UPDATE_RATE, Timer_UpdatePanel, _, TIMER_REPEAT);
}

public void Cvar_EnabledChanged(ConVar convar, char[] oldValue, char[] newValue)
{
	if (!g_enabled.BoolValue)
	{
		StopAllActiveEffects();
		g_cooling_down_effects.Clear();
	}
}

public void StopAllActiveEffects()
{
	// Disable all currently active effects
	for (int i = 0; i < g_active_effects.Length; i++)
	{
		StringMap active_effect = view_as<StringMap>(g_active_effects.Get(i));
		StopEffect(active_effect);
		delete active_effect;
	}
	g_active_effects.Clear();
}

public int Panel_DoNothing(Menu menu, MenuAction action, int param1, int param2) {}

public Action Command_Vote(int client, int args)
{
	if (IsVoteInProgress())
	{
		ReplyToCommand(client, "[SM] Vote in Progress");
		return Plugin_Handled;
	}

	LogAction(client, -1, "\"%L\" initiated a chaosmod vote.", client);
	ShowActivity2(client, "[SM] ", "Initiate Chaos Mod Vote");

	Menu menu = new Menu(Vote_Callback);
	menu.SetTitle("%s Chaos Mod?", g_enabled.BoolValue ? "Disable": "Enable");
	menu.AddItem(g_enabled.BoolValue ? "0": "1", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.DisplayVoteToAll(VOTE_DURATION);

	return Plugin_Handled;
}

public int Vote_Callback(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		/* This is called after VoteEnd */
		delete menu;
	}
	else if (action == MenuAction_VoteEnd)
	{
		/* 0=yes, 1=no */
		if (param1 == 0)
		{
			char enable[64];
			menu.GetItem(param1, enable, sizeof(enable));
			g_enabled.SetString(enable);
		}
	}
}

public Action Command_StopAllActiveEffect(int client, int args)
{
	ReplyToCommand(client, "All active chaosmod effects have stopped!");
	StopAllActiveEffects();
	return Plugin_Handled;
}

public Action Command_ResetCoolDown(int client, int args)
{
	ReplyToCommand(client, "All active chaosmod cool downs have been reset!");
	g_cooling_down_effects.Clear();
	return Plugin_Handled;
}

public Action Command_Refresh(int client, int args)
{
	delete g_effects;
	g_effects = Parse_KeyValueFile(EFFECTS_PATH);
	return Plugin_Handled;
}

public Action Command_Start_Effect(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: chaosmod_effect <effect_name>");
		return Plugin_Handled;
	}
 
	char name[255];
	GetCmdArg(1, name, sizeof(name));
	
	for (int i = 0; i < g_effects.Length; i++)
	{
		StringMap effect = view_as<StringMap>(g_effects.Get(i));
		char name_other[255];
		effect.GetString("name", name_other, sizeof(name_other));
		if (StrEqual(name, name_other, false))
		{
			StartEffect(effect);
			return Plugin_Handled;
		}
	}
	
	ReplyToCommand(client, "Effect not found");
	return Plugin_Handled;
}

void StartEffect(StringMap effect)
{
	char buffer[255];
	effect.GetString("name", buffer, sizeof(buffer));
	for (int i = 0; i < g_active_effects.Length; i++)
	{
		StringMap other_effect = view_as<StringMap>(g_active_effects.Get(i));
		char name_other[255];
		other_effect.GetString("name", name_other, sizeof(name_other));
		if (StrEqual(buffer, name_other, false))
		{
			int time_left = 0;
			other_effect.GetValue("time_left", time_left);
			if (time_left < 0) continue;

			char extent_type_buffer[255];
			effect.GetString("extent_type", extent_type_buffer, sizeof(extent_type_buffer));
			if (StrEqual(extent_type_buffer, "duplicate", false))
			{
				// do nothing and just add like normal
			}
			else
			{
				if (StrEqual(extent_type_buffer, "none", false)) return;
				// extent the duration
				effect.GetString("active_time", buffer, sizeof(buffer));
				float f_active_time = Parse_ActiveTime(buffer);
				other_effect.SetValue("time_left", time_left + RoundToFloor(f_active_time));

				if (StrEqual(extent_type_buffer, "extent", false)) return;
				else if (StrEqual(extent_type_buffer, "end_and_repeat", false))
				{
					// execute the end commands
					effect.GetString("end", buffer, sizeof(buffer));
					ServerCommand(buffer);
				}

				// extent_type is "repeat", execute the start commands
				effect.GetString("start", buffer, sizeof(buffer));
				ServerCommand(buffer);

				return;
			}
		}
	}

	StringMap active_effect = new StringMap();
	
	effect.GetString("start", buffer, sizeof(buffer));
	ServerCommand(buffer);
	
	effect.GetString("name", buffer, sizeof(buffer));
	active_effect.SetString("name", buffer);

	effect.GetString("end", buffer, sizeof(buffer));
	active_effect.SetString("end", buffer);

	float f_active_time;
	effect.GetString("active_time", buffer, sizeof(buffer));
	f_active_time = Parse_ActiveTime(buffer);
	active_effect.SetValue("time_left", RoundToFloor(f_active_time));
	active_effect.SetValue("is_timed_effect", !StrEqual(buffer, "none", false));
	
	effect.GetString("cool_down_time", buffer, sizeof(buffer));
	active_effect.SetString("cool_down_time", buffer);
	
	g_active_effects.Push(active_effect);
}

void StopEffect(StringMap active_effect)
{
	char buffer[255];
	active_effect.GetString("end", buffer, sizeof(buffer));
	ServerCommand(buffer);

	float f_cool_down_time = 0.0;
	active_effect.GetString("name", buffer, sizeof(buffer));
	for (int i = 0; i < g_cooling_down_effects.Length; i++)
	{
		StringMap other_effect = view_as<StringMap>(g_cooling_down_effects.Get(i));
		char name_other[255];
		other_effect.GetString("name", name_other, sizeof(name_other));
		if (StrEqual(buffer, name_other, false))
		{
			active_effect.GetString("cool_down_time", buffer, sizeof(buffer));
			f_cool_down_time = Parse_ActiveTime(buffer);
			other_effect.SetValue("time_left", RoundToFloor(f_cool_down_time));
			return;
		}
	}

	StringMap cool_down_effect = new StringMap();
	cool_down_effect.SetString("name", buffer);

	active_effect.GetString("end", buffer, sizeof(buffer));
	cool_down_effect.SetString("end", buffer);
	
	active_effect.GetString("cool_down_time", buffer, sizeof(buffer));
	f_cool_down_time = Parse_ActiveTime(buffer);
	// Since the cool down effects duration is updated right after this, the time_left will be reduced by 1 second without actual 1 second real time
	// so we correct that with this 
	cool_down_effect.SetValue("time_left", RoundToFloor(f_cool_down_time) + 1);

	g_cooling_down_effects.Push(cool_down_effect);
}

StringMap AttemptChooseRandomEffect()
{
	// Check if effect can be used on current map
	ArrayList available_effects = new ArrayList();
	for (int i = 0; i < g_effects.Length; i++)
	{
		StringMap effect = view_as<StringMap>(g_effects.Get(i));
		char name[255];
		effect.GetString("name", name, sizeof(name));
		bool on_cool_down = false;
		
		for (int j = 0; j < g_cooling_down_effects.Length; j++)
		{
			StringMap other_effect = view_as<StringMap>(g_cooling_down_effects.Get(j));
			char name_other[255];
			other_effect.GetString("name", name_other, sizeof(name_other));
			if (StrEqual(name, name_other, false))
			{
				on_cool_down = true;
				break;
			}
		}

		if (!on_cool_down) available_effects.Push(effect);
	}

	if (available_effects.Length > 0)
	{
		int random_effect_i = GetRandomInt(0, available_effects.Length - 1);
		StringMap chosen_effect = view_as<StringMap>(available_effects.Get(random_effect_i));
		return chosen_effect;
	}
	return view_as<StringMap>(INVALID_HANDLE);
}

public Action Timer_StartRandomEffect(Handle timer)
{
	if (!g_enabled.BoolValue)
	{
		return Plugin_Handled;
	}

	StringMap effect = AttemptChooseRandomEffect();
	if (effect != INVALID_HANDLE)
	{
		StartEffect(effect);
	}

	return Plugin_Handled;
}

// this is also used to update the effect timer as well
public Action Timer_UpdatePanel(Handle timer, any unused)
{
	static int time_until_next_effect = -1;

	if (!g_enabled.BoolValue)
	{
		return Plugin_Handled;
	}
	
	float pbar_fullness = 1 - (time_until_next_effect / g_time_between_effects.FloatValue);
	for (int i = 1; i <= MaxClients; i++)
	{
		// If a menu is open then don't show the panel
		if (!IsClientInGame(i) ||
			(!(GetClientMenu(i) == MenuSource_RawPanel) && !(GetClientMenu(i) == MenuSource_None)))
		{
			continue;
		}

		Panel p = CreateEffectPanel(i, pbar_fullness);
		p.Send(i, Panel_DoNothing, RoundToFloor(PANEL_UPDATE_RATE) + 1);
		delete p;
	}
	
	for (int i = g_active_effects.Length - 1; i >= 0; i--)
	{
		StringMap active_effect = view_as<StringMap>(g_active_effects.Get(i));

		int time_left;
		active_effect.GetValue("time_left", time_left);

		if (time_left > 0)
		{
			active_effect.SetValue("time_left", time_left - 1);
		}
		else
		{
			g_active_effects.Erase(i);
			StopEffect(active_effect);
			delete active_effect;
		}
	}

	for (int i = g_cooling_down_effects.Length - 1; i >= 0; i--)
	{
		StringMap g_cooling_down_effect = view_as<StringMap>(g_cooling_down_effects.Get(i));

		int time_left;
		g_cooling_down_effect.GetValue("time_left", time_left);

		if (time_left > 0)
		{
			g_cooling_down_effect.SetValue("time_left", time_left - 1);
		}
		else
		{
			g_cooling_down_effects.Erase(i);
			delete g_cooling_down_effect;
		}
		
	}
	
	// an effect was triggered manually / timer trigger next effect
	if (time_until_next_effect > 0)
	{
		time_until_next_effect--;
	}
	else
	{
		Timer_StartRandomEffect(timer);
		time_until_next_effect = g_time_between_effects.IntValue;
	}

	return Plugin_Handled;
}

void FilterAvailableEffect(ArrayList &effects)
{
	int random_effect_i = GetRandomInt(0, g_effects.Length - 1);
	StringMap effect = view_as<StringMap>(g_effects.Get(random_effect_i));

	for (int i = effects.Length - 1; i >= 0; i--)
	{
		// Check if effect can be used on current map
		ArrayList maps;
		if (effect.GetValue("disable_on_maps", maps))
		{
			char current_map[64];
			GetCurrentMap(current_map, sizeof(current_map));

			for (int j = 0; j < maps.Length; j++)
			{
				char map[64];
				maps.GetString(i, map, sizeof(map));
				if (StrEqual(current_map, map))
				{
					g_effects.Erase(i);
					delete effect;
					continue;
				}
			}
		}
	}
}

Panel CreateEffectPanel(int client, float pbar_fullness)
{
	Panel p = new Panel();
	
	p.SetTitle("Chaos Mod");
	
	DrawProgressBarPanelText(p, pbar_fullness);

	for (int i = g_active_effects.Length - 1; i >= 0; i--)
	{
		StringMap active_effect = view_as<StringMap>(g_active_effects.Get(i));
		DrawActiveEffectPanelText(p, client, active_effect);
	}

	if (g_cooling_down_effects.Length > 0)
	{
		p.DrawText(" ");
		p.DrawText("======= Effects On Cool down =======");
		for (int i = g_cooling_down_effects.Length - 1; i >= 0; i--)
		{
			StringMap cooling_down_effect = view_as<StringMap>(g_cooling_down_effects.Get(i));
			DrawCoolingDownEffectPanelText(p, client, cooling_down_effect);
		}
	}

	return p;
}

void DrawProgressBarPanelText(Panel panel, float fullness)
{
	char pbar[P_BAR_LENGTH + 1];
	pbar[P_BAR_LENGTH] = 0;
	int pbar_fullness = RoundToNearest(fullness * P_BAR_LENGTH);
	for (int i = 0; i < P_BAR_LENGTH; i++)
	{
		if (i < pbar_fullness)
		{
			pbar[i] = '#';
		}
		else
		{
			pbar[i] = '_';
		}
	}
	panel.DrawText(pbar);
}

void DrawActiveEffectPanelText(Panel panel, int client, StringMap active_effect)
{
	int time_left;
	active_effect.GetValue("time_left", time_left);
	
	char effect_name[255];
	active_effect.GetString("name", effect_name, sizeof(effect_name));
	char effect_tran_name[255];
	Format(effect_tran_name, sizeof(effect_tran_name), "Effect %s", effect_name);
	
	bool is_timed_effect;
	active_effect.GetValue("is_timed_effect", is_timed_effect);

	char panel_text[255];
	if (is_timed_effect)
	{
		Format(panel_text, sizeof(panel_text), "%T (%d)", effect_tran_name, client, time_left);
	}	
	else
	{
		Format(panel_text, sizeof(panel_text), "%T", effect_tran_name, client);
	}

	panel.DrawText(panel_text);
}

void DrawCoolingDownEffectPanelText(Panel panel, int client, StringMap cool_down_effect)
{
	int time_left;
	cool_down_effect.GetValue("time_left", time_left);
	
	char effect_name[255];
	cool_down_effect.GetString("name", effect_name, sizeof(effect_name));
	char effect_tran_name[255];
	Format(effect_tran_name, sizeof(effect_tran_name), "Effect %s", effect_name);
	
	char panel_text[255];
	Format(panel_text, sizeof(panel_text), "%T (%d)", effect_tran_name, client, time_left);

	panel.DrawText(panel_text);
}