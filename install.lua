local HOME = os.getenv("HOME")
if not HOME then
  io.stderr:write("install: HOME is not set\n")
  os.exit(1)
end

local DIR = HOME .. "/.local/bin/lua"
local SCRIPT = DIR .. "/there.lua"
local STORE = HOME .. "/.there.json"
local MARK = "# there:"

local SOURCES = {
  "https://codeberg.org/initsyscall/there/raw/branch/main/there.lua",
  "https://raw.githubusercontent.com/initsyscall/there/main/there.lua",
}

local RCS = { bash = HOME .. "/.bashrc", zsh = HOME .. "/.zshrc" }
local FISHRC = HOME .. "/.config/fish"
local FISHCONF = FISHRC .. "/conf.d/there.fish"

local HINTS = {
  "sudo apt install jq fzf lua5.4        debian, ubuntu",
  "sudo dnf install jq fzf lua           fedora",
  "sudo pacman -S jq fzf lua             arch",
  "nix profile install nixpkgs#{jq,fzf,lua}",
  "brew install jq fzf lua               macos",
}

local FLAGS = {}
local SHELLARG = nil

local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function capture(cmd)
  local f = io.popen(cmd, "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

local function works(cmd)
  local f = io.popen(cmd .. " >/dev/null 2>&1", "r")
  if not f then
    return false
  end
  f:read("a")
  return f:close() and true or false
end

local THEMES = {
  night = { good = "#80FFEA", bad = "#ff496f", head = "#A277FF", mute = "#8f8ba8", ver = "#F087BD" },
  day = { good = "#00715f", bad = "#c01c54", head = "#7d3cdd", mute = "#785a79", ver = "#a14565" },
}
local C = THEMES[os.getenv("THERE_THEME") or ""] or THEMES.night

local TERM = os.getenv("TERM") or ""
local TRUE24 = os.getenv("COLORTERM") or TERM:find("256color") or TERM:find("direct")
local TTY = io.open("/dev/tty")
local PLAIN = os.getenv("NO_COLOR") or TERM == "dumb" or not TRUE24 or TTY == nil
if TTY then
  TTY:close()
end

local function paint(code, s)
  if PLAIN then
    return s
  end
  return "\27[" .. code .. "m" .. s .. "\27[0m"
end

local function rgb(h)
  return "38;2;" .. tonumber(h:sub(2, 3), 16) .. ";"
      .. tonumber(h:sub(4, 5), 16) .. ";" .. tonumber(h:sub(6, 7), 16)
end

local function say(s)
  io.write(s .. "\n")
  io.flush()
end

local function bold(s)
  return paint("1;" .. rgb(C.head), s)
end

local function dim(s)
  return paint(rgb(C.mute), s)
end

local function good(s)
  return paint(rgb(C.good), s)
end

local function bad(s)
  return paint(rgb(C.bad), s)
end

local function ver(s)
  return paint(rgb(C.ver), s)
end

local function pad(s, n)
  return s .. string.rep(" ", n - #s > 1 and n - #s or 1)
end

local function short(p)
  if p:sub(1, #HOME) == HOME then
    return "~" .. p:sub(#HOME + 1)
  end
  return p
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readfile(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

local function writefile(path, s)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  assert(os.rename(tmp, path))
end

local function ask(question)
  io.stderr:write(question)
  io.stderr:flush()
  local tty = io.open("/dev/tty", "r")
  local line
  if tty then
    line = tty:read("l")
    tty:close()
  else
    line = io.read("l")
  end
  return line
end

local function confirmed(question)
  local line = ask(question .. " " .. bold("[y/N]") .. " ")
  if not PLAIN then
    io.stderr:write("\n")
  end
  return line ~= nil and line:lower():sub(1, 1) == "y"
end

local function probe(label, present, cmd)
  if not present then
    say("  " .. pad(label, 6) .. bad("missing"))
    return false
  end
  say("  " .. pad(label, 6) .. ver(trim(capture(cmd .. " 2>&1") or "")))
  return true
end

local function fetch(tool, url, dest)
  if tool == "wget" then
    return works("wget -q -O " .. q(dest) .. " " .. q(url))
  end
  return works("curl -fsSL " .. q(url) .. " -o " .. q(dest))
end

local function compiles(path)
  return works("lua -e " .. q("assert(loadfile(" .. string.format("%q", path) .. "))"))
end

local function download(tool, dest)
  for _, url in ipairs(SOURCES) do
    say("  " .. dim("fetching " .. url))
    if fetch(tool, url, dest) and readfile(dest) and #readfile(dest) > 0 then
      return true, url
    end
  end
  return false
end

local function detect()
  return (os.getenv("SHELL") or ""):match("([^/]+)$") or ""
end

local function targets(shell)
  local out = {}
  if shell == "fish" then
    out[#out + 1] = { shell = "fish", path = FISHCONF }
  elseif RCS[shell] then
    out[#out + 1] = { shell = shell, path = RCS[shell] }
  end
  if shell ~= "fish" and readfile(FISHRC .. "/config.fish") then
    out[#out + 1] = { shell = "fish", path = FISHCONF }
  end
  return out
end

local function emit(shell, runner, home)
  local w = capture("HOME=" .. q(home or HOME) .. " lua " .. q(runner) .. " init " .. shell)
  if w == nil or trim(w) == "" then
    return nil
  end
  w = trim(w) .. "\n"
  if shell == "fish" then
    return MARK .. "begin\n" .. w .. MARK .. "end\n"
  end
  return MARK .. "begin\n"
      .. "if [ -f " .. q(SCRIPT) .. " ]; then\n"
      .. w:gsub("\n", "\n\t")
      .. "fi\n"
      .. MARK .. "end\n"
end

local function unblock(s)
  if s == nil or not s:find(MARK .. "begin", 1, true) then
    return s
  end
  local keep = {}
  local dropping = false
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if line == MARK .. "begin" then
      dropping = true
    elseif line == MARK .. "end" then
      dropping = false
    elseif not dropping then
      keep[#keep + 1] = line
    end
  end
  return table.concat(keep, "\n")
end

local function blocked(path, body)
  local cur = unblock(readfile(path)) or ""
  if cur ~= "" and cur:sub(-1) ~= "\n" then
    cur = cur .. "\n"
  end
  if cur ~= "" then
    cur = cur .. "\n"
  end
  return cur .. body
end

local function strip(path)
  local s = unblock(readfile(path))
  if s == nil then
    return false
  end
  writefile(path, s)
  return true
end

local function wire(t, runner)
  local body = emit(t.shell, runner)
  if body == nil then
    return false
  end
  writefile(t.path, blocked(t.path, body))
  return true
end

local function show(path, body)
  local cur = readfile(path)
  if cur and cur:find(MARK .. "begin", 1, true) then
    say("    " .. dim("replaces the block already here, nothing else"))
  elseif cur and trim(cur) ~= "" then
    say("    " .. dim("appends below " .. select(2, cur:gsub("\n", "")) .. " lines"))
  end
  for line in (body .. "\n"):gmatch("(.-)\n") do
    say("    " .. good("+ " .. line))
  end
end

local function help()
  say([[
install.lua — install there, a deterministic cd wrapper

  curl -sL https://codeberg.org/initsyscall/there/raw/branch/main/install.lua | lua -

  lua install.lua                     install for $SHELL
  lua install.lua --shell zsh         install for a named shell
  lua install.lua --uninstall         remove it, ask about the store

  --dry-run, -n       report everything, write nothing

  --dry-run also works on --uninstall. One dash is fine, so -n and -dry-run
  are the same thing. Anything unrecognised is refused rather than ignored.
]])
end

local function install(shell)
  local dry = FLAGS.dry and true or false
  say("")
  say("  " .. bold("there") .. "  " .. dim("a deterministic cd wrapper")
    .. (dry and "  " .. dim("[dry run]") or ""))
  say("")

  local allgood = probe("lua", true, "lua -e " .. q("print(_VERSION)"))
  for _, name in ipairs({ "jq", "fzf" }) do
    if not probe(name, works(name .. " --version"), name .. " --version") then
      allgood = false
    end
  end
  say("")

  if not allgood then
    say("  " .. bad("missing") .. " install them first:")
    say("")
    for _, h in ipairs(HINTS) do
      say("    " .. h)
    end
    say("")
    os.exit(1)
  end

  local tool
  if works("curl --version") then
    tool = "curl"
  elseif works("wget --version") then
    tool = "wget"
  else
    say("  " .. bad("missing") .. " need curl or wget to download")
    say("")
    os.exit(1)
  end

  local list = targets(shell)
  if #list == 0 then
    say("  " .. bad("cannot tell which shell to wire") .. "  SHELL=" .. dim(shell))
    say("  " .. dim("name one with --shell bash|zsh|fish"))
    say("")
    os.exit(1)
  end

  say("  " .. dim("will write"))
  say("    " .. pad(short(SCRIPT), 40) .. dim(readfile(SCRIPT) and "replace" or "create"))
  for _, t in ipairs(list) do
    say("    " .. pad(short(t.path), 40) .. dim(t.shell))
  end
  say("")

  if not dry and not confirmed("  " .. bold("ok to proceed?") .. " ") then
    say("  " .. dim("stopped, nothing written"))
    say("")
    return
  end

  if not dry then
    assert(os.execute("mkdir -p " .. q(DIR)))
  end

  local part = dry and os.tmpname() or (SCRIPT .. ".part")
  local got, url = download(tool, part)
  if not got then
    os.remove(part)
    say("  " .. bad("could not download there.lua") .. "  " .. dim("tried"))
    for _, s in ipairs(SOURCES) do
      say("    " .. dim(s))
    end
    say("")
    os.exit(1)
  end
  if not compiles(part) then
    os.remove(part)
    say("  " .. bad("downloaded file does not parse as lua"))
    say("")
    os.exit(1)
  end

  if dry then
    say("  " .. good("reachable") .. "  " .. url)
    say("  " .. good("parses") .. "     " .. dim("as lua, " .. #(readfile(part) or "") .. " bytes"))
    say("")
    local box = os.tmpname() .. ".d"
    os.execute("mkdir -p " .. q(box))
    for _, t in ipairs(list) do
      local w = emit(t.shell, part, box)
      if w == nil then
        say("  " .. bad("could not build wrapper") .. "  " .. short(t.path))
        say("")
      else
        say("  " .. dim("add to") .. "  " .. short(t.path) .. dim("  " .. t.shell))
        show(t.path, w)
      end
    end
    os.execute("rm -rf " .. q(box))
    os.remove(part)
    say("")
    say("  " .. dim("dry run, nothing was written"))
    say("")
    return
  end

  assert(os.execute("mkdir -p " .. q(FISHRC .. "/conf.d")))
  assert(os.rename(part, SCRIPT))

  say("")
  say("  " .. good("installed") .. "  " .. short(SCRIPT))
  say("  " .. dim("from " .. url))

  for _, t in ipairs(list) do
    if wire(t, SCRIPT) then
      say("  " .. good("wired") .. "    " .. short(t.path) .. dim("  " .. t.shell))
    else
      say("  " .. bad("could not wire") .. " " .. short(t.path))
    end
  end

  say("")
  say("  " .. bold("start a new shell, then try") .. "  " .. bold("t list"))
  say("")
end

local function uninstall()
  local dry = FLAGS.dry and true or false
  say("")
  say("  " .. bold("there") .. "  " .. dim("uninstall")
    .. (dry and "  " .. dim("[dry run]") or ""))
  say("")

  local function line(verb, path)
    if dry then
      say("  " .. dim(pad("would " .. verb, 11)) .. short(path))
    else
      say("  " .. good(pad(verb, 11)) .. short(path))
    end
  end

  if not dry then
    os.remove(SCRIPT .. ".part")
  end
  if readfile(SCRIPT) then
    line("remove", SCRIPT)
    if not dry then
      os.remove(SCRIPT)
    end
  else
    say("  " .. dim(pad("absent", 11)) .. short(SCRIPT))
  end

  for _, name in ipairs({ "bash", "zsh" }) do
    local s = readfile(RCS[name])
    if s and s:find(MARK .. "begin", 1, true) then
      line("clean", RCS[name])
      if not dry then
        strip(RCS[name])
      end
    end
  end

  if readfile(FISHCONF) then
    line("remove", FISHCONF)
    if not dry then
      os.remove(FISHCONF)
    end
  end

  if readfile(STORE) then
    say("")
    if dry then
      say("  " .. dim("would ask whether to delete"))
      say("    " .. short(STORE) .. dim("  " .. #readfile(STORE) .. " bytes, kept unless you say y"))
    elseif confirmed("  " .. bold("delete the store too?") .. " ") then
      os.remove(STORE)
      say("  " .. good(pad("deleted", 11)) .. short(STORE))
    else
      say("  " .. good(pad("kept", 11)) .. short(STORE) .. dim("  your bookmarks stay put"))
    end
  end

  say("")
  say("  " .. dim("start a new shell to drop the t function"))
  say("")
end

local function parse()
  local mode = "install"
  local i = 0
  while i < #(arg or {}) do
    i = i + 1
    local a = (arg[i] or ""):gsub("^%-+", "")
    if a == "uninstall" then
      mode = "uninstall"
    elseif a == "shell" then
      SHELLARG = arg[i + 1]
      i = i + 1
    elseif a == "dry-run" or a == "n" then
      FLAGS.dry = true
    elseif a == "h" or a == "help" then
      mode = "help"
    else
      say("  " .. bad("unknown option") .. "  " .. arg[i])
      say("  " .. dim("try --help"))
      say("")
      os.exit(2)
    end
  end
  return mode
end

local mode = parse()

if mode == "help" then
  help()
  os.exit(0)
elseif mode == "uninstall" then
  uninstall()
else
  install(SHELLARG or detect())
end
