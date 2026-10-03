--[[--
A small playback bar at the bottom of the page while Voice Companion
speaks: status ("Loading voice…", "Reading", "Paused") plus Pause/Resume
and Stop buttons.

It is drawn as a ReaderView view module and takes taps through a reader
touch zone over its own rectangle, so the rest of the page keeps working
(page turns, selection, menus) while it is shown.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Screen = Device.screen

local ControlBar = {}
ControlBar.__index = ControlBar

local STATUS = {
    loading = _("Loading voice…"),
    playing = _("Reading"),
    paused = _("Paused"),
}

-- Reader tap zones the bar takes precedence over (inside its rectangle only).
local OVERRIDES = {
    "readerhighlight_tap", "tap_link", "readerfooter_tap",
    "readermenu_tap", "readermenu_ext_tap",
    "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
    "tap_forward", "tap_backward",
}

--- @param ui ReaderUI
-- @param actions table { toggle = function(), stop = function() }
function ControlBar:new(ui, actions)
    local o = setmetatable({ actions = actions, state = nil }, self)
    ui.view:registerViewModule("voicecompanion_bar", o)   -- sets o.ui, o.view
    return o
end

function ControlBar:isShown()
    return self.state ~= nil
end

--- Show the bar (or update it) with state "loading"|"playing"|"paused".
function ControlBar:show(state)
    if self.state == state then return end
    self.state = state
    local old = self.dimen
    self:_layout()
    self:_refresh(old)
end

function ControlBar:hide()
    if not self.state then return end
    self.state = nil
    self:_refresh(self.dimen)
end

function ControlBar:_layout()
    local paused = self.state == "paused"
    self.toggle_button = Button:new{
        text = paused and ("▶ " .. _("Resume")) or ("⏸ " .. _("Pause")),
        callback = function() end,   -- taps are handled in onTap
        bordersize = Size.border.button,
        padding = Size.padding.button,
    }
    self.stop_button = Button:new{
        text = "■ " .. _("Stop"),
        callback = function() end,
        bordersize = Size.border.button,
        padding = Size.padding.button,
    }
    local gap = HorizontalSpan:new{ width = Size.span.horizontal_default }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.small,
        HorizontalGroup:new{
            align = "center",
            TextWidget:new{
                text = STATUS[self.state] or "",
                face = Font:getFace("smallinfofont"),
            },
            gap,
            self.toggle_button,
            gap,
            self.stop_button,
        },
    }
    local size = self.frame:getSize()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local view = self.view
    local footer_h = 0
    if view and view.footer_visible and view.footer and view.footer.getHeight then
        footer_h = view.footer:getHeight()
    end
    self.dimen = Geom:new{
        x = math.floor((sw - size.w) / 2),
        y = sh - footer_h - size.h - Screen:scaleBySize(12),
        w = size.w,
        h = size.h,
    }
    self.ui:registerTouchZones({
        {
            id = "voicecompanion_bar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = self.dimen.x / sw, ratio_y = self.dimen.y / sh,
                ratio_w = self.dimen.w / sw, ratio_h = self.dimen.h / sh,
            },
            handler = function(ev) return self:onTap(ev) end,
            overrides = OVERRIDES,
        },
    })
end

--- Rebuild after a rotation or screen-size change.
function ControlBar:resetLayout()
    if self.state then self:_layout() end
end

function ControlBar:_refresh(old)
    local region = self.dimen
    if old and region then
        region = old:combine(region)
    else
        region = old or region
    end
    if self.view and self.view.dialog then
        UIManager:setDirty(self.view.dialog, "ui", region)
    end
end

function ControlBar:paintTo(bb, x, y)
    if not self.state or not self.frame then return end
    self.frame:paintTo(bb, x + self.dimen.x, y + self.dimen.y)
end

local function hit(button, pos)
    return button and button.dimen and pos and pos:intersectWith(button.dimen)
end

--- Tap on the bar.  Returns false when hidden so the tap reaches the page.
function ControlBar:onTap(ev)
    if not self.state then return false end
    if hit(self.toggle_button, ev.pos) then
        UIManager:nextTick(self.actions.toggle)
    elseif hit(self.stop_button, ev.pos) then
        UIManager:nextTick(self.actions.stop)
    end
    return true   -- taps on the bar's padding are swallowed, not page turns
end

return ControlBar
