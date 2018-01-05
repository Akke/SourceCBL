/*
	Plugin made by and for SourceCBL - Source Community Ban List.
	
	When a player joins the server connects to an API where it checks whether the connecting
	player is marked as a cheater or not. If the result comes through as true then they're kicked
	with a warning message telling them they've been banned by SourceCBL.
	
	The API has a rate limit if 3000 requests per 10 minutes, and if you exceed it then
	all cheaters will be let through for 10 minutes until it resets.
*/
#include <sdkhooks>
#include <sdktools>
#include <SteamWorks>
#include <smjansson>
#include <clientprefs>
#include <advanced_motd>

#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL    "https://raw.githubusercontent.com/SirPurpleness/SourceCBL/master/updater.txt"
#define SPECMODE_NONE 				0
#define SPECMODE_FIRSTPERSON 		4
#define SPECMODE_3RDPERSON 			5

#pragma dynamic 1045840

EngineVersion g_EngineVersion;

char ClientSteam[MAXPLAYERS+1][255];
char g_sPadding[128] = "  ";
char FilePath[PLATFORM_MAX_PATH];
char port[32];
char hostname[64];
char TargetSteam32[MAXPLAYERS+1][255];

ConVar g_hCvarEnabled;
ConVar g_hCvarCurrentGameOnly;
ConVar g_hCvarDisableAlt;

bool IsEnabled = true;
bool CurrentGameOnly = false;
bool PlayerIsCheater[MAXPLAYERS+1] = false;
bool HasSeenMOTD[MAXPLAYERS+1] = false;
bool DisableAltBlock = false;

int CurrentGameID = 0;

Handle hAuthTimer[MAXPLAYERS+1] = INVALID_HANDLE;
Handle gamePort;
Handle gameHostName;
Handle AutoCooldown[MAXPLAYERS+1] = INVALID_HANDLE;

int AuthTries[MAXPLAYERS+1] = 0;
int iSpecTarget[MAXPLAYERS+1];

public Plugin myinfo =
{
	name = "SourceCBL",
	author = "SomePanns",
	description = "Allows communities to keep hackers/cheaters away from their servers by using a global database with stored information of hackers/cheaters.",
	version = "2.0",
}

public void OnPluginStart()
{
	g_EngineVersion = GetEngineVersion();
	
	g_hCvarEnabled = CreateConVar("sm_scbl_enabled", "1", "Enable or disable SourceCBL. 1 = Enabled (default), 0 = disabled.", FCVAR_NOTIFY);
	g_hCvarCurrentGameOnly = CreateConVar("sm_scbl_current_game_only", "0", "If set to 0 (default) then cheaters banned from any Source game will be kicked. If set to 1 then only cheaters banned from the current game the server is running are kicked.", FCVAR_NOTIFY);
	g_hCvarDisableAlt = CreateConVar("sm_scbl_disable_altcheck", "0", "0 (default) blocks all alternate account detected from marked cheaters only. 1 will allow alternate accounts of marked cheaters to connect.", FCVAR_NOTIFY);
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	RegConsoleCmd("sm_scbl", Command_Scbl, "Instantly reloads the database from SourceCBL.com and kicks any newly marked cheaters out of the server. Has a cooldown.");
	
	HookConVarChange(g_hCvarEnabled, OnConVarChange);

	BuildPath(Path_SM, FilePath, sizeof(FilePath), "configs/sourcecbl_whitelist.txt");

	if(LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL)
    }
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dB)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if(!DisableAltBlock && !IsFakeClient(client) && !HasSeenMOTD[client])
	{
		char PanelURLToShow[255];
		Format(PanelURLToShow, sizeof(PanelURLToShow), "https://sourcecbl.com/api/initiate?initSteamID=%s", ClientSteam[client]);
		AdvMOTD_ShowMOTDPanel(client, "SourceCBL.com", PanelURLToShow, MOTDPANEL_TYPE_URL, true, false, true, OnMOTDFailure);
		
		CreateTimer(10.0, Timer_SendData, client);
		HasSeenMOTD[client] = true;
	}
}

public Action Timer_SendData(Handle timer, int client)
{
	if(IsClientConnected(client))
	{
		UploadDataString(client);
	}
}

public void OnMOTDFailure(int client, MOTDFailureReason reason) {
    LogError("[SourceCBL] Failed to launch MOTD to verify authentication of alternate account for %s", ClientSteam[client]);
} 

public Action Command_Scbl(int client, int args)
{
	if(IsValidClient(client) && client > 0)
	{
		if(AutoCooldown[client] == INVALID_HANDLE)
		{
			for(int iclient = 1; iclient <= MaxClients; iclient++)
			{
				if(IsClientConnected(iclient) && IsClientInGame(iclient))
				{
					UploadDataString(iclient);
				}
			}
			
			AutoCooldown[client] = CreateTimer(900.0, Timer_AutoCommand, client);	
		}
		else
		{
			PrintToChat(client, "\x04[SourceCBL]\x05 This command is on cooldown, please stand by.");
		}
	}
}

public Action Timer_AutoCommand(Handle timer, int client)
{
	AutoCooldown[client] = INVALID_HANDLE;
}

public OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL)
    }
}

public void OnMapStart()
{
	gamePort = FindConVar("hostport");
	gameHostName = FindConVar("hostname");

	GetConVarString(gamePort, port, 32);
	GetConVarString(gameHostName, hostname, 64);

	char s_URL[] = "http://sourcecbl.com/api/statistics";

	Handle handle = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, s_URL);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "ip", port);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "hostname", hostname);
	SteamWorks_SendHTTPRequest(handle);
	CloseHandle(handle);
	
	CreateTimer(900.0, Timer_AutoReload, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	if(!DisableAltBlock) 
	{
		CreateTimer(10.0, Timer_AutoAltCheck, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnConfigsExecuted() {
	IsEnabled = GetConVarBool(g_hCvarEnabled);
	CurrentGameOnly = GetConVarBool(g_hCvarCurrentGameOnly);
	DisableAltBlock = GetConVarBool(g_hCvarDisableAlt);

	if(!IsEnabled) {
		ServerCommand("sm plugins unload sourcecbl");
	}
	
	AssignGameIDs();
}

public Action Timer_AutoAltCheck(Handle timer)
{
	if(GetClientCount() > 0) 
	{
		for(int client = 1; client <= MaxClients; client++)
		{
			if(client > 0 && client < MaxClients+1)
			{
				char s_URL[] = "https://sourcecbl.com/api/initiate_two/";

				Handle handle = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, s_URL);

				SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "steam", ClientSteam[client]);
				SteamWorks_SetHTTPRequestRawPostBody(handle, "text/html", s_URL, sizeof(s_URL));
				if (!handle || !SteamWorks_SetHTTPCallbacks(handle, HTTP_AltRequestComplete) || !SteamWorks_SendHTTPRequest(handle))
				{
					CloseHandle(handle);
				}
			}
		}
	}
}

public int HTTP_AltRequestComplete(Handle HTTPRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if(!bRequestSuccessful) {
        LogError("[SourceCBL] An error occured while requesting the alt API.");
    } else {
		SteamWorks_GetHTTPResponseBodyCallback(HTTPRequest, AltResponse);

		CloseHandle(HTTPRequest);
    }
}

public int AltResponse(const char[] sData)
{
	for(int client = 1; client <= MaxClients; client++)
	{
		if(client > 0 && client < MaxClients+1)
		{
			if(StrEqual(sData, ClientSteam[client], false))
			{
				CreateTimer(0.1, SourceCBLTimer, client);
				break;
			}
		}
	}
}

public void AssignGameIDs()
{
	if(CurrentGameOnly)
	{
		switch(g_EngineVersion)
		{
			case Engine_TF2:
			{
				CurrentGameID = 440;
			}
			
			case Engine_Left4Dead2:
			{
				CurrentGameID = 550;
			}
			
			case Engine_CSGO:
			{
				CurrentGameID = 730;
			}
			
			case Engine_DODS:
			{
				CurrentGameID = 300;
			}
			
			default:
			{
				CurrentGameID = 0;
			}
		}
	}
	else
	{
		CurrentGameID = 0;
	}
}

public void OnClientDisconnect(int client)
{
	AuthTries[client] = 0;
	HasSeenMOTD[client] = false;
	KillTimerSafe(AutoCooldown[client]);
}

public void OnClientPutInServer(int client)
{
	AuthTries[client] = 0;
}

public void OnConVarChange(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsEnabled = GetConVarBool(g_hCvarEnabled);
	CurrentGameOnly = GetConVarBool(g_hCvarCurrentGameOnly);
	DisableAltBlock = GetConVarBool(g_hCvarDisableAlt);
	
	AssignGameIDs();

	if(convar == g_hCvarEnabled)
	{
		if(StrEqual(oldValue, "1", false)) { // disable the plugin
			ServerCommand("sm plugins unload sourcecbl");
			PrintToServer("[SCBL] SourceCBL Disabled");
		}
	}
}

public void OnClientAuthorized(int client)
{
	CurrentGameOnly = GetConVarBool(g_hCvarCurrentGameOnly);
	DisableAltBlock = GetConVarBool(g_hCvarDisableAlt);
	
	if(!IsFakeClient(client))
	{
		if(!GetClientAuthId(client, AuthId_SteamID64, ClientSteam[client], sizeof(ClientSteam)))
		{
			LogError("[SourceCBL] Could not fetch Steam ID of client %N. Re-trying later.", client);
			hAuthTimer[client] = CreateTimer(180.0, AuthTimer, client, TIMER_REPEAT);
		}
	}
}

public Action Timer_AutoReload(Handle timer)
{
	for(int client = 1; client <= MaxClients; client++)
	{
		if(client > 0 && client < MaxClients+1)
		{
			UploadDataString(client);
		}
	}
}

public bool IsPlayerGenericAdmin(int client)
{
    if (CheckCommandAccess(client, "generic_admin", ADMFLAG_GENERIC, false))
    {
        return true;
    }

    return false;
}

public bool SCBL_Whitelist(int client)
{
	char Whitelisted[64];
	int i_Whitelisted;

	KeyValues Whitelist = CreateKeyValues("");
	Whitelist.ImportFromFile(FilePath);

	if(Whitelist.GotoFirstSubKey(true))
    {
        do
        {
			Whitelist.GetSectionName(ClientSteam[client], sizeof(ClientSteam));

			Whitelist.GetString("whitelist", Whitelisted, sizeof(Whitelisted), NULL_STRING);
			i_Whitelisted = StringToInt(Whitelisted);

			if(i_Whitelisted == 1) {
			    return true;
			}
			else
			{
				return false;
			}


        }
        while(Whitelist.GotoNextKey(true));
    }
	Whitelist.Rewind();

	return false;
}

void ProcessElement(char[] sKey, Handle hObj) {
	switch(json_typeof(hObj)) {
		case JSON_OBJECT: {
			StrCat(g_sPadding, sizeof(g_sPadding), "  ");
			IterateJsonObject(hObj);
			strcopy(g_sPadding, sizeof(g_sPadding), g_sPadding[2]);
		}

		 case JSON_ARRAY: {
			StrCat(g_sPadding, sizeof(g_sPadding), "  ");
			IterateJsonArray(hObj);
			strcopy(g_sPadding, sizeof(g_sPadding), g_sPadding[2]);
		}

		case JSON_STRING: {
			char sString[2024];
			json_string_value(hObj, sString, sizeof(sString));
			
			char GameCompare[10];
			IntToString(CurrentGameID, GameCompare, sizeof(GameCompare));
			
			for(int client = 1; client <= MaxClients; client++)
			{
				/*
					Second stage.
					Will ONLY kick the cheater if settings are correct.
				*/
				if(CurrentGameOnly && CurrentGameID > 0 && StrEqual(sKey, "app_id", false))
				{
					if(StrEqual(sString, GameCompare, false) && PlayerIsCheater[client])
					{
						if(!SCBL_Whitelist(client)) {
							CreateTimer(0.1, SourceCBLTimer, client);

							break;
						}
						else {
							SendConnectionData(client, "1");
						}
					}
				}
				
				/* First stage */
				if(StrEqual(sKey, "steam_id", false)) {
					if(StrEqual(sString, ClientSteam[client], false))
					{
						if(CurrentGameOnly)
						{
							PlayerIsCheater[client] = true;
						}
						else
						{
							if(!SCBL_Whitelist(client)) {
								CreateTimer(0.1, SourceCBLTimer, client);

								break;
							}
							else {
								SendConnectionData(client, "1");
							}
						}
						
						break;
					}

					break;
				}
			}
		}
	}
}

public Action SourceCBLTimer(Handle timer, int client)
{
	if(IsClientConnected(client))
	{
		SendConnectionData(client, "0");

		for(int admins = 0; admins <= MaxClients; admins++)
		{
			if(IsValidClient(admins))
			{
				if(IsPlayerGenericAdmin(admins))
				{
					PrintToChat(admins, "\x04[SourceCBL]\x05 Player \x04%N\x05 with Steam ID \x04%s\x05 is a marked cheater and has been kicked.", client, ClientSteam[client]);
				}
			}
		}
		
		PlayerIsCheater[client] = false;

		char Reason[255];
		Format(Reason, sizeof(Reason), "You have been banned by SourceCBL for cheating. Appeal the ban at www.SourceCBL.com");
		KickClientEx(client, Reason);
	}
}

stock bool IsValidClient(int client, bool isAlive=false)
{
    if(!client||client>MaxClients)    return false;
    if(isAlive) return IsClientInGame(client) && IsPlayerAlive(client);
    return IsClientInGame(client);
}

public int SendConnectionData(int client, char[] handled)
{
	// handled = 1 = allowed, 0 = blocked

	char[] s_URL = "http://sourcecbl.com/api/connections";
	Handle handle = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, s_URL);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "ip", port);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "hostname", hostname);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "steamid", ClientSteam[client]);
	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "handled", handled);
	SteamWorks_SendHTTPRequest(handle);
	CloseHandle(handle);
}

public void IterateJsonArray(Handle hArray) {
	for(int iElement = 0; iElement < json_array_size(hArray); iElement++) {
		Handle hValue = json_array_get(hArray, iElement);
		char sElement[4];
		IntToString(iElement, sElement, sizeof(sElement));
		ProcessElement(sElement, hValue);

		CloseHandle(hValue);
	}
}


public void IterateJsonObject(Handle hObj) {
	Handle hIterator = json_object_iter(hObj);

	while(hIterator != INVALID_HANDLE) {
		char sKey[128];
		json_object_iter_key(hIterator, sKey, sizeof(sKey));

		Handle hValue = json_object_iter_value(hIterator);

		ProcessElement(sKey, hValue);

		CloseHandle(hValue);
		hIterator = json_object_iter_next(hObj, hIterator);
	}
}

public void UploadDataString(int client)
{
	char s_URL[] = "http://sourcecbl.com/api/steam";

	Handle handle = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, s_URL);

	SteamWorks_SetHTTPRequestGetOrPostParameter(handle, "steamid", ClientSteam[client]);
	SteamWorks_SetHTTPRequestRawPostBody(handle, "application/json", s_URL, sizeof(s_URL));
	if (!handle || !SteamWorks_SetHTTPCallbacks(handle, HTTP_RequestComplete) || !SteamWorks_SendHTTPRequest(handle))
	{
		CloseHandle(handle);
	}
}

public int HTTP_RequestComplete(Handle HTTPRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if(!bRequestSuccessful) {
        LogError("[SourceCBL] An error occured while requesting the API.");
    } else {
		SteamWorks_GetHTTPResponseBodyCallback(HTTPRequest, APIWebResponse);

		CloseHandle(HTTPRequest);
    }
}


public int APIWebResponse(const char[] sData)
{
	Handle hObj = json_load(sData);
	
	ProcessElement("steam_id", hObj);
	ProcessElement("app_id", hObj);

	CloseHandle(hObj);
}

public void KillTimerSafe(Handle &hTimer)
{
	if(hTimer != INVALID_HANDLE)
	{
		KillTimer(hTimer);
		hTimer = INVALID_HANDLE;
	}
}

public Action AuthTimer(Handle timer, int client)
{
	if(IsClientInGame(client)) // We expect this to run only when they're in the game and not e.g. downloading content
	{
		if(GetClientAuthId(client, AuthId_SteamID64, ClientSteam[client], sizeof(ClientSteam)))
		{
			UploadDataString(client);
			KillTimerSafe(hAuthTimer[client]);
		}
		else
		{
			AuthTries[client]++;
			if(AuthTries[client] > 3)
			{
				char errorGettingData[255];
				Format(errorGettingData, sizeof(errorGettingData), "SourceCBL failed to retrieve your Steam ID after several tries, please reconnect and try again.");

				KillTimerSafe(hAuthTimer[client]);
				KickClientEx(client, errorGettingData);
			}
		}
	}
}

public int PanelHandler1(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		if(param2 == 1)
		{
			iSpecTarget[param1] = GetEntPropEnt(param1, Prop_Send, "m_hObserverTarget");

			if(!IsValidClient(iSpecTarget[param1]))
			{
				return;
			}

			PrintToChat(param1, "\x04[SourceCBL]\x05 SteamID32 of %N is %s", iSpecTarget[param1], TargetSteam32[iSpecTarget[param1]]);
		}
	}

	return;
}
