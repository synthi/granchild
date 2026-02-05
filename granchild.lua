-- granchild v3.0.11
-- granular sequencer
--
-- llllllll.co/t/granchild
--
-- thx @artfwo, @cfdrake,
-- @justmat
--

engine.name="ZGlut"

local granchild=include("granchild/lib/granchild_core")

local position={1,1}
local press_positions={{0,0},{0,0}}
local norns_screen={}
local divisions={1,2,4,6,8,12,16}
local division_names={"2 wn","wn","hn","hn-t","qn","qn-t","eighth"}

-- CRITICAL FIX: Reordered list so SAMPLE loads first, PLAY happens last.
local param_list={"sample","overtones","overtoneslfo","subharmonics","subharmonicslfo","sizelfo","densitylfo","speedlfo","volumelfo","spreadlfo","jitterlfo","spread","jitter","size","pos","q","division","speed","send","q","cutoff","fade","pitch","density","pan","volume","seek","distribution","play"}
local param_list_delay={"delay_volume","delay_mod_freq","delay_mod_depth","delay_fdbk","delay_diff","delay_damp","delay_size","delay_time"}

local lfo_shapes = {"Sine", "Tri", "Saw", "Square", "S&H", "Slew"}

-- Debounce timers for sample loading
local sample_timers = {}
for i=1,4 do sample_timers[i] = {} end

-- Initial randomizer for LFO Frequencies to match original "Drift" feel
local function randomize_lfo_rates()
  local ranges = {
    jitter = {0.03, 0.06},
    size = {0.03, 0.08},
    subharmonics = {0.02, 0.08},
    overtones = {0.03, 0.05},
    pitch = {0.02, 0.05}, -- Slow wow/flutter
    default = {0.08, 0.12}
  }
  for i=1,4 do
    local lfo_targets = {"density", "size", "speed", "volume", "jitter", "spread", "subharmonics", "overtones", "pitch"}
    for _, target in ipairs(lfo_targets) do
      local r = ranges[target] or ranges.default
      local random_freq = r[1] + math.random() * (r[2] - r[1])
      for scene=1,2 do
        if params:lookup_param(i..target.."freq"..scene) then
           params:set(i..target.."freq"..scene, random_freq)
        end
      end
    end
  end
end

local function global_reset()
  clock.run(function()
      -- 1. Silence Audio
      for i=1,4 do engine.gain(i, 0) end
      
      -- 2. Sequential Unload (Fixes packet drop)
      for i=1,4 do 
          engine.read(i, "-") 
          clock.sleep(0.02) 
      end
      
      -- 3. Clear Data
      for i=1,4 do granchild_grid.voices[i].steps = {} end
      
      -- 4. Reset Params (Silent set)
      for _, p in ipairs(params.params) do
          if p.id and p.id ~= "global_reset" then
              params:set(p.id, p.default or 0, true) -- Silent
          end
      end
      
      -- 5. EXPLICIT ENGINE RESET (Fixes "False Reset" issue)
      -- Manually send defaults to Engine because silent set didn't.
      for i=1,4 do
          engine.gate(i, 0)
          engine.cutoff(i, 20000)
          engine.speed(i, 0)
          engine.density(i, 12) -- Default density
          engine.size(i, 0.1) -- Default size approx
          engine.jitter(i, 0)
          engine.spread(i, 0)
          engine.pitch(i, 1.0)
          engine.gain(i, 0.25) -- Default volume
          engine.seek(i, 0)
      end
      
      -- 6. Reset Internal State (Old Volume for delay logic)
      -- This fixes logic that depends on previous volume state
      -- Accessing local `old_volume` via closure if possible, or just assume restart.
      -- Since old_volume is local to setup_params, we can't touch it easily.
      -- But setting engine gain above handles the audio.
      
      -- 7. Re-randomize LFOs
      randomize_lfo_rates()
      
      -- 8. UI Reset
      granchild_grid.tape_voice = 0
      if _menu.rebuild_params then _menu.rebuild_params() end
      granchild_grid:grid_redraw()
      
      print("GLOBAL RESET COMPLETE")
  end)
end

local function bang(scene)
  for i=1,4 do
    for _,param_name in ipairs(param_list) do
      if params:lookup_param(i..param_name..scene) then
        local p=params:lookup_param(i..param_name..scene)
        p:bang()
      end
    end
    local p=params:lookup_param(i.."pattern"..scene)
    p:bang()
  end
  for _,param_name in ipairs(param_list_delay) do
    local p=params:lookup_param(param_name..scene)
    p:bang()
  end
end

local function setup_params()
  params:add_separator("samples")
  local num_voices=4
  local old_volume={0.25,0.25,0.25,0.25}
  for i=1,num_voices do
    params:add_group("sample "..i,92) 
    params:add_option(i.."scene","scene",{"a","b"},1)
    params:set_action(i.."scene",function(scene)
      for _,param_name in ipairs(param_list) do
        if params:lookup_param(i..param_name..(3-scene)) then
            params:hide(i..param_name..(3-scene))
        end
        if params:lookup_param(i..param_name..scene) then
            params:show(i..param_name..scene)
            local p=params:lookup_param(i..param_name..scene)
            p:bang()
        end
      end
      local lfo_targets = {"density", "size", "speed", "volume", "jitter", "spread", "subharmonics", "overtones", "pitch"}
      for _, target in ipairs(lfo_targets) do
         params:hide(i..target.."depth"..(3-scene))
         params:hide(i..target.."shape"..(3-scene))
         params:hide(i..target.."freq"..(3-scene))
         params:show(i..target.."depth"..scene)
         params:show(i..target.."shape"..scene)
         params:show(i..target.."freq"..scene)
      end

      local p=params:lookup_param(i.."pattern"..scene)
      p:bang()
      if params:get(i.."pattern"..scene)=="" or params:get(i.."pattern"..scene)=="[]" then
        granchild_grid:toggle_playing_voice(i,false)
      end
      if _menu.rebuild_params~=nil then
        _menu.rebuild_params()
      end
    end)
    for scene=1,2 do
      params:add_file(i.."sample"..scene,"sample")
      params:set_action(i.."sample"..scene,function(file)
        print("sample "..file)
        if file~="-" then
          if sample_timers[i][scene] then clock.cancel(sample_timers[i][scene]) end
          sample_timers[i][scene] = clock.run(function()
              clock.sleep(0.2)
              engine.read(i,file)
              params:set(i.."play"..scene,2)
              if params:get(i.."sample"..(3-scene))=="-" then
                params:set(i.."sample"..(3-scene),file,true)
                params:set(i.."play"..(3-scene),2,true)
              end
          end)
        end
      end)

      params:add_option(i.."play"..scene,"play",{"off","on"},1)
      params:set_action(i.."play"..scene,function(x) engine.gate(i,x-1) end)

      params:add_control(i.."seek"..scene,"seek",controlspec.new(0,1,"lin",0.001,0,"",0.001/1))
      params:set_action(i.."seek"..scene,function(value) engine.seek(i,util.clamp(value+params:get(i.."pos"..scene),0,1)) end)

      params:add_control(i.."volume"..scene,"volume",controlspec.new(0,4.0,"lin",0.05,0.25,"vol",0.05/4))
      params:set_action(i.."volume"..scene,function(value)
        engine.volume(i,value)
        if value==0 then
          engine.send(i,0)
        elseif value>0 and old_volume[i]==0 then
          engine.send(i,params:get(i.."send"..scene))
        end
        old_volume[i]=value
      end)
      params:add_option(i.."volumelfo"..scene,"volume lfo",{"off","on"},1)
      params:add_control(i.."volumedepth"..scene,"volume depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."volumeshape"..scene,"volume shape",lfo_shapes,1)
      params:add_control(i.."volumefreq"..scene,"volume freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_control(i.."pan"..scene,"pan",controlspec.new(-1,1,"lin",0.01,0,"",0.01/1))
      params:set_action(i.."pan"..scene,function(value) engine.pan(i,value) end)

      params:add_control(i.."density"..scene,"density",controlspec.new(1,40,"lin",1,12,"/beat",1/40))
      params:set_action(i.."density"..scene,function(value) engine.density(i,value/(4*clock.get_beat_sec())) end)
      params:add_option(i.."densitylfo"..scene,"density lfo",{"off","on"},1)
      params:add_control(i.."densitydepth"..scene,"density depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."densityshape"..scene,"density shape",lfo_shapes,1)
      params:add_control(i.."densityfreq"..scene,"density freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))
      
      params:add_control(i.."distribution"..scene, "chaos", controlspec.new(0, 1, "lin", 0.01, 0, "", 0.01))
      params:set_action(i.."distribution"..scene, function(value) engine.distribution(i, value) end)

      params:add_control(i.."pitch"..scene,"pitch",controlspec.new(-48,48,"lin",1,0,"note",1/96))
      params:set_action(i.."pitch"..scene,function(value) engine.pitch(i,math.pow(0.5,-value/12)) end)
      params:add_option(i.."pitchlfo"..scene,"pitch lfo",{"off","on"},1)
      params:add_control(i.."pitchdepth"..scene,"pitch depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."pitchshape"..scene,"pitch shape",lfo_shapes,1)
      params:add_control(i.."pitchfreq"..scene,"pitch freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_taper(i.."fade"..scene,"att / dec",1,9000,1000,3,"ms")
      params:set_action(i.."fade"..scene,function(value) engine.envscale(i,value/1000) end)

      params:add_control(i.."cutoff"..scene,"filter cutoff",controlspec.new(20,20000,"exp",0,20000,"hz"))
      params:set_action(i.."cutoff"..scene,function(value) engine.cutoff(i,value) end)

      params:add_control(i.."q"..scene,"filter rq",controlspec.new(0.1,1.00,"lin",0.01,1))
      params:set_action(i.."q"..scene,function(value) engine.q(i,value) end)

      params:add_control(i.."send"..scene,"delay send",controlspec.new(0.0,1.0,"lin",0.01,0.2))
      params:set_action(i.."send"..scene,function(value) engine.send(i,value) end)

      params:add_control(i.."speed"..scene,"speed",controlspec.new(-2.0,2.0,"lin",0.05,0,"",0.05/4))
      params:set_action(i.."speed"..scene,function(value) engine.speed(i,value) end)
      params:add_option(i.."speedlfo"..scene,"speed lfo",{"off","on"},1)
      params:add_control(i.."speeddepth"..scene,"speed depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."speedshape"..scene,"speed shape",lfo_shapes,1)
      params:add_control(i.."speedfreq"..scene,"speed freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_option(i.."division"..scene,"division",division_names,5)
      params:set_action(i.."division"..scene,function(value)
        if granchild_grid~=nil then
          granchild_grid:set_division(i,divisions[value])
        end
      end)

      params:add_control(i.."pos"..scene,"pos",controlspec.new(-1/40,1/40,"lin",0.001,0))
      params:set_action(i.."pos"..scene,function(value) engine.seek(i,util.clamp(value+params:get(i.."seek"..scene),0,1)) end)

      params:add_control(i.."size"..scene,"size",controlspec.new(1,15,"lin",1,5,"",1/15))
      params:set_action(i.."size"..scene,function(value)
        engine.size(i,util.clamp(value*clock.get_beat_sec()/10,0.001,util.linlin(1,40,1,0.1,params:get(i.."density"..scene))))
      end)
      params:add_option(i.."sizelfo"..scene,"size lfo",{"off","on"},1)
      params:add_control(i.."sizedepth"..scene,"size depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."sizeshape"..scene,"size shape",lfo_shapes,1)
      params:add_control(i.."sizefreq"..scene,"size freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_taper(i.."jitter"..scene,"jitter",0,500,0,5,"ms")
      params:set_action(i.."jitter"..scene,function(value) engine.jitter(i,value/1000) end)
      params:add_option(i.."jitterlfo"..scene,"jitter lfo",{"off","on"},2)
      params:add_control(i.."jitterdepth"..scene,"jitter depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."jittershape"..scene,"jitter shape",lfo_shapes,1)
      params:add_control(i.."jitterfreq"..scene,"jitter freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_taper(i.."spread"..scene,"spread",0,100,0,0,"%")
      params:set_action(i.."spread"..scene,function(value) engine.spread(i,value/100) end)
      params:add_option(i.."spreadlfo"..scene,"spread lfo",{"off","on"},2)
      params:add_control(i.."spreaddepth"..scene,"spread depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."spreadshape"..scene,"spread shape",lfo_shapes,1)
      params:add_control(i.."spreadfreq"..scene,"spread freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_control(i.."subharmonics"..scene,"subharmonic vol",controlspec.new(0.00,1.00,"lin",0.01,0))
      params:set_action(i.."subharmonics"..scene,function(value) engine.subharmonics(i,value) end)
      params:add_option(i.."subharmonicslfo"..scene,"subharmonic lfo",{"off","on"},1)
      params:add_control(i.."subharmonicsdepth"..scene,"subharmonic depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."subharmonicsshape"..scene,"subharmonic shape",lfo_shapes,1)
      params:add_control(i.."subharmonicsfreq"..scene,"subharmonic freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_control(i.."overtones"..scene,"overtone vol",controlspec.new(0.00,1.00,"lin",0.01,0))
      params:set_action(i.."overtones"..scene,function(value) engine.overtones(i,value) end)
      params:add_option(i.."overtoneslfo"..scene,"overtone lfo",{"off","on"},1)
      params:add_control(i.."overtonesdepth"..scene,"overtone depth",controlspec.new(0,1,"lin",0.01,0.5))
      params:add_option(i.."overtonesshape"..scene,"overtone shape",lfo_shapes,1)
      params:add_control(i.."overtonesfreq"..scene,"overtone freq",controlspec.new(0.01,1.0,"lin",0.01,0.1,"hz"))

      params:add_text(i.."pattern"..scene,"pattern","")
      params:hide(i.."pattern"..scene)
      params:set_action(i.."pattern"..scene,function(value)
        if granchild_grid~=nil then
          granchild_grid:set_steps(i,value)
        end
      end)
    end
  end

  params:add_group("delay",17)
  params:add_option("delayscene","scene",{"a","b"},1)
  params:set_action("delayscene",function(scene)
    for _,param_name in ipairs(param_list_delay) do
      params:hide(param_name..(3-scene))
      params:show(param_name..scene)
      if _menu.rebuild_params~=nil then
        _menu.rebuild_params()
      end
      local p=params:lookup_param(i..param_name..scene)
      p:bang()
    end
  end)
  for scene=1,2 do
    params:add_control("delay_time"..scene,"*".."delay time",controlspec.new(0.0,60.0,"lin",.01,2.00,""))
    params:set_action("delay_time"..scene,function(value) engine.delay_time(value) end)
    params:add_control("delay_size"..scene,"*".."delay size",controlspec.new(0.5,5.0,"lin",0.01,2.00,""))
    params:set_action("delay_size"..scene,function(value) engine.delay_size(value) end)
    params:add_control("delay_damp"..scene,"*".."delay damp",controlspec.new(0.0,1.0,"lin",0.01,0.10,""))
    params:set_action("delay_damp"..scene,function(value) engine.delay_damp(value) end)
    params:add_control("delay_diff"..scene,"*".."delay diff",controlspec.new(0.0,1.0,"lin",0.01,0.707,""))
    params:set_action("delay_diff"..scene,function(value) engine.delay_diff(value) end)
    params:add_control("delay_fdbk"..scene,"*".."delay fdbk",controlspec.new(0.00,1.0,"lin",0.01,0.20,""))
    params:set_action("delay_fdbk"..scene,function(value) engine.delay_fdbk(value) end)
    params:add_control("delay_mod_depth"..scene,"*".."delay mod depth",controlspec.new(0.0,1.0,"lin",0.01,0.00,""))
    params:set_action("delay_mod_depth"..scene,function(value) engine.delay_mod_depth(value) end)
    params:add_control("delay_mod_freq"..scene,"*".."delay mod freq",controlspec.new(0.0,10.0,"lin",0.01,0.10,"hz"))
    params:set_action("delay_mod_freq"..scene,function(value) engine.delay_mod_freq(value) end)
    params:add_control("delay_volume"..scene,"*".."delay output volume",controlspec.new(0.0,1.0,"lin",0,1.0,""))
    params:set_action("delay_volume"..scene,function(value) engine.delay_volume(value) end)
  end
  params:add_control("rec_fade","rec fade time",controlspec.new(0.0,1500,"lin",10,100,"ms",10/1500))
  params:add_trigger("global_reset", ">> RESET ALL <<")
  params:set_action("global_reset", function() global_reset() end)

  for i=1,4 do
    for _,param_name in ipairs(param_list) do
      params:hide(i..param_name.."2")
    end
    local lfo_targets = {"density", "size", "speed", "volume", "jitter", "spread", "subharmonics", "overtones", "pitch"}
    for _, target in ipairs(lfo_targets) do
         params:hide(i..target.."depth2")
         params:hide(i..target.."shape2")
         params:hide(i..target.."freq2")
    end
  end
  for _,param_name in ipairs(param_list_delay) do
    params:hide(param_name.."2")
  end

  bang(1)
end

function init()
  math.randomseed(os.time())
  setup_params()
  randomize_lfo_rates() -- Initial randomization

  params.action_loaded = function()
    clock.run(function()
        clock.sleep(1.25) -- Increased wait time for buffers
        for i=1,4 do
            local s = params:get(i.."scene")
            bang(s)
        end
        
        -- FORCE RE-TRIGGER OF GATE (Play) TO WAKE UP ENGINE
        for i=1,4 do
            local s = params:get(i.."scene")
            local play_state = params:get(i.."play"..s)
            if play_state == 2 then -- If ON
                engine.gate(i, 1)
            end
        end
        print("PSET Loaded: State Synced & Gates Open.")
    end)
  end

  granchild_grid=granchild:new({grid_on=true,toggleable=false})

  clock.run(function()
    while true do
      clock.sleep(1/10)
      if granchild_grid.grid_on then
        norns_screen=granchild_grid.visual
      elseif kolor_grid~=nil and kolor_grid.grid_on then
        norns_screen=kolor_grid.visual
      end
      redraw()
    end
  end)
end

function cleanup()
  if granchild_grid then granchild_grid:cleanup() end
end

function enc(k,d)
  if k==2 then
    position[1]=position[1]+d
    if position[1]>8 then position[1]=8 elseif position[1]<1 then position[1]=1 end
  elseif k==3 then
    position[2]=position[2]+d
    if position[2]>16 then position[2]=16 elseif position[2]<1 then position[2]=1 end
  end
end

function key(k,z)
  if k>1 then
    if z==1 then
      press_positions[k-1]={position[1],position[2]}
    end
    granchild_grid:key_press(press_positions[k-1][1],press_positions[k-1][2],z==1)
  elseif k==1 and z==1 then
    granchild_grid:toggle_grid64_side()
  end
end

function redraw()
  screen.clear()
  screen.level(0)
  screen.rect(1,1,128,64)
  screen.fill()

  if norns_screen~=nil and norns_screen[1]~=nil then
    local gd=norns_screen
    rows=#gd
    cols=#gd[1]
    for row=1,rows do
      for col=1,cols do
        if gd[row][col]~=0 then
          screen.level(gd[row][col])
          screen.rect(col*8-7,row*8-8+1,6,6)
          screen.fill()
        end
      end
    end
    screen.level(15)
    screen.rect(position[2]*8-7,position[1]*8-8+1,7,7)
    screen.stroke()
  end

  screen.update()
end

function rerun()
  norns.script.load(norns.state.script)
end
