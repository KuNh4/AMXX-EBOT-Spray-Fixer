/*================================================================================
    
    Plugin: [E-BOT] Spray Fixer
    Version: 2.0
    Author: KuNh4

    - Forces E-BOT LEGACY R12 bots to spray automatic weapons instead of tap firing;
    - Type 1: Smart Spray - Adapts spray behavior based on combat distance (Panic/Dynamic/Burst);
    - Type 2: Aim-Based - Fires only when crosshair is over enemy;
    - Grenade Handler: Makes bots fire grenade "more quickly";

    - Credits:
    -> @zerodiamond. for the "spray_type 2" idea in E-BOT Discord.
    
================================================================================*/

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <cstrike>
#include <engine>

#define PLUGIN_NAME     "[E-BOT] Spray Fixer"
#define PLUGIN_VERSION  "2.0"
#define PLUGIN_AUTHOR   "KuNh4"

// Hardcoded constants
#define MAX_SCALING_DIST    1800.0
#define DEFAULT_SPRAY       0.50
#define PANIC_DIST_DEFAULT  300.0

// Grenade timing
#define GRENADE_PIN_TIME    0.3

// Spray types
#define SPRAY_TYPE_LEGACY   1
#define SPRAY_TYPE_AIMBASED 2

// Weapon reload offsets
const m_fInReload = 54

// Spray states for debug tracking
enum _:SprayState
{
    STATE_NONE = 0,
    STATE_PANIC,
    STATE_DYNAMIC,
    STATE_BURST,
    STATE_AIMBASED
}

// Grenade state machine  
enum _:GrenadeState
{
    NADE_STATE_NONE = 0,
    NADE_STATE_WAIT_DEPLOY,
    NADE_STATE_PULL_PIN,
    NADE_STATE_WAIT_RELEASE,
    NADE_STATE_THROW
}

// Spray control timer per player
new Float:g_fStopSprayTime[33]

// Button state from previous frame (for edge detection)
new g_iOldButtons[33]

// Previous weapon ID (for weapon switch detection)
new g_iOldWeapon[33]

// Panic fire state (close range mag dump)
new bool:g_bPanicFire[33]

// Debug: Current spray state per bot
new g_iSprayState[33]

// Debug: Last debug print time per bot (flood protection)
new Float:g_fLastDebugTime[33]

// Grenade state per player
new g_iGrenadeState[33]
new Float:g_fGrenadePinTime[33]

// Grenade: force attack flag (set in PRE, applied in POST)
new bool:g_bForceNadeAttack[33]
new bool:g_bForceNadeRelease[33]

// Type 2: Track previous on-target state for debug
new bool:g_bWasOnTarget[33]

// Full-auto weapons list
new const g_iFullAutoWeapons[] = 
{
    CSW_AK47,
    CSW_M4A1,
    CSW_MP5NAVY,
    CSW_P90,
    CSW_GALIL,
    CSW_FAMAS,
    CSW_M249,
    CSW_TMP,
    CSW_MAC10,
    CSW_UMP45,
    CSW_SG552,
    CSW_AUG
}

// Grenade weapons list
new const g_iGrenadeWeapons[] =
{
    CSW_HEGRENADE,
    CSW_FLASHBANG,
    CSW_SMOKEGRENADE
}

// Cvars
new g_pCvarEnabled
new g_pCvarDebug
new g_pCvarPanicDistance
new g_pCvarMinTime
new g_pCvarMaxTime
new g_pCvarSprayType

// Cached cvar values
new g_iEnabled
new g_iDebugEnabled
new Float:g_fPanicDistance
new Float:g_fMinTime
new Float:g_fMaxTime
new g_iSprayType

/*================================================================================
 [Plugin Init]
================================================================================*/

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)
    
    register_forward(FM_CmdStart, "fw_CmdStart_Pre", 0)
    
    register_forward(FM_CmdStart, "fw_CmdStart_Post", 1)
    
    // Cvars
    g_pCvarEnabled = register_cvar("ebot_spray", "1")
    g_pCvarDebug = register_cvar("ebot_spray_debug", "0")
    g_pCvarPanicDistance = register_cvar("ebot_spray_distance", "300.0")
    g_pCvarMinTime = register_cvar("ebot_spray_min_time", "0.3")
    g_pCvarMaxTime = register_cvar("ebot_spray_max_time", "2.0")
    g_pCvarSprayType = register_cvar("ebot_spray_type", "1")
    
    // Bind cvars for auto-update
    bind_pcvar_num(g_pCvarEnabled, g_iEnabled)
    bind_pcvar_num(g_pCvarDebug, g_iDebugEnabled)
    bind_pcvar_float(g_pCvarPanicDistance, g_fPanicDistance)
    bind_pcvar_float(g_pCvarMinTime, g_fMinTime)
    bind_pcvar_float(g_pCvarMaxTime, g_fMaxTime)
    bind_pcvar_num(g_pCvarSprayType, g_iSprayType)
    
    register_srvcmd("ebot_spray_info", "ServerCmd_Info")
    
    server_print("[E-BOT Spray Fixer] Plugin loaded successfully! [Type ebot_spray_info]")
}

public plugin_cfg()
{
    server_cmd("exec addons/amxmodx/configs/ebot_spray_fixer.cfg")
}

public ServerCmd_Info()
{
    server_print("========================================")
    server_print(" %s v%s by %s", PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)
    server_print("========================================")
    server_print(" [E-BOT] Smart Spray System]")
    server_print(" Enabled: %s", g_iEnabled ? "YES" : "NO")
    server_print(" Debug: %s", g_iDebugEnabled ? "ON" : "OFF")
    server_print(" Spray Type: %d (%s)", g_iSprayType, 
        g_iSprayType == SPRAY_TYPE_AIMBASED ? "Aim-Based" : "Legacy Time-Based")
    server_print("----------------------------------------")
    
    if (g_iSprayType == SPRAY_TYPE_LEGACY)
    {
        server_print(" [Type 1: Distance-Based]")
        server_print(" Panic Distance: %.1f units", g_fPanicDistance)
        server_print(" Min Spray Time: %.2fs (at %.0f units)", g_fMinTime, MAX_SCALING_DIST)
        server_print(" Max Spray Time: %.2fs (at panic range)", g_fMaxTime)
        server_print(" Default Spray: %.2fs (no target)", DEFAULT_SPRAY)
        server_print(" Max Scaling Dist: %.0f units", MAX_SCALING_DIST)
    }
    else
    {
        server_print(" [Type 2: Aim-Based]")
        server_print(" Logic: Fires only when crosshair is on enemy")
    }
    
    server_print("----------------------------------------")
    server_print(" [Grenade Handler]")
    server_print(" Mode: Immediate Throw")
    server_print(" Pin Hold Time: %.2fs", GRENADE_PIN_TIME)
    server_print("========================================")
    
    return PLUGIN_HANDLED
}

public fw_CmdStart_Pre(id, uc_handle, seed)
{
    // Reset grenade flags
    g_bForceNadeAttack[id] = false
    g_bForceNadeRelease[id] = false
    
    // Check master switch
    if (!g_iEnabled)
        return FMRES_IGNORED
    
    // Only process bots
    if (!is_user_bot(id))
        return FMRES_IGNORED
    
    // Ignore dead players
    if (!is_user_alive(id))
        return FMRES_IGNORED
    
    // Get current weapon
    new iWeapon = get_user_weapon(id)
    
    // ============================================================
    // WEAPON SWITCH DETECTION - Reset ALL states on change
    // ============================================================
    
    if (iWeapon != g_iOldWeapon[id])
    {
        // Reset spray states
        g_fStopSprayTime[id] = 0.0
        g_iOldButtons[id] = 0
        g_bPanicFire[id] = false
        g_iSprayState[id] = STATE_NONE
        g_bWasOnTarget[id] = false
        
        // Reset grenade states
        g_iGrenadeState[id] = NADE_STATE_NONE
        g_fGrenadePinTime[id] = 0.0
        
        g_iOldWeapon[id] = iWeapon
    }
    
    // ============================================================
    // GRENADE HANDLER
    // ============================================================
    
    if (IsGrenadeWeapon(iWeapon))
    {
        HandleGrenadeLogic(id, uc_handle)
        return FMRES_IGNORED
    }
    else
    {
        // Reset grenade state when not holding grenade
        g_iGrenadeState[id] = NADE_STATE_NONE
        g_fGrenadePinTime[id] = 0.0
    }
    
    // ============================================================
    // SPRAY LOGIC (Full-Auto Weapons Only)
    // ============================================================
    
    // Check if weapon is full-auto
    if (!IsFullAutoWeapon(iWeapon))
        return FMRES_IGNORED
    
    // Get weapon entity
    new iWeaponEnt = get_pdata_cbase(id, 373)
    
    if (!pev_valid(iWeaponEnt))
        return FMRES_IGNORED
    
    // Safety checks: clip empty or reloading
    new iClip = cs_get_weapon_ammo(iWeaponEnt)
    new iReloading = get_pdata_int(iWeaponEnt, m_fInReload, 4)
    
    if (iClip <= 0 || iReloading)
    {
        g_fStopSprayTime[id] = 0.0
        g_iOldButtons[id] = 0
        g_bPanicFire[id] = false
        g_iSprayState[id] = STATE_NONE
        g_bWasOnTarget[id] = false
        return FMRES_IGNORED
    }
    
    // Branch based on spray type
    if (g_iSprayType == SPRAY_TYPE_AIMBASED)
    {
        return HandleSprayType2_AimBased(id, uc_handle)
    }
    else
    {
        return HandleSprayType1_Legacy(id, uc_handle)
    }
}

/*================================================================================
 [Type 1: Distance base dynamic spray]
================================================================================*/

HandleSprayType1_Legacy(id, uc_handle)
{
    // Get button state
    new iButtons = get_uc(uc_handle, UC_Buttons)
    new Float:fGameTime = get_gametime()
    
    // Edge Detection
    new bool:bIsAttackPressed = (iButtons & IN_ATTACK) ? true : false
    new bool:bWasAttackPressed = (g_iOldButtons[id] & IN_ATTACK) ? true : false
    
    // Target Acquisition
    new iTarget, iBody
    new Float:fDistance = 9999.0
    new bool:bHasTarget = false
    
    if (bIsAttackPressed || g_bPanicFire[id])
    {
        get_user_aiming(id, iTarget, iBody)
        
        if (iTarget > 0 && iTarget <= MaxClients)
        {
            if (is_user_alive(iTarget) && IsEnemy(id, iTarget))
            {
                bHasTarget = true
                
                new Float:fBotOrigin[3], Float:fTargetOrigin[3]
                pev(id, pev_origin, fBotOrigin)
                pev(iTarget, pev_origin, fTargetOrigin)
                fDistance = get_distance_f(fBotOrigin, fTargetOrigin)
            }
        }
    }
    
    new iOldState = g_iSprayState[id]
    new Float:fSprayDuration = 0.0
    
    // MODE A: PANIC
    if (bHasTarget && fDistance < g_fPanicDistance)
    {
        g_bPanicFire[id] = true
        g_iSprayState[id] = STATE_PANIC
        
        iButtons |= IN_ATTACK
        set_uc(uc_handle, UC_Buttons, iButtons)
        
        g_fStopSprayTime[id] = 0.0
        g_iOldButtons[id] = iButtons
        
        DebugPrintState(id, iOldState, fDistance, 0.0)
        return FMRES_IGNORED
    }
    
    if (g_bPanicFire[id])
    {
        if (!bHasTarget || fDistance >= g_fPanicDistance)
        {
            g_bPanicFire[id] = false
        }
        else
        {
            iButtons |= IN_ATTACK
            set_uc(uc_handle, UC_Buttons, iButtons)
            g_iOldButtons[id] = iButtons
            
            DebugPrintState(id, iOldState, fDistance, 0.0)
            return FMRES_IGNORED
        }
    }
    
    // MODE B: DYNAMIC
    if (bHasTarget && fDistance >= g_fPanicDistance && fDistance < MAX_SCALING_DIST)
    {
        if (bIsAttackPressed && !bWasAttackPressed)
        {
            fSprayDuration = CalculateSprayDuration(fDistance)
            g_fStopSprayTime[id] = fGameTime + fSprayDuration
            g_iSprayState[id] = STATE_DYNAMIC
            
            DebugPrintState(id, iOldState, fDistance, fSprayDuration)
        }
        
        if (fGameTime < g_fStopSprayTime[id])
        {
            iButtons |= IN_ATTACK
            set_uc(uc_handle, UC_Buttons, iButtons)
        }
        else if (g_iSprayState[id] == STATE_DYNAMIC)
        {
            g_iSprayState[id] = STATE_NONE
        }
        
        g_iOldButtons[id] = iButtons
        return FMRES_IGNORED
    }
    
    // MODE C: BURST
    if (bIsAttackPressed && !bWasAttackPressed)
    {
        if (bHasTarget)
            fSprayDuration = g_fMinTime
        else
            fSprayDuration = DEFAULT_SPRAY
        
        g_fStopSprayTime[id] = fGameTime + fSprayDuration
        g_iSprayState[id] = STATE_BURST
        
        DebugPrintState(id, iOldState, fDistance, fSprayDuration)
    }
    
    if (fGameTime < g_fStopSprayTime[id])
    {
        iButtons |= IN_ATTACK
        set_uc(uc_handle, UC_Buttons, iButtons)
    }
    else
    {
        if (g_iSprayState[id] == STATE_BURST)
            g_iSprayState[id] = STATE_NONE
    }
    
    g_iOldButtons[id] = get_uc(uc_handle, UC_Buttons)
    
    return FMRES_IGNORED
}

/*================================================================================
 [Type 2: Aim-Based Spray]
 Fires only when crosshair is directly over an enemy target.
================================================================================*/

HandleSprayType2_AimBased(id, uc_handle)
{
    // Get current button state
    new iButtons = get_uc(uc_handle, UC_Buttons)
    
    // Check if crosshair is over an enemy
    new iTarget, iBody
    get_user_aiming(id, iTarget, iBody)
    
    new bool:bOnTarget = false
    new Float:fDistance = 9999.0
    
    // Validate target
    if (iTarget > 0 && iTarget <= MaxClients)
    {
        if (is_user_alive(iTarget) && IsEnemy(id, iTarget))
        {
            bOnTarget = true
            
            // Calculate distance for debug
            new Float:fBotOrigin[3], Float:fTargetOrigin[3]
            pev(id, pev_origin, fBotOrigin)
            pev(iTarget, pev_origin, fTargetOrigin)
            fDistance = get_distance_f(fBotOrigin, fTargetOrigin)
        }
    }
    
    // Debug: Detect state transitions
    new bool:bStateChanged = (bOnTarget != g_bWasOnTarget[id])
    
    if (bOnTarget)
    {
        // ============================================================
        // ON TARGET: Force attack button DOWN
        // ============================================================
        iButtons |= IN_ATTACK
        set_uc(uc_handle, UC_Buttons, iButtons)
        
        // Update state
        g_iSprayState[id] = STATE_AIMBASED
        
        // Debug output on state change
        if (bStateChanged && g_iDebugEnabled)
        {
            new szBotName[32]
            get_user_name(id, szBotName, charsmax(szBotName))
            
            client_print_color(0, print_team_default, 
                "^4[E-BOT Spray Fixer]^1 ^3%s^1 [AIM-BASED] ON TARGET - Dist: ^4%.0f^1 - ^3SHOOTING!", 
                szBotName, fDistance)
        }
    }
    else
    {
        // ============================================================
        // OFF TARGET: Force attack button UP (release)
        // ============================================================
        iButtons &= ~IN_ATTACK
        set_uc(uc_handle, UC_Buttons, iButtons)
        
        // Update state
        g_iSprayState[id] = STATE_NONE
        
        // Debug output on state change
        if (bStateChanged && g_iDebugEnabled)
        {
            new szBotName[32]
            get_user_name(id, szBotName, charsmax(szBotName))
            
            client_print_color(0, print_team_default, 
                "^4[E-BOT Spray Fixer]^1 ^3%s^1 [AIM-BASED] Crosshair OFF TARGET - ^1Recoil control", 
                szBotName)
        }
    }
    
    // Store current state for next frame comparison
    g_bWasOnTarget[id] = bOnTarget
    g_iOldButtons[id] = iButtons
    
    return FMRES_IGNORED
}

/*================================================================================
 [FM_CmdStart - POST Hook]
 Applies grenade button forcing AFTER E-Bot has processed
================================================================================*/

public fw_CmdStart_Post(id, uc_handle, seed)
{
    if (!g_iEnabled)
        return FMRES_IGNORED
    
    if (!is_user_bot(id) || !is_user_alive(id))
        return FMRES_IGNORED
    
    // Apply grenade attack forcing
    if (g_bForceNadeAttack[id])
    {
        new iButtons = get_uc(uc_handle, UC_Buttons)
        iButtons |= IN_ATTACK
        iButtons &= ~IN_ATTACK2
        set_uc(uc_handle, UC_Buttons, iButtons)
        
        // Also force pev->button
        new iPevButtons = pev(id, pev_button)
        iPevButtons |= IN_ATTACK
        iPevButtons &= ~IN_ATTACK2
        set_pev(id, pev_button, iPevButtons)
    }
    else if (g_bForceNadeRelease[id])
    {
        new iButtons = get_uc(uc_handle, UC_Buttons)
        iButtons &= ~IN_ATTACK
        iButtons &= ~IN_ATTACK2
        set_uc(uc_handle, UC_Buttons, iButtons)
        
        // Also force pev->button
        new iPevButtons = pev(id, pev_button)
        iPevButtons &= ~IN_ATTACK
        iPevButtons &= ~IN_ATTACK2
        set_pev(id, pev_button, iPevButtons)
    }
    
    return FMRES_IGNORED
}

/*================================================================================
 [Grenade Logic Handler]
================================================================================*/

HandleGrenadeLogic(id, uc_handle)
{
    new Float:fGameTime = get_gametime()
    
    // Get weapon entity
    new iWeaponEnt = get_pdata_cbase(id, 373)
    
    if (!pev_valid(iWeaponEnt))
        return
    
    // Check m_flStartThrow - if > 0, grenade pin is pulled
    new Float:fStartThrow = get_pdata_float(iWeaponEnt, 30, 4)
    
    // If pin is already pulled, release to throw
    if (fStartThrow > 0.0)
    {
        g_bForceNadeRelease[id] = true
        g_iGrenadeState[id] = NADE_STATE_THROW
        return
    }
    
    // Initialize state
    if (g_iGrenadeState[id] == NADE_STATE_NONE)
    {
        g_iGrenadeState[id] = NADE_STATE_WAIT_DEPLOY
        g_fGrenadePinTime[id] = fGameTime + 0.5
    }
    
    switch (g_iGrenadeState[id])
    {
        case NADE_STATE_WAIT_DEPLOY:
        {
            if (fGameTime >= g_fGrenadePinTime[id])
            {
                g_iGrenadeState[id] = NADE_STATE_PULL_PIN
                g_fGrenadePinTime[id] = fGameTime + GRENADE_PIN_TIME
            }
        }
        case NADE_STATE_PULL_PIN:
        {
            // Force attack to pull pin
            g_bForceNadeAttack[id] = true
            
            new iButtons = get_uc(uc_handle, UC_Buttons)
            iButtons |= IN_ATTACK
            set_uc(uc_handle, UC_Buttons, iButtons)
            
            // Timeout failsafe
            if (fGameTime >= g_fGrenadePinTime[id])
            {
                g_iGrenadeState[id] = NADE_STATE_THROW
            }
        }
        case NADE_STATE_THROW:
        {
            // Release to throw
            g_bForceNadeRelease[id] = true
        }
    }
}

/*================================================================================
 [Debug Functions]
================================================================================*/

DebugPrintState(id, iOldState, Float:fDistance, Float:fDuration)
{
    if (!g_iDebugEnabled)
        return
    
    new iCurrentState = g_iSprayState[id]
    new Float:fGameTime = get_gametime()
    
    new bool:bStateChanged = (iCurrentState != iOldState)
    new bool:bTimeElapsed = (fGameTime - g_fLastDebugTime[id] >= 1.0)
    
    if (!bStateChanged && !bTimeElapsed)
        return
    
    g_fLastDebugTime[id] = fGameTime
    
    new szBotName[32]
    get_user_name(id, szBotName, charsmax(szBotName))
    
    switch (iCurrentState)
    {
        case STATE_PANIC:
        {
            client_print_color(0, print_team_default, 
                "^4[E-BOT Spray Fixer]^1 ^3%s^1 [PANIC] Dist: ^4%.0f^1 - ^3FULL SPRAY!", 
                szBotName, fDistance)
        }
        case STATE_DYNAMIC:
        {
            client_print_color(0, print_team_default, 
                "^4[E-BOT Spray Fixer]^1 ^3%s^1 [DYNAMIC] Dist: ^4%.0f^1 - Spray: ^4%.2fs", 
                szBotName, fDistance, fDuration)
        }
        case STATE_BURST:
        {
            if (fDistance < 9000.0)
            {
                client_print_color(0, print_team_default, 
                    "^4[E-BOT Spray Fixer]^1 ^3%s^1 [BURST] Dist: ^4%.0f^1 - Spray: ^4%.2fs", 
                    szBotName, fDistance, fDuration)
            }
            else
            {
                client_print_color(0, print_team_default, 
                    "^4[E-BOT Spray Fixer]^1 ^3%s^1 [BURST] No Target - Spray: ^4%.2fs", 
                    szBotName, fDuration)
            }
        }
    }
}

/*================================================================================
 [Helper Functions]
================================================================================*/

Float:CalculateSprayDuration(Float:fDistance)
{
    if (fDistance <= g_fPanicDistance)
        return g_fMaxTime
    
    if (fDistance >= MAX_SCALING_DIST)
        return g_fMinTime
    
    new Float:fDistRange = MAX_SCALING_DIST - g_fPanicDistance
    new Float:fTimeRange = g_fMaxTime - g_fMinTime
    new Float:fDistRatio = (fDistance - g_fPanicDistance) / fDistRange
    
    new Float:fDuration = g_fMaxTime - (fDistRatio * fTimeRange)
    
    return fDuration
}

bool:IsFullAutoWeapon(iWeaponID)
{
    for (new i = 0; i < sizeof(g_iFullAutoWeapons); i++)
    {
        if (iWeaponID == g_iFullAutoWeapons[i])
            return true
    }
    
    return false
}

bool:IsGrenadeWeapon(iWeaponID)
{
    for (new i = 0; i < sizeof(g_iGrenadeWeapons); i++)
    {
        if (iWeaponID == g_iGrenadeWeapons[i])
            return true
    }
    
    return false
}

bool:IsEnemy(id, iTarget)
{
    new CsTeams:iTeam1 = cs_get_user_team(id)
    new CsTeams:iTeam2 = cs_get_user_team(iTarget)
    
    return (iTeam1 != iTeam2)
}

/*================================================================================
 [Client Events]
================================================================================*/

public client_putinserver(id)
{
    g_iOldButtons[id] = 0
    g_iOldWeapon[id] = 0
    g_fStopSprayTime[id] = 0.0
    g_bPanicFire[id] = false
    g_iSprayState[id] = STATE_NONE
    g_fLastDebugTime[id] = 0.0
    g_iGrenadeState[id] = NADE_STATE_NONE
    g_fGrenadePinTime[id] = 0.0
    g_bForceNadeAttack[id] = false
    g_bForceNadeRelease[id] = false
    g_bWasOnTarget[id] = false
}

public client_disconnected(id)
{
    g_iOldButtons[id] = 0
    g_iOldWeapon[id] = 0
    g_fStopSprayTime[id] = 0.0
    g_bPanicFire[id] = false
    g_iSprayState[id] = STATE_NONE
    g_fLastDebugTime[id] = 0.0
    g_iGrenadeState[id] = NADE_STATE_NONE
    g_fGrenadePinTime[id] = 0.0
    g_bForceNadeAttack[id] = false
    g_bForceNadeRelease[id] = false
    g_bWasOnTarget[id] = false
}