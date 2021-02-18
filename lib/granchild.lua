local Granchild={}


function Granchild:new(args)
  local m=setmetatable({},{__index=Granchild})
  local args=args==nil and {} or args
  m.grid_on = args.grid_on == nil and true or args.grid_on
  m.toggleable = args.toggleable == nil and false or args.toggleable

  -- initiate the grid
  m.g=grid.connect()
  m.grid_width = 16 
  if m.g.cols == 8 then 
  	m.grid_width = 8
  end
  m.g.key=function(x,y,z)
    if m.g.cols > 0 and m.grid_on then 
      m:grid_key(x,y,z)
    end
  end
  print("grid columns: "..m.g.cols)

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

  -- grid refreshing
  m.grid_refresh=metro.init()
  m.grid_refresh.time=0.05
  m.grid_refresh.event=function()
    if m.g.cols > 0 and m.grid_on then 
      m:grid_redraw()
    end
  end
  m.grid_refresh:start()

  -- setup step sequencer
  m.recording_voice = 0 -- set to current recording track
  m.recording_step = 1 

  return m
end

function Granchild:record_sequence(voice)
	self.recording_voice = voice 
	self.recording_step = 1 
end

function Granchild:toggle_grid(on)
  if on == nil then
    self.grid_on = not self.grid_on 
  else
    self.grid_on = on 
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
    if self.toggle_callback ~= nil then 
      self.toggle_callback()
    end
  end
end

function Granchild:set_toggle_callback(fn)
  self.toggle_callback = fn
end

function Granchild:grid_key(x,y,z)
  self:key_press(y,x,z==1)
  self:grid_redraw()
end

function Granchild:key_press(row,col,on)
  if on then
    self.pressed_buttons[row..","..col]=true
    if row == 8 and col == 2 and self.toggleable then 
      print("holding kill timer")
      self.kill_timer = self:current_time()
    end
  else
    self.pressed_buttons[row..","..col]=nil
    if row == 8 and col == 2 and self.toggleable then 
      self.kill_timer = self:current_time() - self.kill_timer
      print(self.kill_timer)
      if self.kill_timer > 0.5 then 
        self:toggle_grid(false)
      end
      self.kill_timer = 0
    end
  end

  if col == 1 and on then 
  	-- change volume
  elseif row < 7 then 
  	-- change position
  end
end



function Granchild:get_visual()
  --- update the blinky thing
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
  if self.show_graphic[2]>0 then
    self.show_graphic[2]=self.show_graphic[2]-1
  end

  -- clear visual
  for row=1,8 do
    for col=1,self.grid_width do
      self.visual[row][col]=0
    end
  end

  return self.visual
end

function Granchild:grid_redraw()
  self.g:all(0)
  local gd=self:get_visual()
  for row=1,8 do
    for col=1,self.grid_width do
      if gd[row][col]~=0  then
        self.g:led(col,row,gd[row][col])
      end
    end
  end
  self.g:refresh()
end

return Granchild