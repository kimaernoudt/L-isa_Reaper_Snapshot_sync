-- L-ISA Live Snapshot Monitor via OSC
-- Runs in the background, monitors playhead, and triggers OSC when crossing a "LISA:N" marker.
-- Sends /ext/snap/<int>/f via UDP using Python 3.
-- Double-Click this text button to change the target IP.

-- ============================================================
--  CONFIGURATION & PERSISTENT STORAGE
-- ============================================================

local EXT_SECTION = "LISA_CUE_TRIGGER_CONFIG" 
local DEFAULT_HOST = "127.0.0.1"
local LISA_PORT = 8880                        

-- Fetch the saved IP from REAPER's configuration, or fall back to default
if not reaper.HasExtState(EXT_SECTION, "IP") then
    reaper.SetExtState(EXT_SECTION, "IP", DEFAULT_HOST, true)
end
local LISA_HOST = reaper.GetExtState(EXT_SECTION, "IP")

if not LISA_HOST or LISA_HOST == "" then 
    LISA_HOST = DEFAULT_HOST 
end

-- State tracking for the playback loop
local last_triggered_snapshot = -1

-- ============================================================
--  GET SNAPSHOT NUMBER FROM NEAREST "LISA:N" MARKER
-- ============================================================

local function get_snapshot_from_current_position()
    local play_state = reaper.GetPlayState()
    local current_pos = (play_state & 1 == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    
    local total = reaper.CountProjectMarkers(0)
    local latest_marker_time = -1
    local found_snapshot = nil
    
    for i = 0, total - 1 do
        local _, isrgn, pos, _, name, _ = reaper.EnumProjectMarkers(i)
        if not isrgn and pos <= current_pos then
            local n = name:match("^LISA:(%d+)")
            if n and pos > latest_marker_time then 
                latest_marker_time = pos
                found_snapshot = tonumber(n)
            end
        end
    end
    return found_snapshot
end

-- ============================================================
--  OSC PACKET BUILDER (Embedded Path Syntax)
-- ============================================================

local function pad4(s)
    s = s .. "\0"
    while #s % 4 ~= 0 do s = s .. "\0" end
    return s
end

local function build_osc_embedded_path(snapshot_num)
    local full_address = "/ext/snap/" .. math.floor(snapshot_num) .. "/f"
    local osc_address = pad4(full_address)
    local osc_typetag = pad4(",") 
    return osc_address .. osc_typetag
end

-- ============================================================
--  SEND VIA PYTHON
-- ============================================================

local function send_via_python(host, port, packet)
    local hex = ""
    for i = 1, #packet do
        hex = hex .. string.format("\\x%02x", packet:byte(i))
    end

    local tmp = os.tmpname() .. ".py"
    local f = io.open(tmp, "w")
    if not f then return false end
    
    f:write(string.format([[
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"%s", ("%s", %d))
s.close()
]], hex, host, port))
    f:close()

    local success, _, _ = os.execute("/usr/bin/python3 " .. tmp .. " 2>/dev/null")
    os.remove(tmp)
    return success
end

-- ============================================================
--  TOOLBAR & TOGGLE MANAGEMENT
-- ============================================================

local _, _, section_id, cmd_id = reaper.get_action_context()

local function SetToggleState(state)
    if section_id and cmd_id and cmd_id ~= 0 then
        reaper.SetToggleCommandState(section_id, cmd_id, state)
        reaper.RefreshToolbar2(section_id, cmd_id)
    end
end

-- ============================================================
--  SETTINGS DIALOG (Change IP)
-- ============================================================

local function show_ip_settings_dialog()
    local current_ip = reaper.GetExtState(EXT_SECTION, "IP")
    if not current_ip or current_ip == "" then current_ip = DEFAULT_HOST end
    
    local ok, ret_val = reaper.GetUserInputs("L-ISA Configuration", 1, "Target Controller IP:", current_ip)
    
    if ok and ret_val ~= "" then
        ret_val = ret_val:gsub("%s+", "") 
        reaper.SetExtState(EXT_SECTION, "IP", ret_val, true)
        LISA_HOST = ret_val
        reaper.ShowConsoleMsg("[L-ISA] Destination IP updated to: " .. ret_val .. "\n")
    end
end

-- ============================================================
--  MAIN LOOP
-- ============================================================

local function loop()
    local current_snapshot = get_snapshot_from_current_position()

    if current_snapshot and current_snapshot ~= last_triggered_snapshot then
        local packet = build_osc_embedded_path(current_snapshot)
        local ok = send_via_python(LISA_HOST, LISA_PORT, packet)
        
        if ok then
            reaper.ShowConsoleMsg(string.format("[L-ISA] Live Trigger: Snapshot %d -> %s\n", current_snapshot, LISA_HOST))
            last_triggered_snapshot = current_snapshot
        end
    end

    if not current_snapshot then
        last_triggered_snapshot = -1
    end

    reaper.defer(loop)
end

-- ============================================================
--  SHUTDOWN / CLEANUP
-- ============================================================

local function shutdown()
    SetToggleState(0)
    reaper.ShowConsoleMsg("[L-ISA] Live Monitor Stopped.\n")
end

-- ============================================================
--  INITIALIZATION (Double-Click Timing Check)
-- ============================================================

local current_time = os.clock()
local last_click_time = tonumber(reaper.GetExtState(EXT_SECTION, "LAST_CLICK")) or 0

-- If the time between clicks is less than 0.35 seconds, it's a double-click!
if (current_time - last_click_time) < 0.35 then
    -- Double Click: Reset tracking, make sure button stays lit if it was running, open menu
    reaper.SetExtState(EXT_SECTION, "LAST_CLICK", "0", false)
    show_ip_settings_dialog()
else
    -- Single Click: Save this click time for double-click tracking
    reaper.SetExtState(EXT_SECTION, "LAST_CLICK", tostring(current_time), false)
    
    -- Normal toggle engine state
    local current_state = reaper.GetToggleCommandStateEx(section_id, cmd_id)

    if current_state == 1 then
        shutdown()
    else
        SetToggleState(1)
        reaper.atexit(shutdown)
        reaper.ShowConsoleMsg("[L-ISA] Live Monitor Running (Target IP: " .. LISA_HOST .. ")\n")
        loop()
    end
end
