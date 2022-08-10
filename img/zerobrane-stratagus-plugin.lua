
-- Start copy from spec/lua.lua 
local unpack = table.unpack or unpack
local funcdef = "([A-Za-z_][A-Za-z0-9_%.%:]*)%s*"
local decindent = {
  ['else'] = true, ['elseif'] = true, ['until'] = true, ['end'] = true}
local incindent = {
  ['else'] = true, ['elseif'] = true, ['for'] = true, ['do'] = true,
  ['if'] = true, ['repeat'] = true, ['while'] = true}
local function isfndef(str)
  local l
  local s,e,cap,par = string.find(str, "function%s+" .. funcdef .. "(%(.-%))")
  -- try to match without brackets now, but only at the beginning of the line
  if (not s) then
    s,e,cap = string.find(str, "^%s*function%s+" .. funcdef)
  end
  -- try to match "foo = function()"
  if (not s) then
    s,e,cap,par = string.find(str, funcdef .. "=%s*function%s*(%(.-%))")
  end
  if (s) then
    l = string.find(string.sub(str,1,s-1),"local%s+$")
    cap = cap .. " " .. (par or "(?)")
  end
  return s,e,cap,l
end
local q = EscapeMagic

local PARSE = require 'lua_parser_loose'
local LEX = require 'lua_lexer_loose'

local function ldoc(tx, typepatt)
  local varname = "([%w_]+)"
  -- <type> == ?string, ?|T1|T2
  -- anything that follows optional "|..." is ignored
  local typename = "%??"..typepatt
  -- @tparam[...] <type> <paramname>
  -- @param[type=<type>] <paramname>
  -- @string[...] <paramname>; not handled
  local t, v = tx:match("--%s*@tparam%b[]%s+"..typename.."%s+"..varname)
  if not t then -- try without optional [...] part
    t, v = tx:match("--%s*@tparam%s+"..typename.."%s+"..varname)
  end
  if not t then
    t, v = tx:match("--%s*@param%s*%[type="..typename.."%]%s+"..varname)
  end
  return t, v
end

local mapspec = {
  exts = {"sms", "smp"},
  lexer = wxstc.wxSTC_LEX_LUA,
  apitype = "lua",
  linecomment = "--",
  sep = ".:",
  isdecindent = function(str)
    str = (str
      :gsub('%[=*%[.-%]=*%]','') -- remove long strings
      :gsub("%b[]","") -- remove all table indexes
      :gsub('%[=*%[.*',''):gsub('.*%]=*%]','') -- remove partial long strings
      :gsub('%-%-.*','') -- strip comments after strings are processed
      :gsub("%b()","()") -- remove all function calls
    )
    -- this handles three different cases:
    local term = (str:match("^%s*([%w_]+)%s*$")
      or str:match("^%s*(elseif)[%s%(]")
      or str:match("^%s*(until)[%s%(]")
      or str:match("^%s*(else)%f[^%w_]")
    )
    -- (1) 'end', 'elseif', 'else', 'until'
    local match = term and decindent[term]
    -- (2) 'end)', 'end}', 'end,', and 'end;'
    if not term then term, match = str:match("^%s*(end)%s*([%)%}]*)%s*[,;]?") end
    -- endFoo could be captured as well; filter it out
    if term and str:match("^%s*(end)[%w_]") then term = nil end
    -- (3) '},', '};', '),' and ');'
    if not term then match = str:match("^%s*[%)%}]+%s*[,;]?%s*$") end

    return match and 1 or 0, match and term and 1 or 0
  end,
  isincindent = function(str)
    -- remove "long" comments and escaped slashes (to process \' and \" below)
    str = str:gsub('%-%-%[=*%[.-%]=*%]',' '):gsub('\\[\\\'"]','')
    while true do
      local num, sep = nil, str:match("['\"]")
      if not sep then break end
      str, num = str:gsub(sep..".-\\"..sep,sep):gsub(sep..".-"..sep," ")
      if num == 0 then break end
    end
    str = (str
      :gsub('%[=*%[.-%]=*%]',' ') -- remove long strings
      :gsub('%b[]',' ') -- remove all table indexes
      :gsub('%[=*%[.*',''):gsub('.*%]=*%]','') -- remove partial long strings
      :gsub('%-%-.*','') -- strip comments after strings are processed
      :gsub("%b()","()") -- remove all function calls
    )

    local func = (isfndef(str) or str:match("%f[%w_]function%s*%(")) and 1 or 0
    local term = str:match("^%s*([%w_]+)%W*")
    local terminc = term and incindent[term] and 1 or 0
    -- fix 'if' not terminated with 'then'
    -- or 'then' not started with 'if'
    if (term == 'if' or term == 'elseif') and not str:match("%f[%w_]then%f[^%w_]")
    or (term == 'for') and not str:match("%f[%w_]do%f[^%w_]")
    or (term == 'while') and not str:match("%f[%w_]do%f[^%w_]")
    -- or `repeat ... until` are on the same line
    or (term == 'repeat') and str:match("%f[%w_]until%f[^%w_]")
    -- if this is a function definition, then don't increment the level
    or func == 1 then
      terminc = 0
    elseif not (term == 'if' or term == 'elseif') and str:match("%f[%w_]then%f[^%w_]")
    or not (term == 'for') and str:match("%f[%w_]do%f[^%w_]")
    or not (term == 'while') and str:match("%f[%w_]do%f[^%w_]") then
      terminc = 1
    end
    local _, opened = str:gsub("([%{%(])", "%1")
    local _, closed = str:gsub("([%}%)])", "%1")
    -- ended should only be used to negate term and func effects
    local anon = str:match("%f[%w_]function%s*%(.+[^%w_]end%f[^%w_]")
    local ended = (terminc + func > 0) and (str:match("[^%w_]+end%s*$") or anon) and 1 or 0

    return opened - closed + func + terminc - ended
  end,
  marksymbols = function(code, pos, vars)
    local lx = LEX.lexc(code, nil, pos)
    return coroutine.wrap(function()
      local varnext = {}
      PARSE.parse_scope_resolve(lx, function(op, name, lineinfo, vars, nobreak)
        if not(op == 'Id' or op == 'Statement' or op == 'Var'
            or op == 'Function' or op == 'String'
            or op == 'VarNext' or op == 'VarInside' or op == 'VarSelf'
            or op == 'FunctionCall' or op == 'Scope' or op == 'EndScope') then
          return end -- "normal" return; not interested in other events

        -- level needs to be adjusted for VarInside as it comes into scope
        -- only after next block statement
        local at = vars[0] and (vars[0] + (op == 'VarInside' and 1 or 0))
        if op == 'Statement' then
          for _, token in pairs(varnext) do coroutine.yield(unpack(token)) end
          varnext = {}
        elseif op == 'VarNext' or op == 'VarInside' then
          table.insert(varnext, {'Var', name, lineinfo, vars, at, nobreak})
        end

        coroutine.yield(op, name, lineinfo, vars, op == 'Function' and at-1 or at, nobreak)
      end, vars)
    end)
  end,

  typeassigns = function(editor)
    local maxlines = 48 -- scan up to this many lines back
    local iscomment = editor.spec.iscomment
    local assigns = {}
    local endline = editor:GetCurrentLine()-1
    local line = math.max(endline-maxlines, 0)

    while (line <= endline) do
      local ls = editor:PositionFromLine(line)
      local tx = editor:GetLine(line) --= string
      local s = bit.band(editor:GetStyleAt(ls + #tx:match("^%s*") + 2),31)

      -- check for assignments
      local sep = editor.spec.sep
      local varname = "([%w_][%w_"..q(sep:sub(1,1)).."]*)"
      local identifier = "([%w_][%w_"..q(sep).."%s]*)"

      -- special hint
      local typ, var = tx:match("%s*%-%-=%s*"..varname.."%s+"..identifier)
      local ldoctype, ldocvar = ldoc(tx, varname)
      if var and typ then
        assigns[var] = typ:gsub("%s","")
      elseif ldoctype and ldocvar then
        assigns[ldocvar] = ldoctype
      elseif not iscomment[s] then
        -- real assignments
        local var,typ = tx:match("%s*"..identifier.."%s*=%s*([^;]+)")

        var = var and var:gsub("local",""):gsub("%s","")
        -- remove assert() calls as they don't affect their parameter types
        typ = typ and typ:gsub("assert%s*(%b())", function(s) return s:gsub("^%(",""):gsub("%)$","") end)
        -- handle `require` as a special case that returns a type that matches its parameter
        -- (this is without deeper analysis on loaded files and should work most of the time)
        local req = typ and typ:match("^require%s*%(?%s*['\"](.+)['\"]%s*%)?")
        typ = req or typ
        typ = (typ and typ
          :gsub("%b()","")
          :gsub("%b{}","")
          :gsub("%b[]",".0")
          -- replace concatenation with addition to avoid misidentifying types
          :gsub("%.%.+","+")
          -- remove comments; they may be in strings, but that's okay here
          :gsub("%-%-.*",""))
        if (typ and (typ:match(",") or typ:match("%sor%s") or typ:match("%sand%s"))) then
          typ = nil
        end
        typ = typ and typ:gsub("%s","")
        typ = typ and typ:gsub(".+", function(s)
            return (s:find("^'[^']*'$")
              or s:find('^"[^"]*"$')
              or s:find('^%[=*%[.*%]=*%]$')) and 'string' or s
          end)

        -- filter out everything that is not needed
        if typ and typ ~= 'string' -- special value for all strings
        and (not typ:match('^'..identifier..'$') -- not an identifier
          or typ:match('^%d') -- or a number
          or editor.api.tip.keys[typ] -- or a keyword
          ) then
          typ = nil
        end

        if (var and typ) then
          if (assigns[typ] and not req) then
            assigns[var] = assigns[typ]
          else
            if req then assigns[req] = nil end
            assigns[var] = typ
          end
        end
      end
      line = line+1
    end

    return assigns
  end,

  lexerstyleconvert = {
    text = {wxstc.wxSTC_LUA_IDENTIFIER,},

    lexerdef = {wxstc.wxSTC_LUA_DEFAULT,},
    comment = {wxstc.wxSTC_LUA_COMMENT,
      wxstc.wxSTC_LUA_COMMENTLINE,
      wxstc.wxSTC_LUA_COMMENTDOC,},
    stringtxt = {wxstc.wxSTC_LUA_STRING,
      wxstc.wxSTC_LUA_CHARACTER,
      wxstc.wxSTC_LUA_LITERALSTRING,},
    stringeol = {wxstc.wxSTC_LUA_STRINGEOL,},
    preprocessor= {wxstc.wxSTC_LUA_PREPROCESSOR,},
    operator = {wxstc.wxSTC_LUA_OPERATOR,},
    number = {wxstc.wxSTC_LUA_NUMBER,},

    keywords0 = {wxstc.wxSTC_LUA_WORD,},
    keywords1 = {wxstc.wxSTC_LUA_WORD2,},
    keywords2 = {wxstc.wxSTC_LUA_WORD3,},
    keywords3 = {wxstc.wxSTC_LUA_WORD4,},
    keywords4 = {wxstc.wxSTC_LUA_WORD5,},
    keywords5 = {wxstc.wxSTC_LUA_WORD6,},
    keywords6 = {wxstc.wxSTC_LUA_WORD7,},
    keywords7 = {wxstc.wxSTC_LUA_WORD8,},
  },

  keywords = {
    -- keywords
    [[and break do else elseif end for function goto if in local not or repeat return then until while]],

    -- constants/variables
    [[_G _VERSION _ENV false io.stderr io.stdin io.stdout nil math.huge math.pi self true package.cpath package.path]],

    -- core/global functions
    [[assert collectgarbage dofile error getfenv getmetatable ipairs load loadfile loadstring
      module next pairs pcall print rawequal rawget rawlen rawset require
      select setfenv setmetatable tonumber tostring type unpack xpcall]],

    -- library functions
    [[bit32.arshift bit32.band bit32.bnot bit32.bor bit32.btest bit32.bxor bit32.extract
      bit32.lrotate bit32.lshift bit32.replace bit32.rrotate bit32.rshift
      coroutine.create coroutine.resume coroutine.running coroutine.status coroutine.wrap coroutine.yield
      coroutine.isyieldable
      debug.debug debug.getfenv debug.gethook debug.getinfo debug.getlocal
      debug.getmetatable debug.getregistry debug.getupvalue debug.getuservalue debug.setfenv
      debug.sethook debug.setlocal debug.setmetatable debug.setupvalue debug.setuservalue
      debug.traceback debug.upvalueid debug.upvaluejoin
      io.close io.flush io.input io.lines io.open io.output io.popen io.read io.tmpfile io.type io.write
      close flush lines read seek setvbuf write
      math.abs math.acos math.asin math.atan math.atan2 math.ceil math.cos math.cosh math.deg math.exp
      math.floor math.fmod math.frexp math.ldexp math.log math.log10 math.max math.min math.modf
      math.pow math.rad math.random math.randomseed math.sin math.sinh math.sqrt math.tan math.tanh
      math.type math.tointeger math.maxinteger math.mininteger math.ult
      os.clock os.date os.difftime os.execute os.exit os.getenv os.remove os.rename os.setlocale os.time os.tmpname
      package.loadlib package.searchpath package.seeall package.config
      package.loaded package.loaders package.preload package.searchers
      string.byte string.char string.dump string.find string.format string.gmatch string.gsub string.len
      string.lower string.match string.rep string.reverse string.sub string.upper
      byte find format gmatch gsub len lower match rep reverse sub upper
      table.move, string.pack, string.unpack, string.packsize
      table.concat table.insert table.maxn table.pack table.remove table.sort table.unpack]]
  },
}
-- end copy from spec/lua.lua

local api = {
  DefineSpell = { type = "function", description = "Parse Spell.\n\n  @param l  Lua state." },
  AddMessage = { type = "function", description = "Description\n\n  Add a new message.\n\n Example:\n\n AddMessage(\"Hello World!\")\n\n  @param l  Lua state." },
  SetKeyScrollSpeed = { type = "function", description = "Description\n\n  Set speed of key scroll\n\n  @param l  Lua state.\n\n Example:\n\n SetKeyScrollSpeed(4)" },
  GetKeyScrollSpeed = { type = "function", description = "Description\n\n  Get speed of key scroll\n\n  @param l  Lua state.\n\n Example:\n\n scroll_speed = GetKeyScrollSpeed()\n		print(scroll_speed)" },
  SetMouseScrollSpeed = { type = "function", description = "Description\n\n  Set speed of mouse scroll\n\n  @param l  Lua state.\n\n Example:\n\n SetMouseScrollSpeed(2)" },
  GetMouseScrollSpeed = { type = "function", description = "Description\n\n  Get speed of mouse scroll\n\n  @param l  Lua state.\n\n Example:\n\n scroll_speed = GetMouseScrollSpeed()\n		print(scroll_speed)" },
  SetMouseScrollSpeedDefault = { type = "function", description = "Set speed of middle-mouse scroll\n\n  @param l  Lua state." },
  GetMouseScrollSpeedDefault = { type = "function", description = "Get speed of middle-mouse scroll\n\n  @param l  Lua state." },
  SetMouseScrollSpeedControl = { type = "function", description = "Set speed of ctrl-middle-mouse scroll\n\n  @param l  Lua state." },
  GetMouseScrollSpeedControl = { type = "function", description = "Get speed of ctrl-middle-mouse scroll\n\n  @param l  Lua state." },
  SetClickMissile = { type = "function", description = "Set which missile is used for right click\n\n  @param l  Lua state." },
  SetDamageMissile = { type = "function", description = "Set which missile shows Damage\n\n  @param l  Lua state." },
  SetVideoResolution = { type = "function", description = "Description\n\n  Set the video resolution.\n\n  @param l  Lua state.\n\n Example:\n\n SetVideoResolution(640,480)" },
  GetVideoResolution = { type = "function", description = "Description\n\n  Get the video resolution.\n\n  @param l  Lua state.\n\n Example:\n\n width,height = GetVideoResolution()\n		print(\"Resolution  is \" .. width .. \"x\" .. height)" },
  SetVideoFullScreen = { type = "function", description = "Description\n\n  Set the video fullscreen mode.\n\n  @param l  Lua state.\n\n Example:\n\n -- Full Screen mode enabled\n		SetVideoFullScreen(true)\n		-- Full Screen mode disabled\n		SetVideoFullScreen(false)" },
  GetVideoFullScreen = { type = "function", description = "Description\n\n  Get the video fullscreen mode.\n\n  @param l  Lua state.\n\n Example:\n\n fullscreenmode = GetVideoFullScreen()\n		print(fullscreenmode)" },
  SetWindowSize = { type = "function", description = "Request a specific initial window size" },
  SetVerticalPixelSize = { type = "function", description = "For games with non-square pixels, this sets the scale of vertical pixels versus horizontal pixels.\n e.g., if your assets are 320x200, but you render at 320x240, this is 1.2." },
  SetFontCodePage = { type = "function", description = "Description\n\n Declare which codepage the font files are in. Text is handled internally\n as UTF-8 everywhere, but the font rendering system uses graphics with 256\n symbols. Commonly, DOS and early Windows games used codepage 437 or 1252 for\n western European languages, or 866 for Russian and some other cyrillic\n writing systems. These are the only ones that are currently supported, but\n more can easily be added. All text is mapped into the codepage that is set\n for the font files. If the codepage is not one of the supported ones, or if\n something doesn't map (for example, some accented characters with codepage\n 866, or cyrillic letters with codepage 437), a simple \"visual\" mapping to\n 7-bit ASCII is used to at least print something that may be recognizable." },
  SetTitleScreens = { type = "function", description = "Default title screens.\n\n  @param l  Lua state." },
  ShowTitleScreens = { type = "function", description = "" },
  DefinePanelContents = { type = "function", description = "Define the Panels.\n  Define what is shown in the panel(text, icon, variables)\n\n  @param l  Lua state.\n  @return   0." },
  DefinePopup = { type = "function", description = "Define the Panels.\n  Define what is shown in the panel(text, icon, variables)\n\n  @param l  Lua state.\n  @return   0." },
  DefineViewports = { type = "function", description = "Define the viewports.\n\n  @param l  Lua state." },
  RightButtonAttacks = { type = "function", description = "Fighter right button attacks as default.\n\n  @param l  Lua state." },
  RightButtonMoves = { type = "function", description = "Fighter right button moves as default.\n\n  @param l  Lua state." },
  SetFancyBuildings = { type = "function", description = "Description\n\n  Enable/disable the fancy buildings.\n\n  @param l  Lua state.\n\n Example:\n\n -- Enable fancy buildings\n		  SetFancyBuildings(true)\n		  -- Disable fancy buildings\n		  SetFancyBuildings(false)" },
  DefineButton = { type = "function", description = "Define a button.\n\n  @param l  Lua state." },
  ClearButtons = { type = "function", description = "Clear all buttons\n\n  @param l  Lua state." },
  CopyButtonsForUnitType = { type = "function", description = "" },
  DefineButtonStyle = { type = "function", description = "Define a button style\n\n  @param l  Lua state." },
  PresentMap = { type = "function", description = "Description\n\n Set basic map caracteristics.\n\n  @param l  Lua state.\n\n Example:\n\n PresentMap(\"Map description\", 1, 128, 128, 17)" },
  DefineMapSetup = { type = "function", description = "Description\n\n Define the lua file that will build the map\n\n  @param l  Lua state.\n\n Example:\n\n -- Load map setup from file\n		DefineMapSetup(\"Setup.sms\")" },
  SetSelectionStyle = { type = "function", description = "Set selection style.\n\n  @param l  Lua state." },
  SetGroupKeys = { type = "function", description = "Set the keys which are use for grouping units, helpful for other keyboards\n\n  @param l  Lua state." },
  DefineDependency = { type = "function", description = "Define a new dependency.\n\n  @param l  Lua state." },
  GetDependency = { type = "function", description = "Get the dependency.\n\n  @todo not written.\n\n  @param l  Lua state." },
  CheckDependency = { type = "function", description = "Checks if dependencies are met.\n\n  @return true if the dependencies are met.\n\n  @param l  Lua state.\n  Argument 1: player\n  Argument 2: object which we want to check the dependencies of" },
  DefineModifier = { type = "function", description = "Define a new upgrade modifier.\n\n  @param l  List of modifiers." },
  DefineAllow = { type = "function", description = "Description\n\n  Define which units/upgrades are allowed.\n\n Example:\n\n DefineAllow(\"unit-town-hall\",\"AAAAAAAAAAAAAAAA\") -- Available for everybody\n		DefineAllow(\"unit-stables\",\"FFFFFFFFFFFFFFFF\") -- Not available\n		DefineAllow(\"upgrade-sword1\",\"RRRRRRRRRRRRRRRR\") -- Upgrade already researched." },
  DefineUnitAllow = { type = "function", description = "Define which units are allowed and how much." },
  SetTrainingQueue = { type = "function", description = "Description\n\n  Set training queue\n\n  @param l  Lua state.\n\n  @return  The old state of the training queue\n\n Example:\n\n -- Training queue available. Train multiple units.\n		SetTrainingQueue(true)\n		-- Train one unit at a time.\n		SetTrainingQueue(false)" },
  SetBuildingCapture = { type = "function", description = "Set capture buildings\n\n  @param l  Lua state.\n\n  @return   The old state of the flag\n\n Example:\n\n SetBuildingCapture(true)\n	SetBuildingCapture(false)" },
  SetRevealAttacker = { type = "function", description = "Set reveal attacker\n\n  @param l  Lua state.\n\n  @return   The old state of the flag\n\n Example:\n\n SetRevealAttacker(true)\n	SetRevealAttacker(false)" },
  ResourcesMultiBuildersMultiplier = { type = "function", description = "Set cost multiplier to RepairCost for buildings additional workers helping (0 = no additional cost)\n\n  @param l  Lua state.\n\n Example:\n\n -- No cost\n	ResourcesMultiBuildersMultiplier(0)\n	-- Each builder helping will cost 1 resource\n	ResourcesMultiBuildersMultiplier(1)\n	-- Each builder helping will cost 10 resource\n	ResourcesMultiBuildersMultiplier(10)" },
  Unit = { type = "function", description = "Parse unit\n\n  @param l  Lua state.\n\n  @todo  Verify that vision table is always correct (transporter)\n  @todo (PlaceUnit() and host-info).\n\n Example:\n\n footman = CreateUnit(\"unit-footman\", 0, {0, 1})\n	-- The unit will appear selected\n	Unit(footman,{\"selected\"})\n	-- The unit will be considered destroyed\n	Unit(footman,{\"destroyed\"})\n	-- The unit will be considered removed\n	Unit(footman,{\"removed\"})\n	-- The unit will be considered as a summoned unit\n	Unit(footman,{\"summoned\",500})\n	-- The unit will face on south\n	Unit(footman,{\"direction\",0})\n	-- The unit will be displayed with his 3rd frame\n	Unit(footman,{\"frame\", 3})\n	-- The footman will have a high sight\n	Unit(footman,{\"current-sight-range\",9})\n	-- Change the unit color to be the ones from player 1\n	Unit(footman,{\"rescued-from\",1})" },
  MoveUnit = { type = "function", description = "Move a unit on map.\n\n  @param l  Lua state.\n\n  @return   Returns the slot number of the made placed.\n\n Example:\n\n -- Create the unit\n	footman = CreateUnit(\"unit-footman\", 0, {7, 4})\n	-- Move the unit to position 20 (x) and 10 (y)\n	MoveUnit(footman,{20,10})" },
  RemoveUnit = { type = "function", description = "Description\n\n  Remove unit from the map.\n\n  @param l  Lua state.\n\n  @return   Returns 1.\n\n Example:\n\n ogre = CreateUnit(\"unit-ogre\", 0, {24, 89})\n\n		AddTrigger(\n  		function() return (GameCycle > 150) end,\n  		function()\n    			RemoveUnit(ogre)\n    			return false end -- end of function\n		)" },
  CreateUnit = { type = "function", description = "Description\n\n  Create a unit and place it on the map\n\n  @param l  Lua state.\n\n  @return   Returns the slot number of the made unit.\n\n Example:\n\n CreateUnit(\"unit-human-transport\", 1, {94, 0})" },
  TransformUnit = { type = "function", description = "Description\n\n  'Upgrade' a unit in place to a unit of different type.\n\n  @param l  Lua state.\n\n  @return   Returns success.\n\n Example:\n\n -- Make a peon for player 5\n		peon = CreateUnit(\"unit-peon\", 5, {58, 9})\n		-- The peon will be trasformed into a Grunt\n		TransformUnit(peon,\"unit-grunt\")" },
  DamageUnit = { type = "function", description = "Description\n\n  Damages unit, additionally using another unit as first's attacker\n\n  @param l  Lua state.\n\n  @return   Returns the slot number of the made unit.\n\n Example:\n\n -- Make a grunt for player 5\n		grunt = CreateUnit(\"unit-grunt\", 5, {58, 8})\n		-- Damage the grunt with 15 points\n		DamageUnit(-1,grunt,15)" },
  SetResourcesHeld = { type = "function", description = "Set resources held by a unit\n\n  @param l  Lua state." },
  SetTeleportDestination = { type = "function", description = "Set teleport deastination for teleporter unit\n\n  @param l  Lua state." },
  OrderUnit = { type = "function", description = "Description\n\n  Order a unit\n\n  @param l  Lua state.\n\n  OrderUnit(player, unit-type, start_loc, dest_loc, order)\n\n Example:\n\n -- Move transport from position x=94,y=0 to x=80,y=9\n		OrderUnit(1,\"unit-human-transport\",{94,0},{80,9},\"move\")" },
  KillUnit = { type = "function", description = "Description\n\n  Kill a unit\n\n  @param l  Lua state.\n\n  @return   Returns true if a unit was killed.\n\n Example:\n\n -- Kills an ogre controlled by player 3\n		KillUnit(\"unit-ogre\", 3)" },
  KillUnitAt = { type = "function", description = "Description\n\n  Kill a unit at a location\n\n  @param l  Lua state.\n\n  @return   Returns the number of units killed.\n\n Example:\n\n -- Kill 8 peasants controlled by player 7 from position {27,1} to {34,5}\n		KillUnitAt(\"unit-peasant\",7,8,{27,1},{34,5})" },
  FindNextResource = { type = "function", description = "Find the next reachable resource unit that gives resource starting from a worker.\n  Optional third argument is the range to search.\n\n  @param l  Lua state.\n\n Example:\n\n \n		peon = CreateUnit(\"unit-peon\", 5, {58, 8})\n      goldmine = FindNextResource(peon, 0)" },
  GetUnits = { type = "function", description = "Description\n\n  Get a player's units\n\n  @param l  Lua state.\n\n  @return   Array of units.\n\n Example:\n\n -- Get units from player 0\n	units = GetUnits(0)\n	for i, id_unit in ipairs(units) do\n	    print(id_unit)\n	end" },
  GetUnitsAroundUnit = { type = "function", description = "Description\n\n  Get a player's units in rectangle box specified with 2 coordinates\n\n  @param l  Lua state.\n\n  @return   Array of units.\n\n Example:\n\n circlePower = CreateUnit(\"unit-circle-of-power\", 15, {59, 4})\n		-- Get the units near the circle of power.\n      unitsOnCircle = GetUnitsAroundUnit(circle,1,true)" },
  GetUnitBoolFlag = { type = "function", description = "Get the value of the unit bool-flag.\n\n  @param l  Lua state.\n\n  @return   The value of the bool-flag of the unit." },
  GetUnitVariable = { type = "function", description = "Description\n\n  Get the value of the unit variable.\n\n  @param l  Lua state.\n\n  @return   The value of the variable of the unit.\n\n Example:\n\n -- Make a grunt for player 5\n		grunt = CreateUnit(\"unit-grunt\", 5, {58, 8})\n		-- Take the name of the unit\n		unit_name = GetUnitVariable(grunt,\"Name\")\n		-- Take the player number based on the unit\n		player_type = GetUnitVariable(grunt,\"PlayerType\")\n		-- Take the value of the armor\n		armor_value = GetUnitVariable(grunt,\"Armor\")\n		-- Show the message in the game.\n		AddMessage(unit_name .. \" \" .. player_type .. \" \" .. armor_value)" },
  SetUnitVariable = { type = "function", description = "Description\n\n  Set the value of the unit variable.\n\n  @param l  Lua state.\n\n  @return The new value of the unit.\n\n Example:\n\n -- Create a blacksmith for player 2\n blacksmith = CreateUnit(\"unit-human-blacksmith\", 2, {66, 71})\n -- Specify the amount of hit points to assign to the blacksmith\n SetUnitVariable(blacksmith,\"HitPoints\",344)\n -- Set the blacksmiths color to the color of player 4\n SetUnitVariable(blacksmith,\"Color\",4)\n " },
  SlotUsage = { type = "function", description = "Get the usage of unit slots during load to allocate memory\n\n  @param l  Lua state." },
  SelectSingleUnit = { type = "function", description = "Description\n\n  Select a single unit \n\n  @param l  Lua state.\n\n  @return 0, meaning the unit is selected.\n\n Example:\n\n -- Make the hero unit Grom Hellscream for player 5\n		grom = CreateUnit(\"unit-beast-cry\", 5, {58, 8})\n		-- Select only the unit Grom Hellscream\n		SelectSingleUnit(grom)" },
  EnableSimplifiedAutoTargeting = { type = "function", description = "Enable/disable simplified auto targeting \n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  DefineSprites = { type = "function", description = "Define the sprite to show variables.\n\n  @param l    Lua_state" },
  DefineUnitType = { type = "function", description = "Description\n\n  Parse unit-type.\n\n  @param l  Lua state.\n\n Example:\n\n DefineUnitType(\"unit-silvermoon-archer\", { Name = _(\"Silvermoon Archer\"),\n			Image = {\"file\", \"human/units/elven_archer.png\", \"size\", {72, 72}},\n			Animations = \"animations-archer\", Icon = \"icon-archer\",\n			Costs = {\"time\", 70, \"gold\", 500, \"wood\", 50},\n			Speed = 10,\n			HitPoints = 45,\n			DrawLevel = 40,\n			TileSize = {1, 1}, BoxSize = {33, 33},\n			SightRange = 6, ComputerReactionRange = 7, PersonReactionRange = 6,\n			BasicDamage = 4, PiercingDamage = 6, Missile = \"missile-arrow\",\n			MaxAttackRange = 4,\n			Priority = 75,\n			Points = 60,\n			Demand = 1,\n			Corpse = \"unit-human-dead-body\",\n			Type = \"land\",\n			RightMouseAction = \"attack\",\n			CanAttack = true,\n			CanTargetLand = true, CanTargetSea = true, CanTargetAir = true,\n			LandUnit = true,\n			organic = true,\n			SelectableByRectangle = true,\n			Sounds = {\n				\"selected\", \"archer-selected\",\n				\"acknowledge\", \"archer-acknowledge\",\n				\"ready\", \"archer-ready\",\n				\"help\", \"basic human voices help 1\",\n				\"dead\", \"basic human voices dead\"} } )" },
  CopyUnitType = { type = "function", description = "Description\n\n  Copy a unit type.\n\n  @param l  Lua state.\n\n Example:\n\n CopyUnitType(\"unit-peasant\", \"unit-peasant-copy\")" },
  DefineUnitStats = { type = "function", description = "Description\n\n  Parse unit-stats.\n\n  @param l  Lua state.\n\n Example:\n\n DefineUnitStats(\"unit-berserker\", 2, {\n    		\"HitPoints\", {Value = 55, Max = 55, Increase = 0, Enable = true},\n    		\"AttackRange\", {Value = 5, Max = 6, Increase = 0, Enable = true},\n    		\"SightRange\", {Value = 7, Max = 7, Increase = 0, Enable = true},\n  		})" },
  DefineBoolFlags = { type = "function", description = "Define boolean flag.\n\n  @param l  Lua state." },
  DefineVariables = { type = "function", description = "Define user variables.\n\n  @param l  Lua state." },
  DefineDecorations = { type = "function", description = "Define Decorations for user variables\n\n  @param l  Lua state.\n\n  @todo modify Assert with luastate with User Error.\n  @todo continue to add configuration." },
  DefinePaletteSwap = { type = "function", description = "" },
  DefineExtraDeathTypes = { type = "function", description = "Define default extra death types.\n\n  @param l  Lua state." },
  UnitType = { type = "function", description = "Get unit-type structure.\n\n  @param l  Lua state.\n\n  @return   Unit-type structure." },
  UnitTypeArray = { type = "function", description = "Get all unit-type structures.\n\n  @param l  Lua state.\n\n  @return   An array of all unit-type structures." },
  GetUnitTypeIdent = { type = "function", description = "Get the ident of the unit-type structure.\n\n  @param l  Lua state.\n\n  @return   The identifier of the unit-type." },
  GetUnitTypeName = { type = "function", description = "Description\n\n  Get the name of the unit-type structure.\n\n  @param l  Lua state.\n\n  @return   The name of the unit-type.\n\n Example:\n\n name = GetUnitTypeName(\"unit-knight\")\n		  print(name)" },
  SetUnitTypeName = { type = "function", description = "Description\n\n  Set the name of the unit-type structure.\n\n  @param l  Lua state.\n\n  @return   The name of the unit-type.\n\n Example:\n\n SetUnitTypeName(\"unit-beast-cry\",\"Doomhammer\")" },
  GetUnitTypeData = { type = "function", description = "Description\n\n  Get unit type data.\n\n  @param l  Lua state.\n\n Example:\n\n -- Get the amount of supply from Human Farms\n		  supply = GetUnitTypeData(\"unit-farm\",\"Supply\")\n		  print(supply)" },
  DefineMissileType = { type = "function", description = "Parse missile-type.\n\n  @param l  Lua state." },
  Missile = { type = "function", description = "Create a missile.\n\n  @param l  Lua state." },
  DefineBurningBuilding = { type = "function", description = "Define burning building missiles.\n\n  @param l  Lua state." },
  CreateMissile = { type = "function", description = "Create a missile on the map\n\n  @param l  Lua state." },
  GetShaderNames = { type = "function", description = "Description\n\n  Get the list of shaders.\n\n Example:\n\n shaders = GetShaderNames()\n	for i,name in ipairs(shaders) do\n		print(name)\n	end" },
  GetShader = { type = "function", description = "Description\n\n  Get the active shader.\n\n Example:\n\n shader_name = GetShader()\n	print(shader_name)" },
  SetShader = { type = "function", description = "Description\n\n  Apply a shader.\n\n Example:\n\n -- Apply a VHS shader\n	SetShader(\"VHS\")" },
  SetVideoSyncSpeed = { type = "function", description = "Set the video sync speed\n\n  @param l  Lua state." },
  DefineCursor = { type = "function", description = "Define a cursor.\n\n  @param l  Lua state." },
  SetGameCursor = { type = "function", description = "Set the current game cursor.\n\n  @param l  Lua state." },
  DefineAnimations = { type = "function", description = "Define a unit-type animation set.\n\n  @param l  Lua state." },
  SetGlobalSoundRange = { type = "function", description = "Description\n\n  Set the cut off distance.\n\n  @param l  Lua state.\n\n Example:\n\n SetGlobalSoundRange(200)" },
  DefineGameSounds = { type = "function", description = "Glue between c and scheme. Allows to specify some global game sounds\n  in a ccl file.\n\n  @param l  Lua state." },
  MapSound = { type = "function", description = "Glue between c and scheme. Ask to the sound system to remap a sound id\n  to a given name.\n\n  @param l  Lua state.\n\n  @return   the sound object" },
  SoundForName = { type = "function", description = "Glue between c and scheme. Ask the sound system to associate a\n  sound id to a sound name.\n\n  @param l  Lua state." },
  SetSoundRange = { type = "function", description = "Set the range of a given sound.\n\n  @param l  Lua state." },
  MakeSound = { type = "function", description = "Create a sound.\n\n  Glue between c and scheme. This function asks the sound system to\n  register a sound under a given name, with an associated list of files\n  (the list can be replaced by only one file).\n\n  @param l  Lua state.\n\n  @return   the sound id of the created sound" },
  MakeSoundGroup = { type = "function", description = "Glue between c and scheme. This function asks the sound system to\n  build a special sound group.\n\n  @param l  Lua state.\n\n  @return   The sound id of the created sound" },
  PlaySound = { type = "function", description = "Description\n\n  Ask the sound system to play the specified sound.\n\n  @param l  Lua state.\n\n Example:\n\n PlaySound(\"rescue (orc)\")" },
  StratagusMap = { type = "function", description = "Parse a map.\n\n  @param l  Lua state." },
  RevealMap = { type = "function", description = "Reveal the complete map.\n\n  @param l  Lua state." },
  CenterMap = { type = "function", description = "Description\n\n  Center the map.\n\n  @param l  Lua state.\n\n Example:\n\n -- Center the view at position x=11 and y=1.\n		  CenterMap(11, 1)" },
  SetStartView = { type = "function", description = "Description\n\n  Define the starting viewpoint for a given player.\n\n  @param l  Lua state.\n\n Example:\n\n -- Start view for player 0.\n		  SetStartView(0, 25, 12)\n		  -- Start view for player 1.\n		  SetStartView(1, 71, 38)" },
  ShowMapLocation = { type = "function", description = "Show Map Location\n\n  @param l  Lua state." },
  SetTileSize = { type = "function", description = "Description\n\n  Define size in pixels (x,y) of a tile in this game\n\n  @param l  Lua state.\n\n Example:\n\n SetTileSize(32,32)" },
  SetFogOfWar = { type = "function", description = "Description\n\n  Set fog of war on/off.\n\n Example:\n\n SetFogOfWar(true)\n\n  @param l  Lua state." },
  GetFogOfWar = { type = "function", description = "Description\n\n  Get if the fog of war is enabled.\n\n  @param l  Lua state.\n\n Example:\n\n GetFogOfWar()" },
  SetMinimapTerrain = { type = "function", description = "Description\n\n  Enable display of terrain in minimap.\n\n  @param l  Lua state.\n\n Example:\n\n -- Show the minimap terrain\n		SetMinimapTerrain(true)" },
  SetEnableMapGrid = { type = "function", description = "Activate map grid  (true|false)\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  GetIsMapGridEnabled = { type = "function", description = "Check if map grid is enabled" },
  SetFieldOfViewType = { type = "function", description = "Select unit's field of view algorithm -  ShadowCasting or SimpleRadial\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  GetFieldOfViewType = { type = "function", description = "Get unit's field of view type -  ShadowCasting or SimpleRadial" },
  SetOpaqueFor = { type = "function", description = "Set opaque for the tile's terrain.\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong tile's terrain;" },
  RemoveOpaqueFor = { type = "function", description = "" },
  GetIsOpaqueFor = { type = "function", description = "Check opacity for the tile's terrain.\n\n  @param l  Lua state." },
  SetFogOfWarType = { type = "function", description = "Select which type of Fog of War to use\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  GetFogOfWarType = { type = "function", description = "Get Fog of War type - legacy or enhanced" },
  SetFogOfWarOpacityLevels = { type = "function", description = "Set opacity (alpha) for different levels of fog of war - explored, revealed, unseen\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  SetFogOfWarBlur = { type = "function", description = "Set parameters for FOW blurer (radiuses and number of iterations)\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  SetFogOfWarBilinear = { type = "function", description = "Activate FOW bilinear upscaling type  (true|false)\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  GetIsFogOfWarBilinear = { type = "function", description = "Check if FOW bilinear upscaling enabled" },
  SetFogOfWarGraphics = { type = "function", description = "Define Fog graphics\n\n  @param l  Lua state." },
  SetFogOfWarColor = { type = "function", description = "Description\n\n  Set Fog color.\n\n  @param l  Lua state.\n\n Example:\n\n -- Red fog of war\n		SetFogOfWarColor(128,0,0)" },
  SetMMFogOfWarOpacityLevels = { type = "function", description = "Set opacity (alpha) for different levels of fog of war - explored, revealed, unexplored for mini map\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  SetForestRegeneration = { type = "function", description = "Description\n\n  Set forest regeneration speed.\n\n  @param l  Lua state.\n\n  @return   Old speed\n\n Example:\n\n -- No regeneration.\n		  SetForestRegeneration(0)\n		  -- Slow regeneration every 50 seconds\n		  SetForestRegeneration(50)\n		  -- Extremely slow regeneration every 1h of game time\n		  SetForestRegeneration(3600)" },
  LoadTileModels = { type = "function", description = "Load the lua file which will define the tile models\n\n  @param l  Lua state." },
  DefinePlayerTypes = { type = "function", description = "Define the type of each player available for the map\n\n  @param l  Lua state." },
  DefineTileset = { type = "function", description = "Define tileset\n\n  @param l  Lua state." },
  SetTileFlags = { type = "function", description = "Set the flags like \"water\" for a tile of a tileset\n\n  @param l  Lua state." },
  BuildTilesetTables = { type = "function", description = "Build tileset tables like humanWallTable or mixedLookupTable\n\n Called after DefineTileset and only for tilesets that have wall,\n trees and rocks. This function will be deleted when removing\n support of walls and alike in the tileset." },
  GetTileTerrainName = { type = "function", description = "Get the name of the terrain of the tile.\n\n  @param l  Lua state.\n\n  @return   The name of the terrain of the tile." },
  GetTileTerrainHasFlag = { type = "function", description = "Check if the tile's terrain has a particular flag.\n\n  @param l  Lua state.\n\n  @return   True if has the flag, false if not." },
  SetEnableWallsForSP = { type = "function", description = "Enable walls enabled for single player games (for debug purposes)\n\n  @param l  Lua state.\n\n  @return   0 for success, 1 for wrong type;" },
  GetIsWallsEnabledForSP = { type = "function", description = "Check if walls enabled for single player games (for debug purposes)" },
  GetIsGameHoster = { type = "function", description = "Check if network game was created on this PC" },
  DefineConstruction = { type = "function", description = "Parse the construction.\n\n  @param l  Lua state.\n\n  @note make this more flexible" },
  Player = { type = "function", description = "Parse the player configuration.\n\n  @param l  Lua state." },
  ChangeUnitsOwner = { type = "function", description = "Description\n\n  Change all units owned by one player or change only specific units owned by one player\n\n  @param l  Lua state.\n\n Example:\n\n -- Changes all units owned by player 0 and give to player 1\n		ChangeUnitsOwner({16, 17}, {30, 32}, 0, 1)\n		-- Changes all farms owned by player 0 and give to player 1\n		ChangeUnitsOwner({16, 17}, {30, 32}, 0, 1, \"unit-farm\")" },
  GiveUnitsToPlayer = { type = "function", description = "Description\n\n  GiveUnitsToPlayer(amount, type, fromPlayer, toPlayer)\n  GiveUnitsToPlayer(amount, type, topLeft, bottomRight, fromPlayer, toPlayer)\n  Give some units of a specific type from a player to another player. Optionally only inside a rectangle.\n  Returns number of units actually assigned. This can be smaller than the requested amount if the\n  fromPlayer did not have enough units.\n\n  Instead of a number you can pass \"all\" as the first argument, to hand over all units.\n  \n  Instead of a unit type name, you can pass \"any\", \"unit\", \"building\" as the second argument,\n  to hand over anything, and unit, or any building.\n\n  @param l  Lua state.\n\n Example:\n\n \n   -- Give 2 peasants from player 4 to player 2\n   GiveUnitsToPlayer(2, \"unit-peasant\", 4, 2)\n   -- Give 4 knights from player 5 to player 1 inside the rectangle 2,2 - 14,14\n   GiveUnitsToPlayer(2, \"unit-peasant\", {2,2}, {14,14}, 4, 2)\n   -- Give any 4 units from player 5 to player 1 inside the rectangle 2,2 - 14,14\n   GiveUnitsToPlayer(2, \"any\", 4, 2)\n " },
  GetThisPlayer = { type = "function", description = "Description\n\n  Get ThisPlayer.\n\n  @param l  Lua state.\n\n Example:\n\n GetThisPlayer()" },
  SetThisPlayer = { type = "function", description = "Description\n\n  Set ThisPlayer.\n\n  @param l  Lua state." },
  SetMaxSelectable = { type = "function", description = "Description\n\n  Set the maximum amount of units that can be selected.\n\n  @param l  Lua state.\n\n Example:\n\n -- 9 units can be selected together.\n		  SetMaxSelectable(9)\n		  -- 18 units can be selected together.\n		  SetMaxSelectable(18)\n		  -- 50 units can be selected together.\n		  SetMaxSelectable(50)" },
  SetAllPlayersUnitLimit = { type = "function", description = "Description\n\n  Set players units limit.\n\n  @param l  Lua state.\n\n Example:\n\n SetAllPlayersUnitLimit(200)" },
  SetAllPlayersBuildingLimit = { type = "function", description = "Description\n\n  Set players buildings limit.\n\n  @param l  Lua state.\n\n Example:\n\n SetAllPlayersBuildingLimit(200)" },
  SetAllPlayersTotalUnitLimit = { type = "function", description = "Description\n\n  Set players total units limit.\n\n  @param l  Lua state.\n\n Example:\n\n SetAllPlayersTotalUnitLimit(400)" },
  SetDiplomacy = { type = "function", description = "Description\n\n  Change the diplomacy from player to another player.\n\n  @param l  Lua state.\n\n  @return FIXME: should return old state.\n\n Example:\n\n SetDiplomacy(0,\"allied\",1)\n		SetDiplomacy(1,\"allied\",0)\n		\n		SetDiplomacy(0,\"enemy\",2)\n		SetDiplomacy(1,\"enemy\",2)" },
  GetDiplomacy = { type = "function", description = "Get diplomacy from one player to another. Returns the strings \"allied\",\n  \"enemy\", \"neutral\", or \"crazy\"." },
  Diplomacy = { type = "function", description = "Change the diplomacy from ThisPlayer to another player.\n\n  @param l  Lua state." },
  SetSharedVision = { type = "function", description = "Description\n\n  Change the shared vision from player to another player.\n\n\n  @param l  Lua state.\n\n  @return FIXME: should return old state.\n\n Example:\n\n SetSharedVision(0,true,1)\n		SetSharedVision(1,true,0)\n		\n		SetSharedVision(0,false,2)\n		SetSharedVision(1,false,2)" },
  SharedVision = { type = "function", description = "Change the shared vision from ThisPlayer to another player.\n\n  @param l  Lua state." },
  SetRevelationType = { type = "function", description = "Description\n\n  Change the players revelation type - reveal all units, only buidings or don't reveal anything\n\n  @param l  Lua state.\n\n Example:\n\n SetRevelationType(\"no-revelation\")\n 		SetRevelationType(\"buildings-only\")\n 		SetRevelationType(\"all-units\")" },
  DefineRaceNames = { type = "function", description = "Define race names\n\n @param l Lua state." },
  DefineNewRaceNames = { type = "function", description = "Define race names\n\n @param l Lua state." },
  DefinePlayerColors = { type = "function", description = "Description\n\n  Define player colors. Pass \"false\" as an optional second\n  argument to add the colors to the existing ones.\n\n  @param l  Lua state.\n\n Example:\n\n DefinePlayerColors({\n		\"red\", {{164, 0, 0}, {124, 0, 0}, {92, 4, 0}, {68, 4, 0}},\n		\"blue\", {{12, 72, 204}, {4, 40, 160}, {0, 20, 116}, {0, 4, 76}},\n		\"green\", {{44, 180, 148}, {20, 132, 92}, {4, 84, 44}, {0, 40, 12}},\n		\"violet\", {{152, 72, 176}, {116, 44, 132}, {80, 24, 88}, {44, 8, 44}},\n		\"orange\", {{248, 140, 20}, {200, 96, 16}, {152, 60, 16}, {108, 32, 12}},\n		\"black\", {{40, 40, 60}, {28, 28, 44}, {20, 20, 32}, {12, 12, 20}},\n		\"white\", {{224, 224, 224}, {152, 152, 180}, {84, 84, 128}, {36, 40, 76}},\n		\"yellow\", {{252, 252, 72}, {228, 204, 40}, {204, 160, 16}, {180, 116, 0}},\n		\"red\", {{164, 0, 0}, {124, 0, 0}, {92, 4, 0}, {68, 4, 0}},\n		\"blue\", {{12, 72, 204}, {4, 40, 160}, {0, 20, 116}, {0, 4, 76}},\n		\"green\", {{44, 180, 148}, {20, 132, 92}, {4, 84, 44}, {0, 40, 12}},\n		\"violet\", {{152, 72, 176}, {116, 44, 132}, {80, 24, 88}, {44, 8, 44}},\n		\"orange\", {{248, 140, 20}, {200, 96, 16}, {152, 60, 16}, {108, 32, 12}},\n		\"black\", {{40, 40, 60}, {28, 28, 44}, {20, 20, 32}, {12, 12, 20}},\n		\"white\", {{224, 224, 224}, {152, 152, 180}, {84, 84, 128}, {36, 40, 76}},\n		\"yellow\", {{252, 252, 72}, {228, 204, 40}, {204, 160, 16}, {180, 116, 0}},\n	})" },
  DefinePlayerColorIndex = { type = "function", description = "Define player color indexes\n\n  @param l  Lua state." },
  NewColors = { type = "function", description = "Make new player colors\n\n  @param l  Lua state." },
  GetPlayerData = { type = "function", description = "Description\n\n  Get player data.\n\n  @param l  Lua state.\n\n Example:\n\n GetPlayerData(0,\"TotalNumUnits\")" },
  SetPlayerData = { type = "function", description = "Description\n\n  Set player data.\n\n  @param l  Lua state.\n\n Example:\n\n \n  SetPlayerData(0,\"Name\",\"Nation of Stromgarde\") -- set the name of this player\n	SetPlayerData(0,\"RaceName\",\"human\") -- the the race to human\n 	SetPlayerData(0,\"Resources\",\"gold\",1700) -- set the player to have 1700 gold\n  SetPlayerData(0, \"Allow\", \"upgrade-paladin\", \"R\") -- give the player the Paladin upgrade\n " },
  SetAiType = { type = "function", description = "Description \n \n  Set ai player algo.\n\n  @param l  Lua state.\n \n Example: \n \n   -- Player 1 has a passive A.I \n		  SetAiType(1, \"Passive\")" },
  SetGroupId = { type = "function", description = "Set the current group id. (Needed for load/save)\n\n  @param l  Lua state." },
  Selection = { type = "function", description = "Define the current selection.\n\n  @param l  Lua state." },
  Group = { type = "function", description = "Define the group.\n\n  @param l  Lua state." },
  Add = { type = "function", description = "Return equivalent lua table for add.\n  {\"Add\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Sub = { type = "function", description = "Return equivalent lua table for add.\n  {\"Div\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Mul = { type = "function", description = "Return equivalent lua table for add.\n  {\"Mul\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Div = { type = "function", description = "Return equivalent lua table for add.\n  {\"Div\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Min = { type = "function", description = "Return equivalent lua table for add.\n  {\"Min\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Max = { type = "function", description = "Return equivalent lua table for add.\n  {\"Max\", {arg1, arg2, argn}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Rand = { type = "function", description = "Return equivalent lua table for add.\n  {\"Rand\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  GreaterThan = { type = "function", description = "Return equivalent lua table for GreaterThan.\n  {\"GreaterThan\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  LessThan = { type = "function", description = "Return equivalent lua table for LessThan.\n  {\"LessThan\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Equal = { type = "function", description = "Return equivalent lua table for Equal.\n  {\"Equal\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  GreaterThanOrEq = { type = "function", description = "Return equivalent lua table for GreaterThanOrEq.\n  {\"GreaterThanOrEq\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  LessThanOrEq = { type = "function", description = "Return equivalent lua table for LessThanOrEq.\n  {\"LessThanOrEq\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  NotEqual = { type = "function", description = "Return equivalent lua table for NotEqual.\n  {\"NotEqual\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  VideoTextLength = { type = "function", description = "Return equivalent lua table for VideoTextLength.\n  {\"VideoTextLength\", {Text = arg1, Font = arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  StringFind = { type = "function", description = "Return equivalent lua table for StringFind.\n  {\"StringFind\", {arg1, arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  AttackerVar = { type = "function", description = "Return equivalent lua table for .\n  {\"Unit\", {Unit = \"Attacker\", Variable = arg1, Component = \"Value\" or arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  DefenderVar = { type = "function", description = "Return equivalent lua table for .\n  {\"Unit\", {Unit = \"Defender\", Variable = arg1, Component = \"Value\" or arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  ActiveUnitVar = { type = "function", description = "Return equivalent lua table for .\n  {\"Unit\", {Unit = \"Active\", Variable = arg1, Component = \"Value\" or arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  TypeVar = { type = "function", description = "Return equivalent lua table for .\n  {\"Type\", {Type = \"Active\", Variable = arg1, Component = \"Value\" or arg2}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Concat = { type = "function", description = "Return equivalent lua table for Concat.\n  {\"Concat\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  String = { type = "function", description = "Return equivalent lua table for String.\n  {\"String\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  InverseVideo = { type = "function", description = "Return equivalent lua table for InverseVideo.\n  {\"InverseVideo\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  UnitName = { type = "function", description = "Return equivalent lua table for UnitName.\n  {\"UnitName\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table.\n\n Example:\n\n u_data = UnitType(\"unit-footman\")" },
  SubString = { type = "function", description = "Return equivalent lua table for SubString.\n  {\"SubString\", {arg1, arg2, arg3}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  Line = { type = "function", description = "Return equivalent lua table for Line.\n  {\"Line\", {arg1, arg2[, arg3]}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  GameInfo = { type = "function", description = "Return equivalent lua table for Line.\n  {\"Line\", \"arg1\"}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  PlayerName = { type = "function", description = "Return equivalent lua table for PlayerName.\n  {\"PlayerName\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  PlayerData = { type = "function", description = "Return equivalent lua table for PlayerData.\n  {\"PlayerData\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  If = { type = "function", description = "Return equivalent lua table for If.\n  {\"If\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  NumIf = { type = "function", description = "Return equivalent lua table for NumIf.\n  {\"NumIf\", {arg1}}\n\n  @param l  Lua state.\n\n  @return   equivalent lua table." },
  LibraryPath = { type = "function", description = "Return the stratagus library path.\n\n  @param l  Lua state.\n\n  @return   Current libray path." },
  ListDirectory = { type = "function", description = "Return a table with the files or directories found in the subdirectory." },
  ListFilesInDirectory = { type = "function", description = "Return a table with the files found in the subdirectory." },
  ListDirsInDirectory = { type = "function", description = "Return a table with the files found in the subdirectory." },
  ListFilesystem = { type = "function", description = "" },
  SetDamageFormula = { type = "function", description = "Set damage computation method.\n\n  @param l  Lua state." },
  SavePreferences = { type = "function", description = "Save preferences\n\n  @param l  Lua state." },
  Load = { type = "function", description = "Load a file and execute it.\n\n  @param l  Lua state.\n\n  @return   0 in success, else exit." },
  LoadBuffer = { type = "function", description = "Load a file into a buffer and return it.\n\n  @param l  Lua state.\n\n  @return   buffer or nil on failure" },
  DebugPrint = { type = "function", description = "Print debug message with info about current script name, line number and function.\n\n  @see DebugPrint\n\n  @param l  Lua state." },
  RestartStratagus = { type = "function", description = "Restart the entire game. This function only returns when an error happens." },
  AStar = { type = "function", description = "Enable a*.\n\n  @param l  Lua state." },
  SetGameName = { type = "function", description = "Description\n\n  Return of game name.\n\n  @param l  Lua state.\n\n Example:\n\n SetGameName(\"Wargus Map - Chapter 1\")" },
  SetFullGameName = { type = "function", description = "" },
  SetGodMode = { type = "function", description = "Description\n\n  Set God mode.\n\n  @param l  Lua state.\n\n  @return   The old mode.\n\n Example:\n\n -- God Mode enabled\n		SetGodMode(true)\n		-- God Mode disabled\n		SetGodMode(false)" },
  GetGodMode = { type = "function", description = "Description\n\n  Get God mode.\n\n  @param l  Lua state.\n\n  @return   God mode.\n\n Example:\n\n g_mode = GetGodMode()\n		print(g_mode)" },
  SetSpeedResourcesHarvest = { type = "function", description = "Set resource harvesting speed (deprecated).\n\n  @param l  Lua state." },
  SetSpeedResourcesReturn = { type = "function", description = "Set resource returning speed (deprecated).\n\n  @param l  Lua state." },
  SetSpeedBuild = { type = "function", description = "Set building speed (deprecated).\n\n  @param l  Lua state." },
  GetSpeedBuild = { type = "function", description = "Get building speed (deprecated).\n\n  @param l  Lua state.\n\n  @return   Building speed." },
  SetSpeedTrain = { type = "function", description = "Set training speed (deprecated).\n\n  @param l  Lua state." },
  GetSpeedTrain = { type = "function", description = "Get training speed (deprecated).\n\n  @param l  Lua state.\n\n  @return   Training speed." },
  SetSpeedUpgrade = { type = "function", description = "For debug increase upgrading speed (deprecated).\n\n  @param l  Lua state." },
  SetSpeedResearch = { type = "function", description = "For debug increase researching speed (deprecated).\n\n  @param l  Lua state." },
  SetSpeeds = { type = "function", description = "For debug increase all speeds (deprecated).\n\n  @param l  Lua state." },
  DefineDefaultIncomes = { type = "function", description = "Define default incomes for a new player.\n\n  @param l  Lua state." },
  DefineDefaultActions = { type = "function", description = "Define default action for the resources.\n\n  @param l  Lua state." },
  DefineDefaultResourceNames = { type = "function", description = "Define default names for the resources.\n\n  @param l  Lua state." },
  DefineDefaultResourceAmounts = { type = "function", description = "Define default names for the resources.\n\n  @param l  Lua state." },
  DefineDefaultResourceMaxAmounts = { type = "function", description = "Define max amounts for the resources.\n\n  @param l  Lua state." },
  SetUseHPForXp = { type = "function", description = "Affect UseHPForXp.\n\n  @param l  Lua state.\n\n  @return 0." },
  SetLocalPlayerName = { type = "function", description = "Description\n\n  Set the local player name\n\n  @param l  Lua state.\n\n Example:\n\n SetLocalPlayerName(\"Stormreaver Clan\")" },
  GetLocalPlayerName = { type = "function", description = "Description\n\n  Get the local player name\n\n  @param l  Lua state.\n\n Example:\n\n GetLocalPlayerName()" },
  SetMenuRace = { type = "function", description = "" },
  GetStratagusVersion = { type = "function", description = "Description\n\n  Get Stratagus Version\n\n Example:\n\n version = GetStratagusVersion()\n		print(version)" },
  GetStratagusHomepage = { type = "function", description = "Description\n\n  Get Stratagus Homepage\n\n Example:\n\n url = GetStratagusHomepage()\n	print(url)" },
  SavedGameInfo = { type = "function", description = "Load the SavedGameInfo Header\n\n  @param l  Lua state." },
  AddTrigger = { type = "function", description = "Description\n\n  Add a trigger.\n\n Example:\n\n AddTrigger(\n			function() return (GetPlayerData(1,\"UnitTypesCount\",\"unit-farm\") >= 4) end,\n			function() return ActionVictory() end\n		)" },
  SetActiveTriggers = { type = "function", description = "Set the active triggers" },
  GetNumUnitsAt = { type = "function", description = "Description\n\n  Return the number of units of a given unit-type and player at a location.\n\n Example:\n\n -- Get the number of knights from player 1 from position 0,0 to 20,15\n			num_units = GetNumUnitsAt(1,\"unit-knight\",{0,0},{20,15})\n			print(num_units)" },
  IfNearUnit = { type = "function", description = "Description\n\n  Player has the quantity of unit-type near to unit-type.\n\n Example:\n\n AddTrigger(\n    function() return IfNearUnit(0,\">\",1,\"unit-peasant\",\"unit-town-hall\") end,\n    function()\n        AddMessage(\"Player 0 has more than 1 peasant near the Town Hall\")\n        return false end\n	)" },
  IfRescuedNearUnit = { type = "function", description = "Description\n\n  Player has the quantity of rescued unit-type near to unit-type.\n\n Example:\n\n IfRescuedNearUnit(\"this\", \">=\", 1, \"unit-archer\", \"unit-circle-of-power\")" },
  Log = { type = "function", description = "Parse log" },
  ReplayLog = { type = "function", description = "Parse replay-log" },
  DefineAiHelper = { type = "function", description = "Define helper for AI.\n\n  @param l  Lua state.\n\n  @todo  FIXME: the first unit could be a list see ../doc/ccl/ai.html" },
  DefineAi = { type = "function", description = "Description\n\n  Define an AI engine.\n\n  @param l  Lua state.\n\n  @return   FIXME: docu\n\n Example:\n\n -- Those instructions will be executed forever\n		local simple_ai_loop = {\n			-- Sleep for 5 in game minutes\n			function() return AiSleep(9000) end,\n			-- Repeat the functions from start.\n			function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n		}\n\n		-- The initial instructions the A.I has to execute\n		local simple_ai = {\n			function() return AiSleep(1800) end, -- Sleep for 1 in game minute\n			function() return AiNeed(\"unit-town-hall\") end, -- One Town Hall is needed\n			function() return AiWait(\"unit-town-hall\") end, -- Wait until the Town Hall is completed\n			function() return AiSet(\"unit-peasant\", 4) end, -- Make 4 peasants\n			-- Basic buildings\n			function() return AiSet(\"unit-farm\", 4) end, -- Make 4 farms\n			function() return AiWait(\"unit-farm\") end, -- Wait until all 4 farms are build.\n			function() return AiNeed(\"unit-human-barracks\") end, -- Need a Barracks\n			function() return AiWait(\"unit-human-barracks\") end, -- Wait until the Barracks has been built\n			-- Defense force for the base\n			function() return AiForce(1, {\"unit-footman\", 3}) end, -- Make a force of 3 footmen\n			function() return AiWaitForce(1) end, -- Wait until the 3 footmen are trained\n			function() return AiForceRole(1,\"defend\") end, -- Make this force as a defense force\n			-- Execute the instructions in simple_ai_loop\n			function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n		}\n\n		-- function that calls the instructions in simple_ai inside DefineAi\n		function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n		-- Make an A.I for the human race that calls the function custom_ai\n		DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiGetRace = { type = "function", description = "Get the race of the current AI player.\n\n  @param l  Lua state." },
  AiGetSleepCycles = { type = "function", description = "Description\n\n  Get the number of cycles to sleep.\n\n  @param l  Lua state\n\n  @return   Number of return values\n\n Example:\n\n local simple_ai_loop = {\n			-- Sleep for 5 in game minutes\n			function() return AiSleep(9000) end,\n			-- Repeat the instructions forever.\n			function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n		}\n\n		local simple_ai = {\n			-- Get the number of cycles to sleep.\n			function() return AiSleep(AiGetSleepCycles()) end,\n			-- Execute the instructions in simple_ai_loop\n			function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n		}\n\n		function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n		DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiDebug = { type = "function", description = "Set debugging flag of AI script\n\n  @param l  Lua state\n\n  @return   Number of return values" },
  AiDebugPlayer = { type = "function", description = "Activate AI debugging for the given player(s)\n  Player can be a number for a specific player\n    \"self\" for current human player (ai me)\n    \"none\" to disable\n\n  @param l  Lua State\n\n  @return   Number of return values" },
  AiNeed = { type = "function", description = "Description\n\n  Need a unit.\n\n  @param l  Lua state.\n\n  @return   Number of return values\n\n Example:\n\n local simple_ai_loop = {\n			-- Sleep for 5 in game minutes\n			function() return AiSleep(9000) end,\n			-- Repeat the instructions forever.\n			function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n		}\n\n		local simple_ai = {\n			function() return AiSleep(AiGetSleepCycles()) end,\n			-- Tell to the A.I that it needs a Town Hall.\n			function() return AiNeed(\"unit-town-hall\") end,\n			-- Execute the instructions in simple_ai_loop\n			function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n		}\n\n		function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n		DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiSet = { type = "function", description = "Description\n\n  Set the number of units.\n\n  @param l  Lua state\n\n  @return   Number of return values\n\n Example:\n\n local simple_ai_loop = {\n		-- Sleep for 5 in game minutes\n		function() return AiSleep(9000) end,\n		-- Repeat the instructions forever.\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		-- Tell to the A.I that it needs a Town Hall.\n		function() return AiNeed(\"unit-town-hall\") end,\n		-- Wait until the town-hall has been built.\n		function() return AiWait(\"unit-town-hall\") end,\n		-- Tell to the A.I that it needs 4 peasants\n		function() return AiSet(\"unit-peasant\",4) end,\n		-- Execute the instructions in simple_ai_loop\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiWait = { type = "function", description = "Description\n\n  Wait for a unit.\n\n  @param l  Lua State.\n\n  @return   Number of return values\n\n Example:\n\n local simple_ai_loop = {\n		-- Sleep for 5 in game minutes\n		function() return AiSleep(9000) end,\n		-- Repeat the instructions forever.\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		-- Tell to the A.I that it needs a Town Hall.\n		function() return AiNeed(\"unit-town-hall\") end,\n		-- Wait until the Town Hall has been built.\n		function() return AiWait(\"unit-town-hall\") end,\n		-- Execute the instructions in simple_ai_loop\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiGetPendingBuilds = { type = "function", description = "Get number of active build requests for a unit type.\n\n  @param l  Lua State.\n\n  @return   Number of return values" },
  AiForce = { type = "function", description = "Description\n\n  Define a force, a groups of units.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		-- Sleep for 5 in game minutes\n		function() return AiSleep(9000) end,\n		-- Repeat the instructions forever.\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		-- Tell to the A.I that it needs a Town Hall.\n		function() return AiNeed(\"unit-town-hall\") end,\n		-- Wait until the Town Hall has been built.\n		function() return AiWait(\"unit-town-hall\") end,\n		-- Tell to the A.I that it needs 4 peasants\n		function() return AiSet(\"unit-peasant\",4) end,\n		-- Tell to the A.I that it needs a Barracks.\n		function() return AiNeed(\"unit-human-barracks\") end,\n		-- Tell to the A.I that it needs a Lumbermill.\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		-- Wait until the Barracks has been built.\n		function() return AiWait(\"unit-human-barracks\") end,\n		-- Wait until the Lumbermill has been built.\n		function() return AiWait(\"unit-elven-lumber-mill\") end,\n		-- Specify the force number 1 made only of 3 footmen\n		function() return AiForce(1,{\"unit-footman\", 3}) end,\n		-- Specify the force number 2 made only of 2 archers\n		function() return AiForce(2,{\"unit-archer\", 2}) end,\n		-- Specify the force number 3 made of 2 footmen and 1 archer\n		function() return AiForce(3,{\"unit-footman\", 2, \"unit-archer\", 1}) end,\n		-- Wait for all three forces\n		function() return AiWaitForce(1) end,\n		function() return AiWaitForce(2) end,\n		function() return AiWaitForce(3) end,\n		-- Execute the instructions in simple_ai_loop\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiReleaseForce = { type = "function", description = "Release force.\n\n  @param l  Lua state." },
  AiForceRole = { type = "function", description = "Description\n\n  Define the role of a force.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		-- Force 1 has the role of attacker\n		function() return AiForceRole(1,\"attack\") end,\n		-- Force 2 has the role of defender\n		function() return AiForceRole(2,\"defend\") end,\n		function() return AiForce(1,{\"unit-footman\", 3}) end,\n		function() return AiForce(2,{\"unit-archer\", 2}) end,\n		function() return AiWaitForce(1) end,\n		function() return AiWaitForce(2) end,\n		-- Execute the instructions in simple_ai_loop\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiCheckForce = { type = "function", description = "Check if a force ready.\n\n  @param l  Lua state." },
  AiWaitForce = { type = "function", description = "Description\n\n  Wait for a force ready.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiForce(1,{\"unit-footman\", 3}) end,\n		-- Wait until force 1 is completed\n		function() return AiWaitForce(1) end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiAttackWithForce = { type = "function", description = "Description\n\n  Attack with one single force.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiForce(1,{\"unit-footman\", 3}) end,\n		function() return AiWaitForce(1) end,\n		-- Attack with Force 1\n		function() return AiAttackWithForce(1) end,\n\n		function() return AiForce(2,{\"unit-footman\",5}) end,\n		function() return AiWaitForce(2) end,\n		-- Attack with Force 2\n		function() return AiAttackWithForce(2) end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiSleep = { type = "function", description = "Description\n\n  Sleep for n cycles.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n			-- Sleep for 5 in game minutes\n			function() return AiSleep(9000) end,\n			function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n		}\n\n		local simple_ai = {\n			-- Get the number of cycles to sleep\n			function() return AiSleep(AiGetSleepCycles()) end,\n			function() return AiNeed(\"unit-town-hall\") end,\n			function() return AiWait(\"unit-town-hall\") end,\n			function() return AiSet(\"unit-peasant\",4) end,\n			-- Sleep for 1 in game minute\n			function() return AiSleep(1800) end,\n			function() return AiNeed(\"unit-human-blacksmith\") end,\n			function() return AiWait(\"unit-human-blacksmith\") end,\n			function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n		}\n\n		function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n		DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiResearch = { type = "function", description = "Description\n\n  Research an upgrade.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		-- Get the number of cycles to sleep\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		function() return AiWait(\"unit-elven-lumber-mill\") end,\n		function() return AiForce(1,{\"unit-footman\", 1, \"unit-archer\", 2}) end,\n		function() return AiWaitForce(1) end,\n		-- Upgrade the archers arrow.\n		function() return AiResearch(\"upgrade-arrow1\") end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiUpgradeTo = { type = "function", description = "Description\n\n  Upgrade an unit to an new unit-type.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		function() return AiWait(\"unit-elven-lumber-mill\") end,\n		function() return AiSleep(1800) end,\n		-- Upgrade the Town Hall to Keep\n		function() return AiUpgradeTo(\"unit-keep\") end,\n		function() return AiWait(\"unit-keep\") end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiPlayer = { type = "function", description = "Return the player of the running AI.\n\n  @param l  Lua state.\n\n  @return  Player number of the AI." },
  AiSetReserve = { type = "function", description = "Set AI player resource reserve.\n\n  @param l  Lua state.\n\n  @return     Old resource vector" },
  AiSetCollect = { type = "function", description = "Description\n\n  Set AI player resource collect percent.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		-- The peasants will focus only on gathering gold\n		function() return AiSetCollect({0,100,0,0,0,0,0}) end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiWait(\"unit-peasant\") end,\n		function() return AiSleep(1800) end,\n		-- The peasants will now focus 50% on gathering gold and 50% on gathering lumber\n		function() return AiSetCollect({0,50,50,0,0,0,0}) end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiSetBuildDepots = { type = "function", description = "Set AI player build.\n\n  @param l  Lua state." },
  AiDump = { type = "function", description = "Description\n\n  Dump some AI debug information.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(3600) end,\n		-- Get the information from all the A.I players\n		function() return AiDump() end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiWait(\"unit-peasant\") end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  DefineAiPlayer = { type = "function", description = "Define an AI player.\n\n  @param l  Lua state." },
  AiAttackWithForces = { type = "function", description = "Description\n\n  Attack with forces.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		function() return AiWait(\"unit-elven-lumber-mill\") end,\n		function() return AiForce(1,{\"unit-footman\", 2}) end,\n		function() return AiForce(2,{\"unit-archer\",1}) end,\n		function() return AiForce(3,{\"unit-archer\",1,\"unit-footman\",3}) end,\n		-- Wait all three forces to be ready\n		function() return AiWaitForces({1,2,3}) end,\n		-- Attack with all three forces\n		function() return AiAttackWithForces({1,2,3}) end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiWaitForces = { type = "function", description = "Description\n\n  Wait for a forces ready.\n\n  @param l  Lua state.\n\n Example:\n\n local simple_ai_loop = {\n		function() return AiSleep(9000) end,\n		function() stratagus.gameData.AIState.loop_index[1 + AiPlayer()] = 0; return false; end,\n	}\n\n	local simple_ai = {\n		function() return AiSleep(AiGetSleepCycles()) end,\n		function() return AiNeed(\"unit-town-hall\") end,\n		function() return AiWait(\"unit-town-hall\") end,\n		function() return AiSet(\"unit-peasant\",4) end,\n		function() return AiNeed(\"unit-human-barracks\") end,\n		function() return AiWait(\"unit-human-barracks\") end,\n		function() return AiNeed(\"unit-elven-lumber-mill\") end,\n		function() return AiWait(\"unit-elven-lumber-mill\") end,\n		function() return AiForce(1,{\"unit-footman\", 2}) end,\n		function() return AiForce(2,{\"unit-archer\",1}) end,\n		function() return AiForce(3,{\"unit-archer\",1,\"unit-footman\",3}) end,\n		-- Wait all three forces to be ready\n		function() return AiWaitForces({1,2,3}) end,\n		function() return AiLoop(simple_ai_loop, stratagus.gameData.AIState.loop_index) end,\n	}\n\n	function custom_ai() return AiLoop(simple_ai,stratagus.gameData.AIState.index) end\n	DefineAi(\"example_ai\",\"human\",\"class_ai\",custom_ai)" },
  AiProcessorSetup = { type = "function", description = "AiProcessorSetup(host, port, number_of_state_variables, number_of_actions)\n\n Connect to an AI agent running at host:port, that will consume\n number_of_state_variables every step and select one of number_of_actions." },
  AiProcessorStep = { type = "function", description = "AiProcessorStep(handle, reward_since_last_call, table_of_state_variables)" },
  AiProcessorEnd = { type = "function", description = "" },
  SetEditorSelectIcon = { type = "function", description = "Set the editor's select icon\n\n  @param l  Lua state." },
  SetEditorUnitsIcon = { type = "function", description = "Set the editor's units icon\n\n  @param l  Lua state." },
  SetEditorStartUnit = { type = "function", description = "Set the editor's start location unit\n\n  @param l  Lua state." },
  EditorResizeMap = { type = "function", description = "" },
  SetEditorRandomizeProperties = { type = "function", description = "Confgure the randomize map feature of the editor.\n\n  @param l  Lua state." },
  NoRandomPlacementMultiplayer = { type = "function", description = "Controls Randomization of Player position in Multiplayer mode.\n  Without arguments, disables randomization. Otherwise, sets the\n  NoRandomization flag to the boolean argument value.\n\n  @param l  Lua state." },
  UsesRandomPlacementMultiplayer = { type = "function", description = "Return if player positions in multiplayer mode are randomized.\n\n  @param l  Lua state." },
  NetworkDiscoverServers = { type = "function", description = "" },
  IsReplayGame = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  StartMap = { type = "function", description = "", args = "(str: string, clean: boolean = true)" },
  StartReplay = { type = "function", description = "", args = "(str: string, reveal: boolean = false)" },
  StartSavedGame = { type = "function", description = "", args = "(str: string)" },
  SaveReplay = { type = "function", description = "", args = "(filename: string)", valuetype = "number", returns = "(number)" },
  GameNoResult = { type = "value", valuetype = "number" },
  GameVictory = { type = "value", valuetype = "number" },
  GameDefeat = { type = "value", valuetype = "number" },
  GameDraw = { type = "value", valuetype = "number" },
  GameQuitToMenu = { type = "value", valuetype = "number" },
  GameRestart = { type = "value", valuetype = "number" },
  GameResult = { type = "value", valuetype = "GameResults" },
  StopGame = { type = "function", description = "", args = "(result: GameResults)" },
  GameRunning = { type = "value", valuetype = "boolean" },
  SetGamePaused = { type = "function", description = "", args = "(paused: boolean)" },
  GetGamePaused = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetGameSpeed = { type = "function", description = "", args = "(speed: number)" },
  GetGameSpeed = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  GameObserve = { type = "value", valuetype = "boolean" },
  GameEstablishing = { type = "value", valuetype = "boolean" },
  GameCycle = { type = "value", valuetype = "number" },
  FastForwardCycle = { type = "value", valuetype = "number" },
  cNoRevelation = { type = "value", valuetype = "number" },
  cAllUnits = { type = "value", valuetype = "number" },
  cBuildingsOnly = { type = "value", valuetype = "number" },
  SettingsSinglePlayerGame = { type = "value", valuetype = "number" },
  SettingsMultiPlayerGame = { type = "value", valuetype = "number" },
  Unset = { type = "value", valuetype = "number" },
  Settings = { type = "class", description = "",  childs = {
    NetGameType = { type = "value", valuetype = "NetGameTypes" },
    Presets = { type = "value", valuetype = "SettingsPresets" },
    Resources = { type = "value", valuetype = "number" },
    NumUnits = { type = "value", valuetype = "number" },
    Opponents = { type = "value", valuetype = "number" },
    Difficulty = { type = "value", valuetype = "number" },
    GameType = { type = "value", valuetype = "GameTypes" },
    FoV = { type = "value", valuetype = "FieldOfViewTypes" },
    RevealMap = { type = "value", valuetype = "MapRevealModes" },
    DefeatReveal = { type = "value", valuetype = "RevealTypes" },
    NoFogOfWar = { type = "value", valuetype = "boolean" },
    Inside = { type = "value", valuetype = "boolean" },
    AiExplores = { type = "value", valuetype = "boolean" },
    SimplifiedAutoTargeting = { type = "value", valuetype = "boolean" },
    GetUserGameSetting = { type = "function", description = "", args = "(i: number)", valuetype = "boolean", returns = "(boolean)" },
    SetUserGameSetting = { type = "function", description = "", args = "(i: number, v: boolean)" },
  }},
  GameSettings = { type = "value", valuetype = "Settings" },
  cHidden = { type = "value", valuetype = "number" },
  cKnown = { type = "value", valuetype = "number" },
  cExplored = { type = "value", valuetype = "number" },
  cNumOfModes = { type = "value", valuetype = "number" },
  cShadowCasting = { type = "value", valuetype = "number" },
  cSimpleRadial = { type = "value", valuetype = "number" },
  NumOfTypes = { type = "value", valuetype = "number" },
  SettingsGameTypeMapDefault = { type = "value", valuetype = "number" },
  SettingsGameTypeMelee = { type = "value", valuetype = "number" },
  SettingsGameTypeFreeForAll = { type = "value", valuetype = "number" },
  SettingsGameTypeTopVsBottom = { type = "value", valuetype = "number" },
  SettingsGameTypeLeftVsRight = { type = "value", valuetype = "number" },
  SettingsGameTypeManVsMachine = { type = "value", valuetype = "number" },
  SettingsGameTypeManTeamVsMachine = { type = "value", valuetype = "number" },
  SettingsGameTypeMachineVsMachine = { type = "value", valuetype = "number" },
  SettingsGameTypeMachineVsMachineTraining = { type = "value", valuetype = "number" },
  AStarKnowUnseenTerrain = { type = "value", valuetype = "boolean" },
  AiAttackWithForceAt = { type = "function", description = "/// Attack with force at position", args = "(force: number, x: number, y: number)" },
  AiAttackWithForce = { type = "function", description = "/// Attack with force", args = "(force: number)" },
  SaveGame = { type = "function", description = "", args = "(filename: string)", valuetype = "number", returns = "(number)" },
  DeleteSaveGame = { type = "function", description = "", args = "(filename: string)" },
  SyncRand = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  SyncRand = { type = "function", description = "", args = "(max: number)", valuetype = "number", returns = "(number)" },
  CanAccessFile = { type = "function", description = "", args = "(filename: string)", valuetype = "boolean", returns = "(boolean)" },
  Exit = { type = "function", description = "", args = "(err: number)" },
  IsDebugEnabled = { type = "value", valuetype = "boolean" },
  InitVideo = { type = "function", description = "", args = "()" },
  PlayMovie = { type = "function", description = "", args = "(name: string)", valuetype = "number", returns = "(number)" },
  ShowFullImage = { type = "function", description = "", args = "(name: string, timeOutInSecond: number)" },
  SaveMapPNG = { type = "function", description = "", args = "(name: string)" },
  CVideo = { type = "class", description = "",  childs = {
    Width = { type = "value", valuetype = "number" },
    Height = { type = "value", valuetype = "number" },
    Depth = { type = "value", valuetype = "number" },
    FullScreen = { type = "value", valuetype = "boolean" },
    ResizeScreen = { type = "function", description = "", args = "(width: number, height: number)", valuetype = "boolean", returns = "(boolean)" },
  }},
  Video = { type = "value", valuetype = "CVideo" },
  ToggleFullScreen = { type = "function", description = "", args = "()" },
  CGraphic = { type = "class", description = "",  childs = {
    New = { type = "function", description = "", args = "(file: string, w: number = 0, h: number = 0)", valuetype = "CGraphic", returns = "(CGraphic)" },
    ForceNew = { type = "function", description = "", args = "(file: string, w: number = 0, h: number = 0)", valuetype = "CGraphic", returns = "(CGraphic)" },
    Get = { type = "function", description = "", args = "(file: string)", valuetype = "CGraphic", returns = "(CGraphic)" },
    Free = { type = "function", description = "", args = "(CGraphic )" },
    Load = { type = "function", description = "", args = "(grayscale: boolean = false)" },
    Resize = { type = "function", description = "", args = "(w: number, h: number)" },
    SetPaletteColor = { type = "function", description = "", args = "(idx: number, r: number, g: number, b: number)" },
    OverlayGraphic = { type = "function", description = "", args = "(g: CGraphic, mask: boolean = false)" },
  }},
  CPlayerColorGraphic = { type = "class", description = "", inherits = "CGraphic",  childs = {
    New = { type = "function", description = "", args = "(file: string, w: number = 0, h: number = 0)", valuetype = "CPlayerColorGraphic", returns = "(CPlayerColorGraphic)" },
    ForceNew = { type = "function", description = "", args = "(file: string, w: number = 0, h: number = 0)", valuetype = "CPlayerColorGraphic", returns = "(CPlayerColorGraphic)" },
    Get = { type = "function", description = "", args = "(file: string)", valuetype = "CPlayerColorGraphic", returns = "(CPlayerColorGraphic)" },
  }},
  CColor = { type = "class", description = "",  childs = {
    R = { type = "value", valuetype = "number" },
    G = { type = "value", valuetype = "number" },
    B = { type = "value", valuetype = "number" },
    A = { type = "value", valuetype = "number" },
  }},
  SetColorCycleAll = { type = "function", description = "", args = "(value: boolean)" },
  ClearAllColorCyclingRange = { type = "function", description = "", args = "()" },
  AddColorCyclingRange = { type = "function", description = "", args = "(startColorIndex: number, endColorIndex: number)" },
  SetColorCycleSpeed = { type = "function", description = "", args = "(speed: number)", valuetype = "number", returns = "(number)" },
  CUnitType = { type = "class", description = "",  childs = {
    MinAttackRange = { type = "value", valuetype = "number" },
    ClicksToExplode = { type = "value", valuetype = "number" },
    GivesResource = { type = "value", valuetype = "number" },
    TileWidth = { type = "value", valuetype = "number" },
    TileHeight = { type = "value", valuetype = "number" },
  }},
  UnitTypeByIdent = { type = "function", description = "", args = "(ident: string)", valuetype = "CUnitType", returns = "(CUnitType)" },
  UnitTypeHumanWall = { type = "value", valuetype = "CUnitType" },
  UnitTypeOrcWall = { type = "value", valuetype = "CUnitType" },
  SetMapStat = { type = "function", description = "", args = "(ident: string, variable_key: string, value: number, variable_type: string)" },
  SetMapSound = { type = "function", description = "", args = "(ident: string, sound: string, sound_type: string, sound_subtype: string = \"\")" },
  CFont = { type = "class", description = "",  childs = {
    New = { type = "function", description = "", args = "(ident: string, g: CGraphic)", valuetype = "CFont", returns = "(CFont)" },
    Get = { type = "function", description = "", args = "(ident: string)", valuetype = "CFont", returns = "(CFont)" },
    Height = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    Width = { type = "function", description = "", args = "(text: string)", valuetype = "number", returns = "(number)" },
  }},
  CFontColor = { type = "class", description = "",  childs = {
    New = { type = "function", description = "", args = "(ident: string)", valuetype = "CFontColor", returns = "(CFontColor)" },
    Get = { type = "function", description = "", args = "(ident: string)", valuetype = "CFontColor", returns = "(CFontColor)" },
    Colors = { type = "value", valuetype = "SDL_Color" },
  }},
  GetNumOpponents = { type = "function", description = "", args = "(player: number)", valuetype = "number", returns = "(number)" },
  GetTimer = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  ActionVictory = { type = "function", description = "", args = "()" },
  ActionDefeat = { type = "function", description = "", args = "()" },
  ActionDraw = { type = "function", description = "", args = "()" },
  ActionSetTimer = { type = "function", description = "", args = "(cycles: number, increasing: boolean)" },
  ActionStartTimer = { type = "function", description = "", args = "()" },
  ActionStopTimer = { type = "function", description = "", args = "()" },
  SetTrigger = { type = "function", description = "", args = "(trigger: number)" },
  EditorNotRunning = { type = "value", valuetype = "number" },
  EditorStarted = { type = "value", valuetype = "number" },
  EditorCommandLine = { type = "value", valuetype = "number" },
  EditorEditing = { type = "value", valuetype = "number" },
  CEditor = { type = "class", description = "",  childs = {
    UnitTypes = { type = "value", valuetype = "vector" },
    TerrainEditable = { type = "value", valuetype = "boolean" },
    StartUnit = { type = "value", valuetype = "CUnitType" },
    WriteCompressedMaps = { type = "value", valuetype = "boolean" },
    Running = { type = "value", valuetype = "EditorRunningType" },
    CreateRandomMap = { type = "function", description = "", args = "(shuffleTranslitions: boolean)" },
  }},
  Editor = { type = "value", valuetype = "CEditor" },
  StartEditor = { type = "function", description = "", args = "(filename: string)" },
  EditorSaveMap = { type = "function", description = "", args = "(file: string)", valuetype = "number", returns = "(number)" },
  CMapInfo = { type = "class", description = "",  childs = {
    Description = { type = "value", valuetype = "string" },
    Filename = { type = "value", valuetype = "string" },
    Preamble = { type = "value", valuetype = "string" },
    Postamble = { type = "value", valuetype = "string" },
    MapWidth = { type = "value", valuetype = "number" },
    MapHeight = { type = "value", valuetype = "number" },
    PlayerType = { type = "value", valuetype = "PlayerTypes" },
  }},
  CTileset = { type = "class", description = "",  childs = {
    Name = { type = "value", valuetype = "string" },
  }},
  CMap = { type = "class", description = "",  childs = {
    Info = { type = "value", valuetype = "CMapInfo" },
    Tileset = { type = "value", valuetype = "CTileset" },
  }},
  Map = { type = "value", valuetype = "CMap" },
  SetTile = { type = "function", description = "", args = "(tile: number, w: number, h: number, value: number = 0)" },
  CMinimap = { type = "class", description = "",  childs = {
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    W = { type = "value", valuetype = "number" },
    H = { type = "value", valuetype = "number" },
    WithTerrain = { type = "value", valuetype = "boolean" },
    ShowSelected = { type = "value", valuetype = "boolean" },
    Transparent = { type = "value", valuetype = "boolean" },
  }},
  InitNetwork1 = { type = "function", description = "", args = "()" },
  ExitNetwork1 = { type = "function", description = "", args = "()" },
  IsNetworkGame = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  NetworkSetupServerAddress = { type = "function", description = "", args = "(serveraddr: string, port: number = 0)", valuetype = "number", returns = "(number)" },
  NetworkInitClientConnect = { type = "function", description = "", args = "()" },
  NetworkInitServerConnect = { type = "function", description = "", args = "(openslots: number)" },
  NetworkServerStartGame = { type = "function", description = "", args = "()" },
  NetworkProcessClientRequest = { type = "function", description = "", args = "()" },
  GetNetworkState = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  NetworkServerResyncClients = { type = "function", description = "", args = "()" },
  NetworkDetachFromServer = { type = "function", description = "", args = "()" },
  ServerSetupStateRacesArray = { type = "class", description = "",  childs = {
  }},
  SlotAvailable = { type = "value", valuetype = "number" },
  SlotComputer = { type = "value", valuetype = "number" },
  SlotClosed = { type = "value", valuetype = "number" },
  CServerSetup = { type = "class", description = "",  childs = {
    ServerGameSettings = { type = "value", valuetype = "Settings" },
    CompOpt = { type = "value", valuetype = "SlotOption" },
    Ready = { type = "value", valuetype = "number" },
    ResourcesOption = { type = "value", valuetype = "number" },
    UnitsOption = { type = "value", valuetype = "number" },
    FogOfWar = { type = "value", valuetype = "number" },
    Inside = { type = "value", valuetype = "number" },
    RevealMap = { type = "value", valuetype = "number" },
    GameTypeOption = { type = "value", valuetype = "number" },
    Difficulty = { type = "value", valuetype = "number" },
    Opponents = { type = "value", valuetype = "number" },
  }},
  LocalSetupState = { type = "value", valuetype = "CServerSetup" },
  ServerSetupState = { type = "value", valuetype = "CServerSetup" },
  NetLocalHostsSlot = { type = "value", valuetype = "number" },
  Hosts = { type = "value", valuetype = "CNetworkHost" },
  NetworkMapName = { type = "value", valuetype = "string" },
  NetworkMapFragmentName = { type = "value", valuetype = "string" },
  NetworkGamePrepareGameSettings = { type = "function", description = "", args = "()" },
  Translate = { type = "function", description = "", args = "(str: string)", valuetype = "number", returns = "(number)" },
  AddTranslation = { type = "function", description = "", args = "(str1: string, str2: string)" },
  LoadPO = { type = "function", description = "", args = "(file: string)" },
  SetTranslationsFiles = { type = "function", description = "", args = "(stratagusfile: string, gamefile: string)" },
  GraphicAnimation = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "(g: CGraphic, ticksPerFrame: number);", valuetype = "GraphicAnimation", returns = "(GraphicAnimation)" },
    local_new = { type = "function", description = "", args = "(g: CGraphic, ticksPerFrame: number);", valuetype = "GraphicAnimation", returns = "(GraphicAnimation)" },
    clone = { type = "function", description = "", args = "()", valuetype = "GraphicAnimation", returns = "(GraphicAnimation)" },
  }},
  CParticle = { type = "class", description = "",  childs = {
    clone = { type = "function", description = "", args = "()", valuetype = "CParticle", returns = "(CParticle)" },
    setDrawLevel = { type = "function", description = "", args = "(value: number)" },
  }},
  StaticParticle = { type = "class", description = "", inherits = "CParticle",  childs = {
    new = { type = "function", description = "", args = "(position: CPosition, animation: GraphicAnimation, drawlevel: number = 0);", valuetype = "StaticParticle", returns = "(StaticParticle)" },
    local_new = { type = "function", description = "", args = "(position: CPosition, animation: GraphicAnimation, drawlevel: number = 0);", valuetype = "StaticParticle", returns = "(StaticParticle)" },
  }},
  CChunkParticle = { type = "class", description = "", inherits = "CParticle",  childs = {
    new = { type = "function", description = "", args = "(position: CPosition, smokeAnimation: GraphicAnimation, debrisAnimation: GraphicAnimation, destroyAnimation: GraphicAnimation, minVelocity: number = 0, maxVelocity: number = 400, minTrajectoryAngle: number = 77, maxTTL: number = 0, drawlevel: number = 0);", valuetype = "CChunkParticle", returns = "(CChunkParticle)" },
    local_new = { type = "function", description = "", args = "(position: CPosition, smokeAnimation: GraphicAnimation, debrisAnimation: GraphicAnimation, destroyAnimation: GraphicAnimation, minVelocity: number = 0, maxVelocity: number = 400, minTrajectoryAngle: number = 77, maxTTL: number = 0, drawlevel: number = 0);", valuetype = "CChunkParticle", returns = "(CChunkParticle)" },
    getSmokeDrawLevel = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    getDestroyDrawLevel = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setSmokeDrawLevel = { type = "function", description = "", args = "(value: number)" },
    setDestroyDrawLevel = { type = "function", description = "", args = "(value: number)" },
  }},
  CSmokeParticle = { type = "class", description = "", inherits = "CParticle",  childs = {
    new = { type = "function", description = "", args = "(position: CPosition, animation: GraphicAnimation, speedx: float = 0, speedy: float = -22.0, drawlevel: number = 0);", valuetype = "CSmokeParticle", returns = "(CSmokeParticle)" },
    local_new = { type = "function", description = "", args = "(position: CPosition, animation: GraphicAnimation, speedx: float = 0, speedy: float = -22.0, drawlevel: number = 0);", valuetype = "CSmokeParticle", returns = "(CSmokeParticle)" },
  }},
  CRadialParticle = { type = "class", description = "", inherits = "CParticle",  childs = {
    new = { type = "function", description = "", args = "(position: CPosition, smokeAnimation: GraphicAnimation, maxSpeed: number, drawlevel: number = 0);", valuetype = "CRadialParticle", returns = "(CRadialParticle)" },
    local_new = { type = "function", description = "", args = "(position: CPosition, smokeAnimation: GraphicAnimation, maxSpeed: number, drawlevel: number = 0);", valuetype = "CRadialParticle", returns = "(CRadialParticle)" },
  }},
  CParticleManager = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "CParticleManager", returns = "(CParticleManager)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "CParticleManager", returns = "(CParticleManager)" },
    add = { type = "function", description = "", args = "(particle: CParticle)" },
  }},
  ParticleManager = { type = "value", valuetype = "CParticleManager" },
  PlayerNeutral = { type = "value", valuetype = "number" },
  PlayerNobody = { type = "value", valuetype = "number" },
  PlayerComputer = { type = "value", valuetype = "number" },
  PlayerPerson = { type = "value", valuetype = "number" },
  PlayerRescuePassive = { type = "value", valuetype = "number" },
  PlayerRescueActive = { type = "value", valuetype = "number" },
  CPlayer = { type = "class", description = "",  childs = {
    Index = { type = "value", valuetype = "number" },
    Name = { type = "value", valuetype = "string" },
    Type = { type = "value", valuetype = "PlayerTypes" },
    Race = { type = "value", valuetype = "number" },
    AiName = { type = "value", valuetype = "string" },
    StartPos = { type = "value", valuetype = "Vec2i" },
    SetStartView = { type = "function", description = "", args = "(pos: Vec2i)" },
    Resources = { type = "value", valuetype = "number" },
    StoredResources = { type = "value", valuetype = "number" },
    Incomes = { type = "value", valuetype = "number" },
    Revenue = { type = "value", valuetype = "number" },
    UnitTypesCount = { type = "value", valuetype = "number" },
    UnitTypesAiActiveCount = { type = "value", valuetype = "number" },
    AiEnabled = { type = "value", valuetype = "boolean" },
    NumBuildings = { type = "value", valuetype = "number" },
    Supply = { type = "value", valuetype = "number" },
    Demand = { type = "value", valuetype = "number" },
    UnitLimit = { type = "value", valuetype = "number" },
    BuildingLimit = { type = "value", valuetype = "number" },
    TotalUnitLimit = { type = "value", valuetype = "number" },
    Score = { type = "value", valuetype = "number" },
    TotalUnits = { type = "value", valuetype = "number" },
    TotalBuildings = { type = "value", valuetype = "number" },
    TotalResources = { type = "value", valuetype = "number" },
    TotalRazings = { type = "value", valuetype = "number" },
    TotalKills = { type = "value", valuetype = "number" },
    SpeedResourcesHarvest = { type = "value", valuetype = "number" },
    SpeedResourcesReturn = { type = "value", valuetype = "number" },
    SpeedBuild = { type = "value", valuetype = "number" },
    SpeedTrain = { type = "value", valuetype = "number" },
    SpeedUpgrade = { type = "value", valuetype = "number" },
    SpeedResearch = { type = "value", valuetype = "number" },
    GetUnitCount = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    IsEnemy = { type = "function", description = "", args = "(player: CPlayer)", valuetype = "boolean", returns = "(boolean)" },
    IsEnemy = { type = "function", description = "", args = "(unit: CUnit)", valuetype = "boolean", returns = "(boolean)" },
    IsAllied = { type = "function", description = "", args = "(player: CPlayer)", valuetype = "boolean", returns = "(boolean)" },
    IsAllied = { type = "function", description = "", args = "(unit: CUnit)", valuetype = "boolean", returns = "(boolean)" },
    HasSharedVisionWith = { type = "function", description = "", args = "(player: CPlayer)", valuetype = "boolean", returns = "(boolean)" },
    IsTeamed = { type = "function", description = "", args = "(player: CPlayer)", valuetype = "boolean", returns = "(boolean)" },
    IsTeamed = { type = "function", description = "", args = "(unit: CUnit)", valuetype = "boolean", returns = "(boolean)" },
  }},
  Players = { type = "value", valuetype = "CPlayer" },
  ThisPlayer = { type = "value", valuetype = "CPlayer" },
  CUpgrade = { type = "class", description = "",  childs = {
    New = { type = "function", description = "", args = "(ident: string)", valuetype = "CUpgrade", returns = "(CUpgrade)" },
    Get = { type = "function", description = "", args = "(ident: string)", valuetype = "CUpgrade", returns = "(CUpgrade)" },
    Costs = { type = "value", valuetype = "number" },
    Icon = { type = "value", valuetype = "CIcon" },
  }},
  Vec2i = { type = "class", description = "",  childs = {
  }},
  CUnit = { type = "class", description = "",  childs = {
    Goal = { type = "value", valuetype = "CUnit" },
    Active = { type = "value", valuetype = "boolean" },
    ResourcesHeld = { type = "value", valuetype = "number" },
  }},
  CPreference = { type = "class", description = "",  childs = {
    ShowSightRange = { type = "value", valuetype = "boolean" },
    ShowReactionRange = { type = "value", valuetype = "boolean" },
    ShowAttackRange = { type = "value", valuetype = "boolean" },
    ShowMessages = { type = "value", valuetype = "boolean" },
    ShowNoSelectionStats = { type = "value", valuetype = "boolean" },
    BigScreen = { type = "value", valuetype = "boolean" },
    PauseOnLeave = { type = "value", valuetype = "boolean" },
    AiExplores = { type = "value", valuetype = "boolean" },
    GrayscaleIcons = { type = "value", valuetype = "boolean" },
    IconsShift = { type = "value", valuetype = "boolean" },
    StereoSound = { type = "value", valuetype = "boolean" },
    MineNotifications = { type = "value", valuetype = "boolean" },
    DeselectInMine = { type = "value", valuetype = "boolean" },
    NoStatusLineTooltips = { type = "value", valuetype = "boolean" },
    SimplifiedAutoTargeting = { type = "value", valuetype = "boolean" },
    AiChecksDependencies = { type = "value", valuetype = "boolean" },
    HardwareCursor = { type = "value", valuetype = "boolean" },
    SelectionRectangleIndicatesDamage = { type = "value", valuetype = "boolean" },
    FrameSkip = { type = "value", valuetype = "number" },
    ShowOrders = { type = "value", valuetype = "number" },
    ShowNameDelay = { type = "value", valuetype = "number" },
    ShowNameTime = { type = "value", valuetype = "number" },
    AutosaveMinutes = { type = "value", valuetype = "number" },
    IconFrameG = { type = "value", valuetype = "CGraphic" },
    PressedIconFrameG = { type = "value", valuetype = "CGraphic" },
  }},
  CUnitManager = { type = "class", description = "",  childs = {
  }},
  Preference = { type = "value", valuetype = "CPreference" },
  GetUnitUnderCursor = { type = "function", description = "", args = "()", valuetype = "CUnit", returns = "(CUnit)" },
  UnitNumber = { type = "function", description = "", args = "(unit: CUnit)", valuetype = "number", returns = "(number)" },
  GetEffectsVolume = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  SetEffectsVolume = { type = "function", description = "", args = "(volume: number)" },
  GetMusicVolume = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  SetMusicVolume = { type = "function", description = "", args = "(volume: number)" },
  SetEffectsEnabled = { type = "function", description = "", args = "(enabled: boolean)" },
  IsEffectsEnabled = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetMusicEnabled = { type = "function", description = "", args = "(enabled: boolean)" },
  IsMusicEnabled = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  PlayFile = { type = "function", description = "", args = "(name: string, listener: LuaActionListener = NULL)", valuetype = "number", returns = "(number)" },
  PlayMusic = { type = "function", description = "", args = "(name: string)", valuetype = "number", returns = "(number)" },
  StopMusic = { type = "function", description = "", args = "()" },
  IsMusicPlaying = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetChannelVolume = { type = "function", description = "", args = "(channel: number, volume: number)", valuetype = "number", returns = "(number)" },
  SetChannelStereo = { type = "function", description = "", args = "(channel: number, stereo: number)" },
  StopChannel = { type = "function", description = "", args = "(channel: number)" },
  StopAllChannels = { type = "function", description = "", args = "()" },
  VIEWPORT_SINGLE = { type = "value", valuetype = "number" },
  VIEWPORT_SPLIT_HORIZ = { type = "value", valuetype = "number" },
  VIEWPORT_SPLIT_HORIZ3 = { type = "value", valuetype = "number" },
  VIEWPORT_SPLIT_VERT = { type = "value", valuetype = "number" },
  VIEWPORT_QUAD = { type = "value", valuetype = "number" },
  LuaActionListener = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "(lua: lua_State, luaref: lua_Object);", valuetype = "LuaActionListener", returns = "(LuaActionListener)" },
    local_new = { type = "function", description = "", args = "(lua: lua_State, luaref: lua_Object);", valuetype = "LuaActionListener", returns = "(LuaActionListener)" },
  }},
  CUIButton = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "CUIButton", returns = "(CUIButton)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "CUIButton", returns = "(CUIButton)" },
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    Text = { type = "value", valuetype = "string" },
    Style = { type = "value", valuetype = "ButtonStyle" },
    Callback = { type = "value", valuetype = "LuaActionListener" },
  }},
  CMapArea = { type = "class", description = "",  childs = {
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    EndX = { type = "value", valuetype = "number" },
    EndY = { type = "value", valuetype = "number" },
    ScrollPaddingLeft = { type = "value", valuetype = "number" },
    ScrollPaddingRight = { type = "value", valuetype = "number" },
    ScrollPaddingTop = { type = "value", valuetype = "number" },
    ScrollPaddingBottom = { type = "value", valuetype = "number" },
  }},
  CViewport = { type = "class", description = "",  childs = {
  }},
  CFiller = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "CFiller", returns = "(CFiller)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "CFiller", returns = "(CFiller)" },
    G = { type = "value", valuetype = "CGraphic" },
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
  }},
  vector = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "vector", returns = "(vector)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "vector", returns = "(vector)" },
    push_back = { type = "function", description = "", args = "(val: T)" },
    pop_back = { type = "function", description = "", args = "()" },
    assign = { type = "function", description = "", args = "(num: number, T& val)" },
    clear = { type = "function", description = "", args = "()" },
    empty = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    size = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  }},
  CButtonPanel = { type = "class", description = "",  childs = {
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    Buttons = { type = "value", valuetype = "vector" },
    AutoCastBorderColorRGB = { type = "value", valuetype = "CColor" },
    ShowCommandKey = { type = "value", valuetype = "boolean" },
  }},
  CPieMenu = { type = "class", description = "",  childs = {
    G = { type = "value", valuetype = "CGraphic" },
    MouseButton = { type = "value", valuetype = "number" },
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    SetRadius = { type = "function", description = "", args = "(radius: number)" },
  }},
  CResourceInfo = { type = "class", description = "",  childs = {
    G = { type = "value", valuetype = "CGraphic" },
    IconFrame = { type = "value", valuetype = "number" },
    IconX = { type = "value", valuetype = "number" },
    IconY = { type = "value", valuetype = "number" },
    IconWidth = { type = "value", valuetype = "number" },
    TextX = { type = "value", valuetype = "number" },
    TextY = { type = "value", valuetype = "number" },
  }},
  CInfoPanel = { type = "class", description = "",  childs = {
    G = { type = "value", valuetype = "CGraphic" },
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
  }},
  CUIUserButton = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "CUIUserButton", returns = "(CUIUserButton)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "CUIUserButton", returns = "(CUIUserButton)" },
    Clicked = { type = "value", valuetype = "boolean" },
    Button = { type = "value", valuetype = "CUIButton" },
  }},
  CStatusLine = { type = "class", description = "",  childs = {
    Set = { type = "function", description = "", args = "(status: string)" },
    Clear = { type = "function", description = "", args = "()" },
    Width = { type = "value", valuetype = "number" },
    TextX = { type = "value", valuetype = "number" },
    TextY = { type = "value", valuetype = "number" },
    Font = { type = "value", valuetype = "CFont" },
  }},
  CUITimer = { type = "class", description = "",  childs = {
    X = { type = "value", valuetype = "number" },
    Y = { type = "value", valuetype = "number" },
    Font = { type = "value", valuetype = "CFont" },
  }},
  CUserInterface = { type = "class", description = "",  childs = {
    NormalFontColor = { type = "value", valuetype = "string" },
    ReverseFontColor = { type = "value", valuetype = "string" },
    Fillers = { type = "value", valuetype = "vector" },
    Resources = { type = "value", valuetype = "CResourceInfo" },
    InfoPanel = { type = "value", valuetype = "CInfoPanel" },
    DefaultUnitPortrait = { type = "value", valuetype = "string" },
    SingleSelectedButton = { type = "value", valuetype = "CUIButton" },
    SelectedButtons = { type = "value", valuetype = "vector" },
    MaxSelectedFont = { type = "value", valuetype = "CFont" },
    MaxSelectedTextX = { type = "value", valuetype = "number" },
    MaxSelectedTextY = { type = "value", valuetype = "number" },
    SingleTrainingButton = { type = "value", valuetype = "CUIButton" },
    TrainingButtons = { type = "value", valuetype = "vector" },
    UpgradingButton = { type = "value", valuetype = "CUIButton" },
    ResearchingButton = { type = "value", valuetype = "CUIButton" },
    TransportingButtons = { type = "value", valuetype = "vector" },
    LifeBarColorNames = { type = "value", valuetype = "vector" },
    LifeBarPercents = { type = "value", valuetype = "vector" },
    LifeBarYOffset = { type = "value", valuetype = "number" },
    LifeBarPadding = { type = "value", valuetype = "number" },
    LifeBarBorder = { type = "value", valuetype = "boolean" },
    CompletedBarColorRGB = { type = "value", valuetype = "CColor" },
    CompletedBarShadow = { type = "value", valuetype = "boolean" },
    ButtonPanel = { type = "value", valuetype = "CButtonPanel" },
    PieMenu = { type = "value", valuetype = "CPieMenu" },
    MouseViewport = { type = "value", valuetype = "CViewport" },
    MapArea = { type = "value", valuetype = "CMapArea" },
    MessageFont = { type = "value", valuetype = "CFont" },
    MessageScrollSpeed = { type = "value", valuetype = "number" },
    MenuButton = { type = "value", valuetype = "CUIButton" },
    NetworkMenuButton = { type = "value", valuetype = "CUIButton" },
    NetworkDiplomacyButton = { type = "value", valuetype = "CUIButton" },
    UserButtons = { type = "value", valuetype = "vector" },
    Minimap = { type = "value", valuetype = "CMinimap" },
    StatusLine = { type = "value", valuetype = "CStatusLine" },
    Timer = { type = "value", valuetype = "CUITimer" },
    EditorSettingsAreaTopLeft = { type = "value", valuetype = "Vec2i" },
    EditorSettingsAreaBottomRight = { type = "value", valuetype = "Vec2i" },
    EditorButtonAreaTopLeft = { type = "value", valuetype = "Vec2i" },
    EditorButtonAreaBottomRight = { type = "value", valuetype = "Vec2i" },
    Load = { type = "function", description = "", args = "()" },
  }},
  UI = { type = "value", valuetype = "CUserInterface" },
  CIcon = { type = "class", description = "",  childs = {
    New = { type = "function", description = "", args = "(ident: string)", valuetype = "CIcon", returns = "(CIcon)" },
    Get = { type = "function", description = "", args = "(ident: string)", valuetype = "CIcon", returns = "(CIcon)" },
    G = { type = "value", valuetype = "CPlayerColorGraphic" },
    Frame = { type = "value", valuetype = "number" },
    ClearExtraGraphics = { type = "function", description = "", args = "()" },
    AddSingleSelectionGraphic = { type = "function", description = "", args = "(g: CPlayerColorGraphic)" },
    AddGroupSelectionGraphic = { type = "function", description = "", args = "(g: CPlayerColorGraphic)" },
    AddContainedGraphic = { type = "function", description = "", args = "(g: CPlayerColorGraphic)" },
  }},
  FindButtonStyle = { type = "function", description = "", args = "(style: string)", valuetype = "ButtonStyle", returns = "(ButtonStyle)" },
  GetMouseScroll = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetMouseScroll = { type = "function", description = "", args = "(enabled: boolean)" },
  GetKeyScroll = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetKeyScroll = { type = "function", description = "", args = "(enabled: boolean)" },
  GetGrabMouse = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetGrabMouse = { type = "function", description = "", args = "(enabled: boolean)" },
  GetLeaveStops = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  SetLeaveStops = { type = "function", description = "", args = "(enabled: boolean)" },
  GetDoubleClickDelay = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  SetDoubleClickDelay = { type = "function", description = "", args = "(delay: number)" },
  GetHoldClickDelay = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  SetHoldClickDelay = { type = "function", description = "", args = "(delay: number)" },
  SetScrollMargins = { type = "function", description = "", args = "(top: number, right: number, bottom: number, left: number)" },
  CursorScreenPos = { type = "value", valuetype = "PixelPos" },
  Color = { type = "class", description = "",  childs = {
    new = { type = "function", description = "", args = "(r: number, g: number, b: number, a: number = 255);", valuetype = "Color", returns = "(Color)" },
    local_new = { type = "function", description = "", args = "(r: number, g: number, b: number, a: number = 255);", valuetype = "Color", returns = "(Color)" },
    r = { type = "value", valuetype = "number" },
    g = { type = "value", valuetype = "number" },
    b = { type = "value", valuetype = "number" },
    a = { type = "value", valuetype = "number" },
  }},
  Graphics = { type = "class", description = "",  childs = {
  }},
  Widget = { type = "class", description = "",  childs = {
    setWidth = { type = "function", description = "", args = "(width: number)" },
    getWidth = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setHeight = { type = "function", description = "", args = "(height: number)" },
    getHeight = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setSize = { type = "function", description = "", args = "(width: number, height: number)" },
    setX = { type = "function", description = "", args = "(x: number)" },
    getX = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setY = { type = "function", description = "", args = "(y: number)" },
    getY = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setPosition = { type = "function", description = "", args = "(x: number, y: number)" },
    setBorderSize = { type = "function", description = "", args = "(width: number)" },
    getBorderSize = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setEnabled = { type = "function", description = "", args = "(enabled: boolean)" },
    isEnabled = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    setVisible = { type = "function", description = "", args = "(visible: boolean)" },
    isVisible = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    setDirty = { type = "function", description = "", args = "(isDirty: boolean)" },
    setBaseColor = { type = "function", description = "", args = "(color: Color)" },
    setForegroundColor = { type = "function", description = "", args = "(color: Color)" },
    setBackgroundColor = { type = "function", description = "", args = "(color: Color)" },
    setDisabledColor = { type = "function", description = "", args = "(color: Color)" },
    setGlobalFont = { type = "function", description = "", args = "(font: CFont)" },
    setForegroundColor = { type = "function", description = "", args = "(color: Color)" },
    setBackgroundColor = { type = "function", description = "", args = "(color: Color)" },
    setBaseColor = { type = "function", description = "", args = "(color: Color)" },
    setSize = { type = "function", description = "", args = "(width: number, height: number)" },
    setBorderSize = { type = "function", description = "", args = "(width: number)" },
    setFont = { type = "function", description = "", args = "(font: CFont)" },
    getHotKey = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setHotKey = { type = "function", description = "", args = "(key: number)" },
    setHotKey = { type = "function", description = "", args = "(key: string)" },
    requestFocus = { type = "function", description = "", args = "()" },
    addActionListener = { type = "function", description = "", args = "(actionListener: LuaActionListener)" },
    addMouseListener = { type = "function", description = "", args = "(actionListener: LuaActionListener)" },
    addKeyListener = { type = "function", description = "", args = "(actionListener: LuaActionListener)" },
  }},
  BasicContainer = { type = "class", description = "", inherits = "Widget",  childs = {
  }},
  ScrollArea = { type = "class", description = "", inherits = "BasicContainer",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "ScrollArea", returns = "(ScrollArea)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "ScrollArea", returns = "(ScrollArea)" },
    setContent = { type = "function", description = "", args = "(widget: Widget)" },
    getContent = { type = "function", description = "", args = "()", valuetype = "Widget", returns = "(Widget)" },
    setScrollbarWidth = { type = "function", description = "", args = "(width: number)" },
    getScrollbarWidth = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    scrollToBottom = { type = "function", description = "", args = "()" },
    scrollToTop = { type = "function", description = "", args = "()" },
  }},
  ImageWidget = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(image: CGraphic);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
    local_new = { type = "function", description = "", args = "(image: CGraphic);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
    new = { type = "function", description = "", args = "(image: Mng);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
    local_new = { type = "function", description = "", args = "(image: Mng);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
    new = { type = "function", description = "", args = "(image: Movie);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
    local_new = { type = "function", description = "", args = "(image: Movie);", valuetype = "ImageWidget", returns = "(ImageWidget)" },
  }},
  Button = { type = "class", description = "", inherits = "Widget",  childs = {
  }},
  ButtonWidget = { type = "class", description = "", inherits = "Button",  childs = {
    new = { type = "function", description = "", args = "(caption: string);", valuetype = "ButtonWidget", returns = "(ButtonWidget)" },
    local_new = { type = "function", description = "", args = "(caption: string);", valuetype = "ButtonWidget", returns = "(ButtonWidget)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    adjustSize = { type = "function", description = "", args = "()" },
  }},
  ImageButton = { type = "class", description = "", inherits = "Button",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "ImageButton", returns = "(ImageButton)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "ImageButton", returns = "(ImageButton)" },
    new = { type = "function", description = "", args = "(caption: string);", valuetype = "ImageButton", returns = "(ImageButton)" },
    local_new = { type = "function", description = "", args = "(caption: string);", valuetype = "ImageButton", returns = "(ImageButton)" },
    setNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDisabledImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  RadioButton = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "RadioButton", returns = "(RadioButton)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "RadioButton", returns = "(RadioButton)" },
    new = { type = "function", description = "", args = "(caption: string, group: string, marked: boolean = false);", valuetype = "RadioButton", returns = "(RadioButton)" },
    local_new = { type = "function", description = "", args = "(caption: string, group: string, marked: boolean = false);", valuetype = "RadioButton", returns = "(RadioButton)" },
    isMarked = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    setMarked = { type = "function", description = "", args = "(marked: boolean)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    setGroup = { type = "function", description = "", args = "(group: string)" },
    adjustSize = { type = "function", description = "", args = "()" },
  }},
  ImageRadioButton = { type = "class", description = "", inherits = "RadioButton",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "ImageRadioButton", returns = "(ImageRadioButton)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "ImageRadioButton", returns = "(ImageRadioButton)" },
    new = { type = "function", description = "", args = "(caption: string, group: string, marked: boolean = false);", valuetype = "ImageRadioButton", returns = "(ImageRadioButton)" },
    local_new = { type = "function", description = "", args = "(caption: string, group: string, marked: boolean = false);", valuetype = "ImageRadioButton", returns = "(ImageRadioButton)" },
    setUncheckedNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUncheckedPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUncheckedDisabledImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedDisabledImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  CheckBox = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "CheckBox", returns = "(CheckBox)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "CheckBox", returns = "(CheckBox)" },
    new = { type = "function", description = "", args = "(caption: string, marked: boolean = false);", valuetype = "CheckBox", returns = "(CheckBox)" },
    local_new = { type = "function", description = "", args = "(caption: string, marked: boolean = false);", valuetype = "CheckBox", returns = "(CheckBox)" },
    isMarked = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    setMarked = { type = "function", description = "", args = "(marked: boolean)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    adjustSize = { type = "function", description = "", args = "()" },
  }},
  ImageCheckBox = { type = "class", description = "", inherits = "CheckBox",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "ImageCheckBox", returns = "(ImageCheckBox)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "ImageCheckBox", returns = "(ImageCheckBox)" },
    new = { type = "function", description = "", args = "(caption: string, marked: boolean = false);", valuetype = "ImageCheckBox", returns = "(ImageCheckBox)" },
    local_new = { type = "function", description = "", args = "(caption: string, marked: boolean = false);", valuetype = "ImageCheckBox", returns = "(ImageCheckBox)" },
    setUncheckedNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUncheckedPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUncheckedDisabledImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setCheckedDisabledImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  Slider = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(scaleEnd: double = 1.0);", valuetype = "Slider", returns = "(Slider)" },
    local_new = { type = "function", description = "", args = "(scaleEnd: double = 1.0);", valuetype = "Slider", returns = "(Slider)" },
    new = { type = "function", description = "", args = "(scaleStart: double, scaleEnd: double);", valuetype = "Slider", returns = "(Slider)" },
    local_new = { type = "function", description = "", args = "(scaleStart: double, scaleEnd: double);", valuetype = "Slider", returns = "(Slider)" },
    setScale = { type = "function", description = "", args = "(scaleStart: double, scaleEnd: double)" },
    getScaleStart = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setScaleStart = { type = "function", description = "", args = "(scaleStart: double)" },
    getScaleEnd = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setScaleEnd = { type = "function", description = "", args = "(scaleEnd: double)" },
    getValue = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setValue = { type = "function", description = "", args = "(value: double)" },
    setMarkerLength = { type = "function", description = "", args = "(length: number)" },
    getMarkerLength = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setOrientation = { type = "function", description = "", args = "(orientation: number)" },
    getOrientation = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setStepLength = { type = "function", description = "", args = "(length: double)" },
    getStepLength = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  }},
  ImageSlider = { type = "class", description = "", inherits = "Slider",  childs = {
    new = { type = "function", description = "", args = "(scaleEnd: double = 1.0);", valuetype = "ImageSlider", returns = "(ImageSlider)" },
    local_new = { type = "function", description = "", args = "(scaleEnd: double = 1.0);", valuetype = "ImageSlider", returns = "(ImageSlider)" },
    new = { type = "function", description = "", args = "(scaleStart: double, scaleEnd: double);", valuetype = "ImageSlider", returns = "(ImageSlider)" },
    local_new = { type = "function", description = "", args = "(scaleStart: double, scaleEnd: double);", valuetype = "ImageSlider", returns = "(ImageSlider)" },
    setMarkerImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setBackgroundImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDisabledBackgroundImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  Label = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(caption: string);", valuetype = "Label", returns = "(Label)" },
    local_new = { type = "function", description = "", args = "(caption: string);", valuetype = "Label", returns = "(Label)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    setAlignment = { type = "function", description = "", args = "(alignment: number)" },
    getAlignment = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    adjustSize = { type = "function", description = "", args = "()" },
  }},
  MultiLineLabel = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "MultiLineLabel", returns = "(MultiLineLabel)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "MultiLineLabel", returns = "(MultiLineLabel)" },
    new = { type = "function", description = "", args = "(caption: string);", valuetype = "MultiLineLabel", returns = "(MultiLineLabel)" },
    local_new = { type = "function", description = "", args = "(caption: string);", valuetype = "MultiLineLabel", returns = "(MultiLineLabel)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    setAlignment = { type = "function", description = "", args = "(alignment: number)" },
    getAlignment = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setVerticalAlignment = { type = "function", description = "", args = "(alignment: number)" },
    getVerticalAlignment = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setLineWidth = { type = "function", description = "", args = "(width: number)" },
    getLineWidth = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    adjustSize = { type = "function", description = "", args = "()" },
    draw = { type = "function", description = "", args = "(gcn::graphics: Graphics)" },
  }},
  TextBox = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(text: string);", valuetype = "TextBox", returns = "(TextBox)" },
    local_new = { type = "function", description = "", args = "(text: string);", valuetype = "TextBox", returns = "(TextBox)" },
    setEditable = { type = "function", description = "", args = "(editable: boolean)" },
  }},
  TextField = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(text: string);", valuetype = "TextField", returns = "(TextField)" },
    local_new = { type = "function", description = "", args = "(text: string);", valuetype = "TextField", returns = "(TextField)" },
    setText = { type = "function", description = "", args = "(text: string)" },
    setPassword = { type = "function", description = "", args = "(flag: boolean)" },
  }},
  ImageTextField = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(text: string);", valuetype = "ImageTextField", returns = "(ImageTextField)" },
    local_new = { type = "function", description = "", args = "(text: string);", valuetype = "ImageTextField", returns = "(ImageTextField)" },
    setText = { type = "function", description = "", args = "(text: string)" },
    setItemImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setPassword = { type = "function", description = "", args = "(flag: boolean)" },
  }},
  ListBox = { type = "class", description = "", inherits = "Widget",  childs = {
  }},
  ImageListBox = { type = "class", description = "", inherits = "ListBox",  childs = {
  }},
  ListBoxWidget = { type = "class", description = "", inherits = "ScrollArea",  childs = {
    new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ListBoxWidget", returns = "(ListBoxWidget)" },
    local_new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ListBoxWidget", returns = "(ListBoxWidget)" },
    setList = { type = "function", description = "", args = "(lua: lua_State, lo: lua_Object)" },
    getSelected = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  }},
  ImageListBoxWidget = { type = "class", description = "", inherits = "ListBoxWidget",  childs = {
    new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ImageListBoxWidget", returns = "(ImageListBoxWidget)" },
    local_new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ImageListBoxWidget", returns = "(ImageListBoxWidget)" },
    setList = { type = "function", description = "", args = "(lua: lua_State, lo: lua_Object)" },
    getSelected = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setItemImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUpButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setUpPressedButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDownButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDownPressedButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setLeftButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setLeftPressedButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setRightButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setRightPressedButtonImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setHBarImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setVBarImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setMarkerImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  Window = { type = "class", description = "", inherits = "BasicContainer",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "Window", returns = "(Window)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "Window", returns = "(Window)" },
    new = { type = "function", description = "", args = "(caption: string);", valuetype = "Window", returns = "(Window)" },
    local_new = { type = "function", description = "", args = "(caption: string);", valuetype = "Window", returns = "(Window)" },
    new = { type = "function", description = "", args = "(content: Widget, caption: string = \"\");", valuetype = "Window", returns = "(Window)" },
    local_new = { type = "function", description = "", args = "(content: Widget, caption: string = \"\");", valuetype = "Window", returns = "(Window)" },
    setCaption = { type = "function", description = "", args = "(caption: string)" },
    setAlignment = { type = "function", description = "", args = "(alignment: number)" },
    getAlignment = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setContent = { type = "function", description = "", args = "(Widget* widget)" },
    getContent = { type = "function", description = "", args = "()", valuetype = "Widget", returns = "(Widget)" },
    setPadding = { type = "function", description = "", args = "(padding: number)" },
    getPadding = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setTitleBarHeight = { type = "function", description = "", args = "(height: number)" },
    getTitleBarHeight = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setMovable = { type = "function", description = "", args = "(movable: boolean)" },
    isMovable = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    resizeToContent = { type = "function", description = "", args = "()" },
    setOpaque = { type = "function", description = "", args = "(opaque: boolean)" },
    isOpaque = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  }},
  Windows = { type = "class", description = "", inherits = "Window",  childs = {
    new = { type = "function", description = "", args = "(text: string, width: number, height: number);", valuetype = "Windows", returns = "(Windows)" },
    local_new = { type = "function", description = "", args = "(text: string, width: number, height: number);", valuetype = "Windows", returns = "(Windows)" },
    add = { type = "function", description = "", args = "(widget: Widget, x: number, y: number)" },
  }},
  ScrollingWidget = { type = "class", description = "", inherits = "ScrollArea",  childs = {
    new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ScrollingWidget", returns = "(ScrollingWidget)" },
    local_new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "ScrollingWidget", returns = "(ScrollingWidget)" },
    add = { type = "function", description = "", args = "(widget: Widget, x: number, y: number)" },
    restart = { type = "function", description = "", args = "()" },
    setSpeed = { type = "function", description = "", args = "(speed: float)" },
    getSpeed = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  }},
  DropDown = { type = "class", description = "", inherits = "BasicContainer",  childs = {
    getSelected = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
    setSelected = { type = "function", description = "", args = "(selected: number)" },
    setScrollArea = { type = "function", description = "", args = "(ScrollArea* scrollArea)" },
    getScrollArea = { type = "function", description = "", args = "()", valuetype = "ScrollArea", returns = "(ScrollArea)" },
    setListBox = { type = "function", description = "", args = "(ListBox* listBox)" },
    getListBox = { type = "function", description = "", args = "()", valuetype = "ListBox", returns = "(ListBox)" },
  }},
  DropDownWidget = { type = "class", description = "", inherits = "DropDown",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "DropDownWidget", returns = "(DropDownWidget)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "DropDownWidget", returns = "(DropDownWidget)" },
    setList = { type = "function", description = "", args = "(lua: lua_State, lo: lua_Object)" },
    getListBox = { type = "function", description = "", args = "()", valuetype = "ListBox", returns = "(ListBox)" },
    setSize = { type = "function", description = "", args = "(width: number, height: number)" },
  }},
  ImageDropDownWidget = { type = "class", description = "", inherits = "DropDown",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "ImageDropDownWidget", returns = "(ImageDropDownWidget)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "ImageDropDownWidget", returns = "(ImageDropDownWidget)" },
    setList = { type = "function", description = "", args = "(lua: lua_State, lo: lua_Object)" },
    getListBox = { type = "function", description = "", args = "()", valuetype = "ListBox", returns = "(ListBox)" },
    setSize = { type = "function", description = "", args = "(width: number, height: number)" },
    setItemImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDownNormalImage = { type = "function", description = "", args = "(image: CGraphic)" },
    setDownPressedImage = { type = "function", description = "", args = "(image: CGraphic)" },
  }},
  StatBoxWidget = { type = "class", description = "", inherits = "Widget",  childs = {
    new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "StatBoxWidget", returns = "(StatBoxWidget)" },
    local_new = { type = "function", description = "", args = "(width: number, height: number);", valuetype = "StatBoxWidget", returns = "(StatBoxWidget)" },
    setCaption = { type = "function", description = "", args = "(s: string)" },
    setPercent = { type = "function", description = "", args = "(percent: number)" },
    getPercent = { type = "function", description = "", args = "()", valuetype = "number", returns = "(number)" },
  }},
  Container = { type = "class", description = "", inherits = "BasicContainer",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "Container", returns = "(Container)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "Container", returns = "(Container)" },
    setOpaque = { type = "function", description = "", args = "(opaque: boolean)" },
    isOpaque = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
    add = { type = "function", description = "", args = "(widget: Widget, x: number, y: number)" },
    remove = { type = "function", description = "", args = "(widget: Widget)" },
    clear = { type = "function", description = "", args = "()" },
  }},
  MenuScreen = { type = "class", description = "", inherits = "Container",  childs = {
    new = { type = "function", description = "", args = "();", valuetype = "MenuScreen", returns = "(MenuScreen)" },
    local_new = { type = "function", description = "", args = "();", valuetype = "MenuScreen", returns = "(MenuScreen)" },
    run = { type = "function", description = "", args = "(loop: boolean = true)", valuetype = "number", returns = "(number)" },
    stop = { type = "function", description = "", args = "(result: number = 0)" },
    stopAll = { type = "function", description = "", args = "(result: number = 0)" },
    addLogicCallback = { type = "function", description = "", args = "(actionListener: LuaActionListener)" },
    setDrawMenusUnder = { type = "function", description = "", args = "(drawunder: boolean)" },
    getDrawMenusUnder = { type = "function", description = "", args = "()", valuetype = "boolean", returns = "(boolean)" },
  }},
  CenterOnMessage = { type = "function", description = "", args = "()" },
  ToggleShowMessages = { type = "function", description = "", args = "()" },
  SetMaxMessageCount = { type = "function", description = "", args = "(max: number)" },
  UiFindIdleWorker = { type = "function", description = "", args = "()" },
  CycleViewportMode = { type = "function", description = "", args = "(step: number)" },
  UiToggleTerrain = { type = "function", description = "", args = "()" },
  UiTrackUnit = { type = "function", description = "", args = "()" },
  SetNewViewportMode = { type = "function", description = "", args = "(new_mode: ViewportModeType)" },
  SetDefaultTextColors = { type = "function", description = "", args = "(normal: string, reverse: string)" },
  LoadDecorations = { type = "function", description = "", args = "()" },
  InitUserInterface = { type = "function", description = "", args = "()" },

}

local interpreter = {
  name = "Stratagus",
  description = "Stratagus engine",
  api = {"baselib", "stratagus"},
  frun = function(self,wfilename,rundebug)
    ide:Print("Run stratagus normally")
  end,
  hasdebugger = true,
}

-- the actual plugin
return {
  name = "Stratagus plugin",
  description = "Stratagus completion and filetypes",
  author = "Tim Felgentreff",
  version = 0.1,

  onRegister = function(self)
    ide:AddAPI("lua", "stratagus", api)
    ide:AddSpec("stratagus-maps", mapspec)
    ide:AddInterpreter("Stratagus", interpreter)
    ide:Print("Stratagus plugin registered")
  end,

  onUnRegister = function(self)
    ide:RemoveInterpreter("Stratagus")
    ide:RemoveSpec("stratagus-maps")
    ide:RemoveAPI("lua", "stratagus")
    ide:Print("Stratagus plugin unloaded")
  end,
}
