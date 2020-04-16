local id, pin_sda, pin_scl = 0, 6, 5
local modes = {}
modes['on'] = { seconds = 0, elapsed = 0, diff = 0 }
modes['off'] = { seconds = 0, elapsed = 0, diff = 0 }
local ten_s_in_mV = 150
local main_loop = tmr.create()
local button_pin = 2
local buzzkill = require('buzzkill')
local buzzer_pin = 1
local buzzer = buzzkill.setup(buzzer_pin)
local display_sla = 0x3c
local running = false
local current_timer = nil
local run_timer = tmr.create()
local adc = nil
local display = nil
local update_display, update_on_display, update_off_display = nil, nil, nil
local inactivity_timer = tmr.create()
local in_low_power_mode = false


i2c.setup(id, pin_sda, pin_scl, i2c.SLOW)


-- PROGRAM




local function reset_inactivity_timer()
  inactivity_timer:stop()
  inactivity_timer:start()
end

local function low_power_mode()
  inactivity_timer:stop()
  display:setPowerSave(1)
  in_low_power_mode = true
  print("Low Power Mode")
end

local function normal_power_mode()
  display:setPowerSave(0)
  in_low_power_mode = false
  print("Normal Power Mode")
end

local function activity_happened()
  reset_inactivity_timer()

  if in_low_power_mode then
    normal_power_mode()
    return true

  else
    return false
  end
end

local function time_tick()
  local mode = modes[current_timer]

  mode['elapsed'] = mode['elapsed'] + 1

  local diff = mode['seconds'] - mode['elapsed']

  if diff < 1 then
    if current_timer == 'on' then
      current_timer = 'off'
      update_off_display()
    else
      current_timer = 'on'
      update_on_display()
    end

    buzzkill.playNote(buzzer_pin, { frequency = 1600, duration = 1000 }, function() mode['elapsed'] = 0 end)

  else
    if diff < 6 then
      buzzkill.playNote(buzzer_pin, { frequency = 400 + (5 - diff) * 200, duration = 100 })
    end
  end
end


local function reset()
  running = false
  run_timer:stop()
  modes['on']['elapsed'] = 0
  modes['off']['elapsed'] = 0
  current_timer = 'on'
  update_display()
end


local function start()
  running = true
  run_timer:register(1000, tmr.ALARM_AUTO, time_tick)
  run_timer:start()
end



-- DISPLAY


local function draw_time_string(str, x_offset, y_offset)
  activity_happened()

  local str_width = display:getStrWidth(str)

  display:setDrawColor(0)
  display:drawBox(x_offset + 8, 20, 55, 24)
  display:setDrawColor(1)
  display:drawStr(x_offset + (64 - str_width) / 2, 44 - y_offset, str)
  display:updateDisplayArea(1 * (x_offset / 8), 1, 7, 5)
end

local function set_font(timer, height)
  if timer == current_timer then
    display:setFont(u8g2.font_logisoso24_tn)
    return 0
  else
    display:setFont(u8g2.font_crox2c_tn)
    return 5
  end
end

update_on_display = function()
  local y_offset = set_font('on')
  draw_time_string(tostring(modes['on']['diff']), 0, y_offset)
end

update_off_display = function()
  local y_offset = set_font('off')
  draw_time_string(tostring(modes['off']['diff']), 64, y_offset)
end

update_display = function()
  update_on_display()
  update_off_display()
end

local function draw_interface()
  display:setDrawColor(1)
  display:drawLine(64, 0, 64, 63)

  display:setDrawColor(0)
  display:drawBox(64, 20, 1, 24)

  display:setDrawColor(1)
  display:setFont(u8g2.font_unifont_t_symbols)
  display:drawUTF8(57, 38, "⏱")

  display:updateDisplayArea(7, 0, 2, 8)
end

local function setup_display()
  display = u8g2.ssd1306_i2c_128x64_noname(id, display_sla)

  display:clearBuffer()

  display:setFlipMode(1)
  draw_interface()
end

-- BUZZER

local function play_start(callback)
  local d = 50
  buzzer({ { note='C', duration=d }, { note='E', duration=d }, { note='A', duration=d } }, callback)
end

local function play_reset()
  play_start()
end

local function play_end()
end

local function play_time_tick()
  buzzer({ { note='C', duration=50 } })
end


-- POTS

local function value_to_seconds(value)
  return (math.floor(value / ten_s_in_mV + 0.5) + 1) * 10
end

local function set_seconds_from_reading(which, reading)
  local seconds = value_to_seconds(reading)
  local mode = modes[which]

  if mode['seconds'] ~= seconds then
    mode['seconds'] = seconds
    --print(which .. ": " .. modes[which]['seconds'])
  end

  new_diff = mode['seconds'] - mode['elapsed']
  if new_diff < 0 then
    new_diff = 0
  end

  if new_diff ~= mode['diff'] then
    mode['diff'] = new_diff
    return true
  end

  return false
end

local function read_off_value(volt)
  if set_seconds_from_reading('off', volt) then
    update_off_display()
  end

  main_loop:start()
end

local function read_and_do(which, callback)
  ads1115.reset()
  adc:setting(ads1115.GAIN_4_096V, ads1115.DR_128SPS, which, ads1115.SINGLE_SHOT)
  adc:startread(callback)
end

local function read_on_value(volt)
  if set_seconds_from_reading('on', volt) then
    update_on_display()
  end

  read_and_do(ads1115.SINGLE_1, read_off_value)
end

local function monitor_config_values()
  read_and_do(ads1115.SINGLE_0, read_on_value)
end

local function loop()
  monitor_config_values()
end


local function setup_pots()
  ads1115.reset()
  adc = ads1115.ads1115(id, ads1115.ADDR_GND)
end


-- BUTTON

local button_is_busy = false

local function button_click(val, when, count)
  if button_is_busy then
    return
  end

  if activity_happened() then
    buzzer({ { note = 'a', duration = 50 } })
    return
  end

  button_is_busy = true
  play_start(function() button_is_busy = false end)

  if running then
    reset()
  else
    start()
  end
end

local function setup_button()
  gpio.mode(button_pin, gpio.INT)
  gpio.trig(button_pin, "down", button_click)
end





-- RUN

tmr.create():alarm(2000, tmr.ALARM_SINGLE, function()
  print("start")

  setup_pots()

  setup_button()

  setup_display()

  reset()

  inactivity_timer:alarm(15 * 60 * 1000, tmr.ALARM_SEMI, low_power_mode)

  main_loop:alarm(50, tmr.ALARM_SEMI, loop)
end)



