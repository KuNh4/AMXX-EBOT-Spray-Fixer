/*================================================================================
    
    Plugin: [E-BOT] Spray Fixer
    Version: 1.0
    Author: KuNh4

    - Forces E-BOT LEGACY R12 bots to spray automatic weapons instead of tap firing;
    - Intercepts button inputs via FM_CmdStart;
    - Only affects full-auto weapons;
    - Uses edge detection to prevent infinite spray loops;
    
================================================================================*/

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <cstrike>

#define PLUGIN_NAME     "[E-BOT] Spray Fixer"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "KuNh4"

// Weapon reload offsets
const m_fInReload = 54

// Spray control timer per player
new Float:g_fStopSprayTime[33]

// Button state from previous frame (for edge detection)
new g_iOldButtons[33]

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

// Cvars
new g_pCvarSprayDuration

/*================================================================================
 [Plugin Init]
================================================================================*/

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)
    
    register_forward(FM_CmdStart, "fw_CmdStart")
    
    // Cvars
    g_pCvarSprayDuration = register_cvar("ebot_spray_duration", "1.5")

    register_srvcmd("ebot_spray_info", "ServerCmd_Info")
    
    server_print("[E-BOT Spray Fixer] Plugin has loaded successfully! [Type ebot_spray_info]")
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
    server_print(" Spray Duration: %.1f seconds", get_pcvar_float(g_pCvarSprayDuration))
    server_print(" Status: Active for E-BOT [Humans] only")
    server_print("========================================")
    
    return PLUGIN_HANDLED
}

public fw_CmdStart(id, uc_handle, seed)
{
    // Only process bots
    if (!is_user_bot(id))
        return FMRES_IGNORED
    
    // Ignore dead players
    if (!is_user_alive(id))
        return FMRES_IGNORED
    
    // Get current weapon
    new iWeapon = get_user_weapon(id)
    
    // Check if weapon is full-auto
    if (!IsFullAutoWeapon(iWeapon))
        return FMRES_IGNORED
    
    // Get weapon entity
    new iWeaponEnt = get_pdata_cbase(id, 373) // m_pActiveItem offset
    
    if (!pev_valid(iWeaponEnt))
        return FMRES_IGNORED
    
    // Safety checks: clip empty or reloading
    new iClip = cs_get_weapon_ammo(iWeaponEnt)
    new iReloading = get_pdata_int(iWeaponEnt, m_fInReload, 4)
    
    if (iClip <= 0 || iReloading)
    {
        g_fStopSprayTime[id] = 0.0
        g_iOldButtons[id] = 0
        return FMRES_IGNORED
    }
    
    // Get button state
    new iButtons = get_uc(uc_handle, UC_Buttons)
    new Float:fGameTime = get_gametime()
    
    // Edge Detection: Check if this is a NEW button press (rising edge)
    // Trigger ONLY on transition from NOT pressed to pressed
    new bool:bIsAttackPressed = (iButtons & IN_ATTACK) ? true : false
    new bool:bWasAttackPressed = (g_iOldButtons[id] & IN_ATTACK) ? true : false
    
    if (bIsAttackPressed && !bWasAttackPressed)
    {
        // Rising edge detected - bot just pressed attack
        // Start spray timer
        new Float:fDuration = get_pcvar_float(g_pCvarSprayDuration)
        g_fStopSprayTime[id] = fGameTime + fDuration
    }
    // Sustain Logic: Force spray if timer is still active
    else if (fGameTime < g_fStopSprayTime[id])
    {
        // Timer still active - force attack button
        iButtons |= IN_ATTACK
        set_uc(uc_handle, UC_Buttons, iButtons)
    }
    
    // Update old buttons with current modified state
    // Store the modified buttons to prevent self-triggering
    g_iOldButtons[id] = iButtons
    
    return FMRES_IGNORED
}

// Check if weapon is full-auto
bool:IsFullAutoWeapon(iWeaponID)
{
    for (new i = 0; i < sizeof(g_iFullAutoWeapons); i++)
    {
        if (iWeaponID == g_iFullAutoWeapons[i])
            return true
    }
    
    return false
}

public client_putinserver(id)
{
    // Reset button state on connect
    g_iOldButtons[id] = 0
    g_fStopSprayTime[id] = 0.0
}

public client_disconnected(id)
{
    // Reset spray timer and button state on disconnect
    g_fStopSprayTime[id] = 0.0
    g_iOldButtons[id] = 0
}