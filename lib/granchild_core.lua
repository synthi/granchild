-- granchild_core.lua v3.0.11
-- Core logic class
-- Changelog:
-- v3.0.11: CRITICAL FIX: Whitelist logic for key_press to prevent auto-repeat on Toggle buttons.
-- v3.0.10: Previous fix attempts.
-- v3.0.7-9: LFOs, Grid Speed, Utilities restored.

local json=include("granchild/lib/json")
local lattice=require("lattice")

local Granchild={}

local pitch_mods={-12,-7,-5,-3,0,3,5,7,12}
local num_steps=18

function Granchild:new(args)
  local m=setmetatable({},{__index=Granchild})
  local args=args==nil and {} or args
  m.grid_on=args.grid_on==nil and true or args.grid_on
  m.toggleable=args.toggleable==nil and false or args.toggleable

  m.scene="a"

  -- initiate the grid
  m.g=grid.connect()
  m.grid64=m.g.cols==8
  m.grid64default=true
  m.grid_width=16
  m.g.key=function(x,y,z)
    if m.grid_on then
      m:grid_key(x,y,z)
    end
  end
  print("grid columns: "..m.g.cols)

  -- allow toggling
  m.kill_timer=0

  -- setup visual
  m.visual={}
  for i=1,8 do
    m.visual[i]={}
    for j=1,m.grid_width do
      m.visual[i][j]=0
    end
  end

  -- debouncing and blinking
  m.blink_count=0
  m.blinky={}
  for i=1,m.grid_width do
    m.blinky[i]=1 -- 1 = fast, 16 = slow
  end

  -- keep track of pressed buttons
  m.pressed_buttons={}
  
  -- DEBOUNCE: Store last press time per button
  m.last_press_time={}
  for r=1,8 do m.last_press_time[r]={} end

  -- define num voices
  m.num_voices=4

  -- recording to tape
  m.tape_voice=0
  m.tape_start=0


  -- setup step sequencer
  m.voices={}
  for i=1,m.num_voices do
    m.voices[i]={
      division=8,-- 8 = quartner notes
      is_playing=false,
      is_recording=false,
      steps={},
      step=0,
      step_val=0,
      pitch_mod_i=5,
    }
  end

  -- setup lfos with MUSICAL vs ABSOLUTE ranges
  local mod_parameters={
    {name="jitter",       musical={15,200},   absolute={0,500},   lfo={32,64}},
    {name="spread",       musical={0,100},    absolute={0,100},   lfo={16,24}},
    {name="volume",       musical={0,0.5},    absolute={0,4.0},   lfo={16,24}},
    {name="speed",        musical={-0.05,0.05}, absolute={-2.0,2.0}, lfo={16,24}},
    {name="density",      musical={3,16},     absolute={1,40},    lfo={16,24}},
    {name="size",         musical={2,12},     absolute={1,15},    lfo={24,58}},
    {name="subharmonics", musical={0,1},      absolute={0,1},     lfo={24,70}},
    {name="overtones",    musical={0,0.2},    absolute={0,1},     lfo={36,60}},
    {name="pitch",        musical={-0.05,0.05}, absolute={-0.5,0.5}, lfo={24,60}},
  }
  m.mod_vals={}
  m.mod_state={} 

  for i=1,m.num_voices do
    m.mod_vals[i]={}
    m.mod_state[i]={}
    for j,mod in ipairs(mod_parameters) do
      m.mod_vals[i][j]={
          name=mod.name,
          musical=mod.musical,
          absolute=mod.absolute,
          offset=math.random()*30
      }
      m.mod_state[i][j]={
        last_phase=0,
        sample=0,
        target=0,
        slew_val=0
      }
    end
  end
  
  -- Store current modulated values for UI retrieval
  m.current_mod_values={}
  for i=1,m.num_voices do
    m.current_mod_values[i]={}
    for j,mod in ipairs(mod_parameters) do
      m.current_mod_values[i][mod.name] = 0
    end
  end

  -- setup lattice
  m.lattice=lattice:new({
    ppqn=48
  })
  m.timers={}
  for division=1,16 do
    m.timers[division]={}
    m.timers[division].lattice=m.lattice:new_pattern{
      action=function(t)
        m:emit_note(division)
      end,
    division=1/(division/2)}
  end
  m.lattice:start()


  -- grid refreshing
  m.grid_refresh=metro.init()
  m.grid_refresh.time=0.1
  m.grid_refresh.event=function()
    m:update_lfos() 
    if m.grid_on then
      m:grid_redraw()
    end
  end
  m.grid_refresh:start()

  -- metro for checking if keys are held to toggle re-presses
  m.key_held=metro.init()
  m.key_held.time=0.05 -- SPEED UP: 20Hz
  m.key_held.event=function()
    local cols={1,5,9,13}
    local cur_time=m:current_time()
    for _,col in ipairs(cols) do
      for row=1,8 do
        if m.pressed_buttons[row..","..col]~=nil then
          local elapsed_time=cur_time-m.pressed_buttons[row..","..col]
          if elapsed_time > 0.05 then
             m:key_press(row,col,true, elapsed_time)
          end
        end
      end
    end
  end
  m.key_held:start()

  -- polling for getting positions
  for i=1,m.num_voices do
    local phase_poll=poll.set('phase_'..i,function(pos) m.voices[i].position=pos end)
    phase_poll.time=0.1
    phase_poll:start()
  end

  -- Softcut Event Render
  softcut.event_render(function(ch, start, i, s)
      if m.tape_voice > 0 then
          m:finish_tape_load(m.tape_voice)
      end
  end)

  return m
end

function Granchild:cleanup()
  if self.lattice then self.lattice:stop() end
  if self.grid_refresh then self.grid_refresh:stop() end
  if self.key_held then self.key_held:stop() end
  for i=1,self.num_voices do
      poll.clear_all()
  end
end

-- UTILITY FUNCTIONS
function Granchild:pos_to_row_col(pos)
  local row=math.floor((pos-1)/3)+1
  local col=pos-(row-1)*3+1
  return row,col
end

function Granchild:current_time()
  return clock.get_beat_sec()*clock.get_beats()
end

function Granchild:grid_redraw()
  self.g:all(0)
  local gd=self:get_visual()
  local s=1
  local e=self.grid_width
  local adj=0
  if self.grid64 then
    e=8
    if not self.grid64default then
      s=9
      e=16
      adj=-8
    end
  end
  for row=1,8 do
    for col=s,e do
      if gd[row][col]~=0 then
        self.g:led(col+adj,row,gd[row][col])
      end
    end
  end
  self.g:refresh()
end
-- END UTILITY FUNCTIONS

function Granchild:emit_note(division)
  local update=false
  for i=1,self.num_voices do
    if self.voices[i].is_playing and self.voices[i].division==division then
      self.voices[i].step=self.voices[i].step+1
      if self.voices[i].step>#self.voices[i].steps then
        self.voices[i].step=1
      end
      local step_val=self.voices[i].steps[self.voices[i].step]
      if step_val~=self.voices[i].step_val and step_val~=nil then
        params:set(i.."seek"..params:get(i.."scene"),util.linlin(1,num_steps,0,1,step_val)+(math.random()-0.5)/100)
      end
      self.voices[i].step_val=step_val
      update=true
    end
  end
  if update then
    self:grid_redraw()
  end
end

function Granchild:toggle_grid64_side()
  self.grid64default=not self.grid64default
end

function Granchild:toggle_grid(on)
  if on==nil then
    self.grid_on=not self.grid_on
  else
    self.grid_on=on
  end
  if self.grid_on then
    self.g=grid.connect()
    self.g.key=function(x,y,z)
      print("granchild grid: ",x,y,z)
      if self.grid_on then
        self:grid_key(x,y,z)
      end
    end
  else
    if self.toggle_callback~=nil then
      self.toggle_callback()
    end
  end
end

function Granchild:set_toggle_callback(fn)
  self.toggle_callback=fn
end

function Granchild:grid_key(x,y,z)
  local now = util.time()
  if self.last_press_time[y] and self.last_press_time[y][x] and (now - self.last_press_time[y][x] < 0.03) then
      return -- Ignore bounce
  end
  if self.last_press_time[y] then self.last_press_time[y][x] = now end

  self:key_press(y,x,z==1)
  self:grid_redraw()
end

function Granchild:key_press(row,col,on,elapsed_hold)
  if self.grid64 and not self.grid64default then
    col=col+8
  end
  
  -- WHITELIST LOGIC FOR AUTO-REPEAT
  -- Only allow auto-repeat (elapsed_hold) for specific parameter buttons.
  if elapsed_hold then
      -- Whitelist: Column 1 (Params) OR Column 2 Rows 7-8 (Pitch)
      local is_col1 = (col % 4 == 1)
      local is_pitch = (col % 4 == 2) and (row == 7 or row == 8)
      
      if not (is_col1 or is_pitch) then
          return -- Block repeat for everything else (Rec, Play, Tape, Scene, Timeline)
      end
  end
  
  if on then
    if not elapsed_hold then
        self.pressed_buttons[row..","..col]=self:current_time()
    end
  else
    self.pressed_buttons[row..","..col]=nil
  end

  if (col%4==2 or col%4==3 or col%4==0) and row<7 and on then
    self:change_position(row,col)
  elseif col%4==2 and (row==7 or row==8) and on then
    self:change_pitch_mod(row,col)
  elseif (col%4==0) and row==7 and on then
    self:change_scene(col)
  elseif col%4==1 and (row==1 or row==2) and on then
    self:change_density_mod(row,col,elapsed_hold)
  elseif col%4==1 and (row==3 or row==4) and on then
    self:change_size(row,col,elapsed_hold)
  elseif col%4==1 and (row==5 or row==6) and on then
    self:change_speed(row,col,elapsed_hold)
  elseif col%4==1 and (row==7 or row==8) and on then
    self:change_volume(row,col,elapsed_hold)
  elseif col%4==3 and row==8 and on then
    self:toggle_recording(col)
  elseif col%4==0 and row==8 and on then
    self:toggle_playing(col)
  elseif col%4==3 and row==7 and on then
    self:toggle_tape_rec(col)
  end
end

function Granchild:set_steps(voice,steps_string)
  print("set_steps for voice "..voice..": "..steps_string)
  if steps_string~="" then
    local steps=json.decode(steps_string)
    if steps~=nil then
      self.voices[voice].steps=steps
    else
      self.voices[voice].steps={}
    end
  end
end

function Granchild:toggle_recording(col)
  local voice=math.floor((col-1)/4)+1
  self.voices[voice].is_recording=not self.voices[voice].is_recording
  if self.voices[voice].is_recording then
    self.voices[voice].steps={}
    self.voices[voice].step=0
    self.voices[voice].step_val=0
    self.voices[voice].is_playing=false
  else
    params:set(voice.."pattern"..params:get(voice.."scene"),json.encode(self.voices[voice].steps),true)
  end
end

function Granchild:toggle_playing_voice(voice,on)
  if on==nil then
    self.voices[voice].is_playing=not self.voices[voice].is_playing
  else
    self.voices[voice].is_playing=on
  end
  if self.voices[voice].is_playing then
    params:set(voice.."pattern"..params:get(voice.."scene"),json.encode(self.voices[voice].steps),true)
    self.voices[voice].is_recording=false
    self.voices[voice].step_val=0
  end
end

function Granchild:toggle_playing(col)
  local voice=math.floor((col-1)/4)+1
  self:toggle_playing_voice(voice)
end

function Granchild:toggle_tape_rec(col)
  local voice=math.floor((col-1)/4)+1
  if self.tape_voice==voice then
    self:rec_stop()
  else
    self:rec_start(voice)
  end
end

function Granchild:set_division(voice,division)
  self.voices[voice].division=division
end

function Granchild:get_dynamic_delta(elapsed)
    if not elapsed then return 1 end 
    if elapsed > 1.0 then return 2 end 
    if elapsed > 0.3 then return 1 end 
    return 0.2 
end

function Granchild:change_density_mod(row,col,elapsed)
  local voice=math.floor((col-1)/4)+1
  local mult = self:get_dynamic_delta(elapsed)
  local diff=-1*((row-1)*2-1) * mult
  params:delta(voice.."density"..params:get(voice.."scene"),diff)
  print("change_density_mod "..voice.." "..diff.." "..params:get(voice.."density"..params:get(voice.."scene")))
end

function Granchild:change_size(row,col,elapsed)
  local voice=math.floor((col-1)/4)+1
  local mult = self:get_dynamic_delta(elapsed)
  local diff=-1*((row-3)*2-1) * mult
  params:delta(voice.."size"..params:get(voice.."scene"),diff)
  print("change_size "..voice.." "..diff.." "..params:get(voice.."size"..params:get(voice.."scene")))
end

function Granchild:change_speed(row,col,elapsed)
  local voice=math.floor((col-1)/4)+1
  local mult = self:get_dynamic_delta(elapsed)
  local diff=-1*((row-5)*2-1) * mult
  params:delta(voice.."speed"..params:get(voice.."scene"),diff)
  print("change_speed "..voice.." "..diff.." "..params:get(voice.."speed"..params:get(voice.."scene")))
end

function Granchild:change_volume(row,col,elapsed)
  local voice=math.floor((col-1)/4)+1
  local mult = self:get_dynamic_delta(elapsed)
  local diff=-1*((row-7)*2-1) * mult
  params:delta(voice.."volume"..params:get(voice.."scene"),diff)
  print("change_volume "..voice.." "..diff.." "..params:get(voice.."volume"..params:get(voice.."scene")))
end

function Granchild:change_pitch_mod(row,col)
  local voice=math.floor((col-1)/4)+1
  local diff=-1*((row-7)*2-1)
  self.voices[voice].pitch_mod_i=self.voices[voice].pitch_mod_i+diff
  self.voices[voice].pitch_mod_i=util.clamp(self.voices[voice].pitch_mod_i,1,#pitch_mods)
  print(self.voices[voice].pitch_mod_i)
  params:set(voice.."pitch"..params:get(voice.."scene"),pitch_mods[self.voices[voice].pitch_mod_i])
  print("change_pitch_mod "..voice.." "..diff.." "..params:get(voice.."pitch"..params:get(voice.."scene")))
end

function Granchild:change_scene(col)
  local voice=math.floor((col-1)/4)+1
  params:set(voice.."scene",3-params:get(voice.."scene"))
end

function Granchild:change_position(row,col)
  local voice=math.floor((col-2)/4)+1
  col=col-4*(voice-1)-1 -- col now between 1 and 3
  local val=(row-1)*3+col
  if self.voices[voice].is_recording then
    table.insert(self.voices[voice].steps,val)
  end
  print("change_position "..voice..": "..val)
  params:set(voice.."seek"..params:get(voice.."scene"),util.linlin(1,num_steps,0,1,val)+(math.random()-0.5)/100)
end

function Granchild:get_modulated_value(voice, param_name)
    return self.current_mod_values[voice][param_name]
end

function Granchild:get_visual()
  self.blink_count=self.blink_count+1
  if self.blink_count>1000 then
    self.blink_count=0
  end
  for i,_ in ipairs(self.blinky) do
    if i==1 then
      self.blinky[i]=1-self.blinky[i]
    else
      if self.blink_count%i==0 then
        self.blinky[i]=0
      else
        self.blinky[i]=1
      end
    end
  end

  for row=1,8 do
    for col=1,self.grid_width do
      self.visual[row][col]=0
    end
  end

  for i=1,self.num_voices do
    local row=8
    local col=4*(i-1)+4
    self.visual[row][col]=4
    if self.voices[i].is_playing then
      self.visual[row][col]=14
    end
  end

  for i=1,self.num_voices do
    local row=8
    local col=4*(i-1)+3
    self.visual[row][col]=4
    if self.voices[i].is_recording then
      self.visual[row][col]=14
    end
  end

  for i=1,self.num_voices do
    local val=util.linlin(1,40,0,15, self:get_modulated_value(i, "density"))
    local col=4*(i-1)+1
    self.visual[1][col]=util.round(val)
    self.visual[2][col]=15-util.round(val)
  end

  for i=1,self.num_voices do
    local val=util.linlin(1,15,0,15, self:get_modulated_value(i, "size"))
    local col=4*(i-1)+1
    self.visual[3][col]=util.round(val)
    self.visual[4][col]=15-util.round(val)
  end

  for i=1,self.num_voices do
    local val=util.linlin(-2,2,0,15, self:get_modulated_value(i, "speed"))
    local col=4*(i-1)+1
    self.visual[5][col]=util.round(val)
    self.visual[6][col]=15-util.round(val)
  end

  for i=1,self.num_voices do
    local val=util.linlin(0,4,0,15, self:get_modulated_value(i, "volume"))
    local col=4*(i-1)+1
    self.visual[7][col]=util.round(val)
    self.visual[8][col]=15-util.round(val)
  end

  for i=1,self.num_voices do
    local val=util.linlin(-12,12,0,15,util.clamp(params:get(i.."pitch"..params:get(i.."scene")),-12,12))
    local col=4*(i-1)+2
    self.visual[7][col]=util.round(val)
    self.visual[8][col]=15-util.round(val)
  end

  for i=1,self.num_voices do
    local val=params:get(i.."scene")
    if val==1 then
      self.visual[7][4*(i-1)+4]=7
    else
      self.visual[7][4*(i-1)+4]=15
    end
  end

  for i=1,self.num_voices do
    if self.voices[i].is_recording or self.voices[i].is_playing then
      local step=self.voices[i].step
      if self.voices[i].is_recording then
        step=#self.voices[i].steps
      end
      if step>0 then
        for j=1,step do
          local row,col=self:pos_to_row_col((j-1)%num_steps+1)
          col=col+4*(i-1)
          self.visual[row][col]=self.visual[row][col]+3
          if self.visual[row][col]>15 then
            self.visual[row][col]=1
          end
        end
      end
    end
  end

  for i=1,self.num_voices do
    if self.voices[i].position~=nil then
      local pos=util.linlin(0,1,1,num_steps,self.voices[i].position)
      local pos1=math.floor(pos)
      local diff=pos-pos1
      local pos2=pos1+1
      if pos2>num_steps then
        pos2=1
      end
      local row1,col1=self:pos_to_row_col(pos1)
      local row2,col2=self:pos_to_row_col(pos2)
      self.visual[row2][col2+(i-1)*4]=util.round(util.linlin(0,1,0,15,diff))
      self.visual[row1][col1+(i-1)*4]=15-self.visual[row2][col2+(i-1)*4]
    end
  end

  for i=1,self.num_voices do
    local row=7
    local col=4*(i-1)+3
    if self.tape_voice==i then
      self.visual[row][col]=15
    else
      self.visual[row][col]=4
    end
  end
  return self.visual
end

function Granchild:update_lfos()
  for i=1,self.num_voices do
    local scene = params:get(i.."scene")
    if params:get(i.."play"..scene)==2 then
      
      -- Density first (dependency)
      local density_val = params:get(i.."density"..scene)
      local density_lfo_active = params:get(i.."densitylfo"..scene) == 2
      if density_lfo_active then
          local m = self.mod_vals[i][5] -- density index
          local depth = params:get(i.."densitydepth"..scene)
          local shape = params:get(i.."densityshape"..scene)
          local freq = params:get(i.."densityfreq"..scene)
          local bps = clock.get_beat_sec()
          local period_in_beats = (1.0 / freq) / bps
          local lfo_val = self:calculate_lfo(period_in_beats, m.offset, shape, i, 5)
          
          local musical_span = m.musical[2] - m.musical[1]
          local absolute_span = m.absolute[2] - m.absolute[1]
          local current_span = 0
          if depth <= 0.5 then
              current_span = (depth / 0.5) * musical_span
          else
              current_span = util.linlin(0.5, 1.0, musical_span, absolute_span, depth)
          end
          
          local offset = (current_span / 2) * lfo_val
          density_val = util.clamp(density_val + offset, m.absolute[1], m.absolute[2])
          
          engine.density(i, density_val/(4*clock.get_beat_sec()))
          self.current_mod_values[i]["density"] = density_val
      else
          self.current_mod_values[i]["density"] = density_val
          engine.density(i, density_val/(4*clock.get_beat_sec()))
      end

      for j,m in ipairs(self.mod_vals[i]) do
        if m.name ~= "density" then
            local lfo_active = params:get(i..m.name.."lfo"..scene) == 2
            local base_val = params:get(i..m.name..scene)
            local final_val = base_val
            
            if lfo_active then
              local depth = params:get(i..m.name.."depth"..scene)
              local shape = params:get(i..m.name.."shape"..scene)
              local freq = params:get(i..m.name.."freq"..scene)
              local bps = clock.get_beat_sec()
              local period_in_beats = (1.0 / freq) / bps
              local lfo_val = self:calculate_lfo(period_in_beats, m.offset, shape, i, j)
              
              local musical_span = m.musical[2] - m.musical[1]
              local absolute_span = m.absolute[2] - m.absolute[1]
              local current_span = 0
              if depth <= 0.5 then
                  current_span = (depth / 0.5) * musical_span
              else
                  current_span = util.linlin(0.5, 1.0, musical_span, absolute_span, depth)
              end
              
              local offset = (current_span / 2) * lfo_val
              final_val = util.clamp(base_val + offset, m.absolute[1], m.absolute[2])
              
              -- APPLY TO ENGINE
              if m.name == "volume" then
                 engine.gain(i, final_val)
              elseif m.name == "pitch" then
                 -- Pitch special case: base + offset (semitones) -> convert to rate
                 engine.pitch(i, math.pow(0.5, -final_val/12))
              elseif engine[m.name] then
                   if m.name == "size" then
                       engine.size(i, util.clamp(final_val*clock.get_beat_sec()/10, 0.001, util.linlin(1,40,1,0.1, density_val)))
                   elseif m.name == "jitter" then
                       engine.jitter(i, final_val/1000)
                   elseif m.name == "spread" then
                       engine.spread(i, final_val/100)
                   else
                       engine[m.name](i, final_val)
                   end
              end
            else
                -- LFO OFF: Restore base value to fix stuck values
                final_val = base_val
                if m.name == "volume" then
                   engine.gain(i, final_val)
                elseif m.name == "pitch" then
                   engine.pitch(i, math.pow(0.5, -final_val/12))
                elseif engine[m.name] then
                     if m.name == "size" then
                         engine.size(i, util.clamp(final_val*clock.get_beat_sec()/10, 0.001, util.linlin(1,40,1,0.1, density_val)))
                     elseif m.name == "jitter" then
                         engine.jitter(i, final_val/1000)
                     elseif m.name == "spread" then
                         engine.spread(i, final_val/100)
                     else
                         engine[m.name](i, final_val)
                     end
                end
            end
            self.current_mod_values[i][m.name] = final_val
        end
      end
    end
  end
end

function Granchild:calculate_lfo(period_in_beats, offset, shape, voice_idx, mod_idx)
  if period_in_beats==0 then return 0 end
  
  local phase = (clock.get_beats() / period_in_beats + offset) % 1
  local val = 0
  
  if shape == 1 then -- Sine
    val = math.sin(2 * math.pi * phase)
  elseif shape == 2 then -- Triangle
    val = 2 * math.abs(2 * phase - 1) - 1
  elseif shape == 3 then -- Saw
    val = 2 * phase - 1
  elseif shape == 4 then -- Square
    val = phase < 0.5 and 1 or -1
  elseif shape == 5 or shape == 6 then -- Random / Slew
    local state = self.mod_state[voice_idx][mod_idx]
    if phase < state.last_phase then
        state.sample = state.target
        state.target = math.random() * 2 - 1
    end
    state.last_phase = phase
    
    if shape == 5 then -- S&H
        val = state.target
    else -- Slew Random
        val = state.sample + (state.target - state.sample) * phase
    end
  end
  
  return val
end

function Granchild:rec_start(voice)
  if self.tape_voice>0 then
    self:rec_stop()
  end
  self.tape_voice=voice
  audio.level_eng_cut(0)
  audio.level_tape_cut(0)
  softcut.buffer_clear()
  for i=1,2 do
    softcut.enable(i,1)
    if i%2==1 then
      softcut.pan(i,1)
      softcut.buffer(i,1)
      softcut.level_input_cut(1,i,1)
      softcut.level_input_cut(2,i,0)
    else
      softcut.pan(i,-1)
      softcut.buffer(i,2)
      softcut.level_input_cut(1,i,0)
      softcut.level_input_cut(2,i,1)
    end
    softcut.rec_level(i,0.0)
    softcut.pre_level(i,1.0)
    softcut.level_slew_time(i,0.05)
    softcut.rate_slew_time(i,0)
    softcut.recpre_slew_time(i,params:get("rec_fade")/1000/10)
    softcut.level(i,0)
    softcut.rate(i,1)
    softcut.position(i,2)
    softcut.loop_start(i,2)
    softcut.loop_end(i,121)
    softcut.post_filter_dry(i,0.0)
    softcut.post_filter_lp(i,1.0)
    softcut.post_filter_rq(i,1.0)
    softcut.post_filter_fc(i,18000)

    softcut.pre_filter_dry(i,1.0)
    softcut.pre_filter_lp(i,1.0)
    softcut.pre_filter_rq(i,1.0)
    softcut.pre_filter_fc(i,18000)
  end
  clock.run(function()
    for i=1,2 do
      softcut.play(i,1)
      softcut.rec(i,1)
    end
    print("rec_start()")
    self.tape_start=self:current_time()
    for j=1,10 do
      for i=1,2 do
        softcut.rec_level(i,j/10)
      end
      clock.sleep(params:get("rec_fade")/1000/10)
    end
  end)
end

function Granchild:rec_stop()
  local total_length=self:current_time()-self.tape_start+params:get("rec_fade")/1000+params:get("rec_fade")/1000/10*1
  clock.run(function()
    for j=1,10 do
      for i=1,2 do
        softcut.rec_level(i,1-j/10)
      end
      clock.sleep(params:get("rec_fade")/1000/10)
    end
    clock.sleep(params:get("rec_fade")/1000/10*1)
    
    local tape_name=self:tape_get_name()
    if tape_name~=nil then
      self.pending_tape_name = tape_name
      softcut.buffer_write_stereo(tape_name,2,total_length)
    else
      self.tape_voice=0
    end
  end)
end

function Granchild:finish_tape_load(voice)
    print("saved to '"..self.pending_tape_name.."'")
    clock.sleep(1)
    for i=1,2 do
      softcut.rec(i,0)
      softcut.play(i,0)
    end
    print("loading!")
    params:set(voice.."sample"..params:get(voice.."scene"),self.pending_tape_name)
    self.tape_voice=0
    self.pending_tape_name = nil
end

function Granchild:tape_get_name()
  if not util.file_exists(_path.audio.."granchild/") then
    os.execute("mkdir -p ".._path.audio.."granchild/")
  end
  for index=1,9999 do
    index=string.format("%04d",index)
    local filename=_path.audio.."granchild/"..index..".wav"
    if not util.file_exists(filename) then
      do return _path.audio.."granchild/"..index..".wav" end
    end
  end
  return nil
end

return Granchild
