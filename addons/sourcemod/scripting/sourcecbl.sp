
#include <sdkhooks>
#include <sdktools>
#include <SteamWorks>
#include <smjansson>

#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL    "https://raw.githubusercontent.com/SirPurpleness/SourceCBL/master/updater.txt"

#pragma dynamic 1045840

char ClientSteam[MAXPLAYERS+1][255];
char g_sPadding[128] = "  ";
char FilePath[PLATFORM_MAX_PATH];
char port[32];
char hostname[64];

ConVar g_hCvarEnabled;

bool IsEnabled = true;

Handle hAuthTimer[MAXPLAYERS+1] = INVALID_HANDLE;
Handle gamePort;
Handle gameHostName;

int AuthTries[MAXPLAYERS+1] = 0;

public Plugin myinfo =
{
	name = "SourceBL",
	author = "SourceBL",
	description = "Allows communities to keep hackers/cheaters away from their servers by using a global database with stored information of hackers/cheaters.",
	version = "1.2",
}

public void OnPluginStart()
{
	g_hCvarEnabled = CreateConVar("sm_scbl_enabled", "1", "1 = Enabled (default), 0 = disabled.");
	HookConVarChange(g_hCvarEnabled, OnConVarChange);

	BuildPath(Path_SM, FilePath, sizeof(FilePath), "configs/sourcecbl_whitelist.txt");

	if(LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL)
    }
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
}

public void OnConfigsExecuted() {
	IsEnabled = GetConVarBool(g_hCvarEnabled);

	if(!IsEnabled) {
		ServerCommand("sm plugins unload sourcecbl");
	}
}

public void OnClientDisconnect(int client)
{
	AuthTries[client] = 0;
}

public void OnClientPutInServer(int client)
{
	AuthTries[client] = 0;
}

public void OnConVarChange(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsEnabled = GetConVarBool(g_hCvarEnabled);

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
	if(!IsFakeClient(client))
	{
		if(GetClientAuthId(client, AuthId_SteamID64, ClientSteam[client], sizeof(ClientSteam)))
		{
			UploadDataString(client);
		}
		else
		{
			LogError("[SourceCBL] Could not fetch Steam ID of client %N. Re-trying later.", client);
			hAuthTimer[client] = CreateTimer(180.0, AuthTimer, client, TIMER_REPEAT);
		}
	}
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
			char sString[1024];
			json_string_value(hObj, sString, sizeof(sString));

			for(int client = 1; client <= MaxClients; client++)
			{
				if(StrEqual(sKey, "steam_id", false)) {
					if(StrEqual(sString, ClientSteam[client], false))
					{
						if(!SCBL_Whitelist(client)) {
							CreateTimer(0.1, kickTimer, client);

							break;
						}
						else {
							SendConnectionData(client, "1");
						}
					}

					break;
				}
			}
		}
	}
}

public Action kickTimer(Handle timer, int client)
{
	if(IsClientConnected(client))
	{
		char kickReason[255];
		Format(kickReason, sizeof(kickReason), "You have been banned by SourceCBL for cheating. Visit www.SourceCBL.com for more information");

		SendConnectionData(client, "0");

		KickClientEx(client, kickReason);
	}
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
