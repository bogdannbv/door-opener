#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME "DoorOpener"
#define PLUGIN_VERSION "0.1.0"
#define PLUGIN_ENABLED_DEFAULT "1"

#define KV_CONFIG_FILE "door-opener.cfg"
#define KV_CONFIG_ROOT_KEY "maps"

#define MAXENTITIES 2048

#define DOOR_REMOVE_DEFAULT 0
#define DOOR_TOGGLE_DEFAULT 0
#define DOOR_INTERVAL_DEFAULT 20.0

#define GetEntityName(%1,%2,%3) GetEntPropString(%1, Prop_Data, "m_iName", %2, %3)

ConVar CvarEnabled = null;

KeyValues KvConfig;

char KvConfigFilePath[PLATFORM_MAX_PATH];

Handle DoorOpenTimers[MAXENTITIES];
int DoorOpenTimersCounter = 0;

int EntityDetectingClient = 0;

char ValidDoorClasses[][] = {
	"func_movelinear",
	"func_door",
	"func_door_rotating",
	"prop_door_rotating"
};

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = "BogdanNBV",
	description = "A plugin that periodically opens doors.",
	version = PLUGIN_VERSION,
	url = "https://github.com/bogdannbv/door-opener"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion engineVersion = GetEngineVersion();
	if (engineVersion != Engine_CSS)
	{
		LogMessage("[WARNING] This plugin was tested ONLY on Counter-Strike: Source. Your mileage may vary.");
	}
}

public void OnPluginStart()
{
	AutoExecConfig(true);
	LoadKvConfig();
	RegisterConVars();
	RegisterAdminCmds();
	RegisterEventHooks();

	CreateTimer(0.1, ShowHudDetectedEntity, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
	if (client == EntityDetectingClient) {
		EntityDetectingClient = 0;
	}
}

public void RegisterConVars()
{
	CreateConVar("sm_door-opener_version", PLUGIN_VERSION, "DoorOpener version.", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD|FCVAR_SPONLY);

	CvarEnabled = CreateConVar("sm_door-opener_enabled", PLUGIN_ENABLED_DEFAULT, "Determines if the plugin should be enabled.", FCVAR_NOTIFY|FCVAR_REPLICATED);
}

public void RegisterAdminCmds()
{
	RegAdminCmd("sm_detectentstart", StartAimEntityDetectCommand, ADMFLAG_CONVARS, "Starts aim entity detection.");
	RegAdminCmd("sm_detectentstop", StopAimEntityDetectCommand, ADMFLAG_CONVARS, "Stops aim entity detection.");
	RegAdminCmd("sm_savedoor", SaveDoorCommand, ADMFLAG_CONVARS, "Saves the aim detected door.");
	RegAdminCmd("sm_deletedoor", DeleteDoorCommand, ADMFLAG_CONVARS, "Deletes the aim detected door.");
	RegAdminCmd("sm_showmapdoors", ShowMapDoorsCommand, ADMFLAG_CONVARS, "Shows all the saved doors on the current map and their configuration.");
}

public void RegisterEventHooks()
{
	HookEvent("round_start", EventRoundStartHandler, EventHookMode_PostNoCopy);
	HookEvent("round_end", EventRoundEndHandler, EventHookMode_PostNoCopy);
}

public Action StartAimEntityDetectCommand(int client, int argc)
{
	if (EntityDetectingClient != 0 && EntityDetectingClient != client) {
		CReplyToCommand(client, "[{green}%s{default}] Sorry, there's already someone using the plugin.", PLUGIN_NAME);
		return Plugin_Continue;
	}

	EntityDetectingClient = client;

	return Plugin_Continue;
}

public Action StopAimEntityDetectCommand(int client, int argc)
{
	EntityDetectingClient = 0;
	return Plugin_Continue;
}

public Action SaveDoorCommand(int client, int argc)
{
	char usage[256];
	FormatEx(usage, sizeof(usage), "[{green}%s{default}] Usage: {green}!savedoor{default} <interval>|toggle|remove", PLUGIN_NAME);

	if (argc != 1) {
		CReplyToCommand(client, usage);
		return Plugin_Continue;
	}

	int remove = DOOR_REMOVE_DEFAULT;
	int toggle = DOOR_TOGGLE_DEFAULT;
	float interval = DOOR_INTERVAL_DEFAULT;

	char buffer[32];
	GetCmdArg(1, buffer, sizeof(buffer));

	if (StrEqual(buffer, "toggle", true)) {
		toggle = 1;
	} else if (StrEqual(buffer, "remove", true)) {
		remove = 1;
	} else if (StringToFloat(buffer) >= 0.0) {
		interval = StringToFloat(buffer);
	} else {
		CReplyToCommand(client, usage);
		return Plugin_Continue;
	}

	int entityId = GetClientAimEntityId(client);

	if (entityId == -1) {
		CReplyToCommand(client, "[{green}%s{default}] No entity found. Please make sure you're looking at the door.", PLUGIN_NAME);
	}

	char name[64];
	char class[64];
	GetEntityName(entityId, name, sizeof(name));
	GetEntityClassname(entityId, class, sizeof(class));

	if (!IsValidDoorClass(class)) {
		if (StrEqual(name, "")) {
			strcopy(name, sizeof(name), "N\\A");
		}
		CReplyToCommand(client, "[{green}%s{default}] Entity {green}%s{default}(class:{green}%s{default}) is not a valid door.", PLUGIN_NAME, name, class);
		return Plugin_Continue;
	}

	SaveDoor(name, class, interval, remove, toggle);

	CReplyToCommand(client, "[{green}%s{default}] Success, the door {green}%s{default} (class:{green}%s{default}, interval: {green}%f{default}, remove:{green}%d{default}, toggle:{green}%d{default}) has been saved!", PLUGIN_NAME, name, class, interval, remove, toggle);

	return Plugin_Continue;
}

public Action DeleteDoorCommand(int client, int argc)
{
	char usage[256];
	FormatEx(usage, sizeof(usage), "[{green}%s{default}] Usage: {green}!deletedoor{default} <name>", PLUGIN_NAME);

	if (argc != 1) {
		CReplyToCommand(client, usage);
		return Plugin_Continue;
	}

	char name[64];
	GetCmdArg(1, name, sizeof(name));

	DeleteDoor(name);

	return Plugin_Continue;
}

public Action ShowMapDoorsCommand(int client, int argc)
{
	char currentMapName[128];
	GetCurrentMap(currentMapName, sizeof(currentMapName));

	if (!KvConfig.JumpToKey(currentMapName)) {
		KvConfig.Rewind();
		return Plugin_Continue;
	}

	if (!KvConfig.GotoFirstSubKey()) {
		KvConfig.Rewind();
		return Plugin_Continue;
	}

	char name[64];
	char class[64];
	int remove;
	int toggle;
	float interval;

	CReplyToCommand(client, "[{green}%s{default}] All the saved doors on this map:", PLUGIN_NAME);

	do {

		KvConfig.GetSectionName(name, sizeof(name));
		KvConfig.GetString("class", class, sizeof(class));
		remove = KvConfig.GetNum("remove", DOOR_REMOVE_DEFAULT);
		toggle = KvConfig.GetNum("toggle", DOOR_TOGGLE_DEFAULT);
		interval = KvConfig.GetFloat("interval", DOOR_INTERVAL_DEFAULT);

		CReplyToCommand(client, "{green}%s{default} (class:{green}%s{default}, interval: {green}%f{default}, remove:{green}%d{default}, toggle:{green}%d{default})", name, class, interval, remove, toggle);


	} while (KvConfig.GotoNextKey());

	KvConfig.Rewind();

	return Plugin_Continue;
}

public int GetClientAimEntityId(int client)
{
	return GetClientAimTarget(client, false);
}

public Action ShowHudDetectedEntity(Handle timer)
{
	if (EntityDetectingClient == 0) {
		return Plugin_Continue;
	}

	int entityId = GetClientAimEntityId(EntityDetectingClient);

	if (entityId == -1) {
		return Plugin_Continue;
	}

	char name[64];
	char class[64];
	GetEntityName(entityId, name, sizeof(name));
	GetEntityClassname(entityId, class, sizeof(class));

	PrintHintText(EntityDetectingClient, "Name: %s\nClass: %s", name, class);

	return Plugin_Continue;
}

public void LoadKvConfig()
{
	KvConfig = new KeyValues(KV_CONFIG_ROOT_KEY);

	BuildPath(Path_SM, KvConfigFilePath, sizeof(KvConfigFilePath), "%s/%s", "configs", KV_CONFIG_FILE);

	if (!FileExists(KvConfigFilePath)) {
		PrintToServer("Configuration file \"%s\" not found. Creating default one.", KvConfigFilePath);
		KvConfig.ExportToFile(KvConfigFilePath);
	}

	if (!KvConfig.ImportFromFile(KvConfigFilePath)) {
		SetFailState("Unable to find \"%s\" key inside \"%s\".", KV_CONFIG_ROOT_KEY, KvConfigFilePath);
	}
}

public Action EventRoundStartHandler(Event event, const char[] eventName, bool dontBroadcast)
{
	if (!CvarEnabled.BoolValue) {
		return Plugin_Continue;
	}

	CloseTimers();

	char currentMapName[128];
	GetCurrentMap(currentMapName, sizeof(currentMapName));

	if (!KvConfig.JumpToKey(currentMapName)) {
		KvConfig.Rewind();
		return Plugin_Continue;
	}

	if (!KvConfig.GotoFirstSubKey()) {
		KvConfig.Rewind();
		return Plugin_Continue;
	}

	char name[64];
	char class[64];
	int remove;
	int toggle;
	float interval;

	do {

		KvConfig.GetSectionName(name, sizeof(name));
		KvConfig.GetString("class", class, sizeof(class));
		remove = KvConfig.GetNum("remove", DOOR_REMOVE_DEFAULT);
		toggle = KvConfig.GetNum("toggle", DOOR_TOGGLE_DEFAULT);
		interval = KvConfig.GetFloat("interval", DOOR_INTERVAL_DEFAULT);

		if (remove == 1) {
			RemoveDoor(name, class);
			continue;
		}

		if (toggle == 1) {
			ToggleDoor(name, class);
			continue;
		}

		if (interval > 0.0) {
			DataPack pack;

			DoorOpenTimers[DoorOpenTimersCounter] = CreateDataTimer(interval, OpenDoorDataTimerHandler, pack, TIMER_REPEAT);

			pack.WriteString(name);
			pack.WriteString(class);

			DoorOpenTimersCounter++;
		}

	} while (KvConfig.GotoNextKey());

	KvConfig.Rewind();

	return Plugin_Continue;
}

public Action EventRoundEndHandler(Event event, const char[] eventName, bool dontBroadcast)
{
	CloseTimers();

	return Plugin_Continue;
}

public void CloseTimers()
{
	for (int i = 0; i < DoorOpenTimersCounter; i++) {
		delete DoorOpenTimers[i];
	}
	DoorOpenTimersCounter = 0;
}

public Action OpenDoorDataTimerHandler(Handle timer, DataPack pack)
{
	char name[64];
	char class[64];

	pack.Reset();
	pack.ReadString(name, sizeof(name));
	pack.ReadString(class, sizeof(class));

	OpenDoor(name, class);

	return Plugin_Continue;
}

public void OpenDoor(const char[] name, const char[] class)
{
	if (!IsValidDoorClass(class)) {
		return;
	}

	EntityInput(name, class, "Open");
}

public void CloseDoor(const char[] name, const char[] class)
{
	if (!IsValidDoorClass(class)) {
		return;
	}

	EntityInput(name, class, "Close");
}

public void ToggleDoor(const char[] name, const char[] class)
{
	if (!IsValidDoorClass(class)) {
		return;
	}

	if (StrEqual("func_movelinear", class, true)) {
		EntityInput(name, class, "Open");
		EntityInput(name, class, "Close");
		return;
	}

	EntityInput(name, class, "Toggle");
}

public void RemoveDoor(const char[] name, const char[] class)
{
	int entityIds[MAXENTITIES];
	int entityCount;

	entityCount = FindAllEntityIds(name, class, entityIds, sizeof(entityIds));

	for (int i = 0; i < entityCount; i++) {
		RemoveEdict(entityIds[i]);
	}
}

void SaveDoor(
	const char[] name,
	const char[] class,
	float interval = DOOR_INTERVAL_DEFAULT,
	int remove = DOOR_REMOVE_DEFAULT,
	int toggle = DOOR_TOGGLE_DEFAULT)
{
	char currentMapName[128];
	GetCurrentMap(currentMapName, sizeof(currentMapName));

	KvConfig.JumpToKey(currentMapName, true);
	KvConfig.JumpToKey(name, true);
	KvConfig.SetString("class", class);
	KvConfig.SetNum("remove", remove);
	KvConfig.SetNum("toggle", toggle);
	KvConfig.SetFloat("interval", interval);

	KvConfig.Rewind();

	KvConfig.ExportToFile(KvConfigFilePath);
}

void DeleteDoor(const char[] name)
{
	char currentMapName[128];
	GetCurrentMap(currentMapName, sizeof(currentMapName));

	KvConfig.JumpToKey(currentMapName);
	KvConfig.JumpToKey(name);
	KvConfig.DeleteThis();

	KvConfig.Rewind();

	KvConfig.ExportToFile(KvConfigFilePath);
}

public int EntityInput(const char[] name, const char[] class, const char[] input)
{
	int entityIds[MAXENTITIES];
	int entityCount;

	entityCount = FindAllEntityIds(name, class, entityIds, sizeof(entityIds));

	for (int i = 0; i < entityCount; i++) {
		AcceptEntityInput(entityIds[i], input);
	}

	return entityCount;
}

public int FindAllEntityIds(const char[] name, const char[] class, int[] entityIds, int maxEntityIds)
{
	int entityCount = 0;
	char entityClass[64];
	char entityName[64];

	for (int i = 0; i < maxEntityIds; i++) {
		if (!IsValidEntity(i)) {
			continue;
		}

		GetEntityClassname(i, entityClass, sizeof(entityClass));
		if (!StrEqual(class, entityClass)) {
			continue;
		}

		GetEntityName(i, entityName, sizeof(entityName));
		if (!StrEqual(name, entityName)) {
			continue;
		}

		entityIds[entityCount] = i;
		entityCount++;
	}

	return entityCount;
}

public bool IsValidDoorClass(const char[] class)
{
	for (int i = 0; i < sizeof(ValidDoorClasses); i++) {
		if (StrEqual(ValidDoorClasses[i], class, true)) {
			return true;
		}
	}

	return false;
}
