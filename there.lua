local HOME = os.getenv("HOME")
if not HOME then
  io.stderr:write("t: HOME is not set\n")
  os.exit(1)
end

local STORE = HOME .. "/.there.json"
local TAG = "+"

local WRAPS = {}

WRAPS.bash = [==[
t() {
	local out
	out=$(command lua "$HOME/.local/bin/lua/there.lua" "$@") || return $?
	case $out in
		cd\ *) eval "$out" ;;
	esac
}
]==]

WRAPS.zsh = WRAPS.bash

WRAPS.fish = [==[
function t
	set -l out (command lua "$HOME/.local/bin/lua/there.lua" $argv)
	set -l rc $status
	if test $rc -ne 0
		return $rc
	end
	if string match -q -- 'cd *' "$out"
		eval $out[1]
	end
end
]==]

local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function note(s)
  io.stderr:write(s)
end

local function die(msg)
  note("t: " .. msg .. "\n")
  os.exit(1)
end

local function run(cmd)
  local f = io.popen(cmd, "r")
  local out = f:read("a")
  if not f:close() then
    os.exit(1)
  end
  return out
end

local function jqout(filter, ...)
  local cmd = { "jq", "-r", q(filter), q(STORE) }
  for _, a in ipairs({ ... }) do
    cmd[#cmd + 1] = q(a)
  end
  return run(table.concat(cmd, " "))
end

local function jqput(filter, ...)
  local tmp = STORE .. "~"
  local cmd = { "jq", q(filter), q(STORE) }
  for _, a in ipairs({ ... }) do
    cmd[#cmd + 1] = q(a)
  end
  run(table.concat(cmd, " ") .. " > " .. q(tmp))
  os.execute("chmod 600 " .. q(tmp))
  os.rename(tmp, STORE)
end

local function lines(s)
  local t = {}
  for line in s:gmatch("[^\n]+") do
    if line ~= "null" then
      t[#t + 1] = line
    end
  end
  return t
end

local function names(t)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

local function isdir(p)
  local f = io.popen("test -d " .. q(p), "r")
  f:read("a")
  return f:close() and true or false
end

local function stillthere(list)
  if #list == 0 then
    return {}
  end
  local args = {}
  for _, p in ipairs(list) do
    args[#args + 1] = q(p)
  end
  return lines(run(
    "printf '%s\\n' " .. table.concat(args, " ")
    .. " | while IFS= read -r p; do [ -d \"$p\" ] && printf '%s\\n' \"$p\"; done; exit 0"
  ))
end

local function abs(p)
  p = p:gsub("^~", HOME)
  if p:sub(1, 1) ~= "/" then
    p = (os.getenv("PWD") or ".") .. "/" .. p
  end
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  return p
end

local function cd(p)
  if p:find("\n") then
    die("a path cannot hold a newline: " .. p:gsub("\n", "\\n"))
  end
  print("cd " .. q(p))
end

local function tagname(s)
  return s:sub(1, 1) == TAG and s or TAG .. s
end

local function save(list, tags)
  for _, p in ipairs(list) do
    if p:find("\n") then
      die("a path cannot hold a newline: " .. p:gsub("\n", "\\n"))
    end
  end
  jqput(
    '($l | split("\n") | map(select(length > 0))) as $ps'
    .. ' | ($t | split("\n") | map(select(length > 0)) | unique) as $ts'
    .. ' | reduce $ps[] as $p (.;'
    .. ' if any(.paths[]; .path == $p)'
    .. ' then .paths |= map(if .path == $p then .tags = ((.tags // []) + $ts | unique) else . end)'
    .. ' else .paths += [{path: $p, tags: $ts}]'
    .. ' end)',
    "--arg", "l", table.concat(list, "\n"),
    "--arg", "t", table.concat(tags, "\n")
  )
end

local function remove(list)
  jqput(
    '($l | split("\n") | map(select(length > 0))) as $x'
    .. ' | .paths |= map(select(.path as $p | $x | index($p) | not))',
    "--arg", "l", table.concat(list, "\n")
  )
end

local pruned = false

local function prune()
  if pruned then
    return
  end
  pruned = true
  if #jqout('.paths[] | select(.path | type != "string") | .path // "x"') > 0 then
    die(STORE .. " has an entry with no path; drop that entry")
  end
  local all = lines(jqout(".paths[].path"))
  local live = stillthere(all)
  if #live == #all then
    return
  end
  local dead = {}
  for _, p in ipairs(all) do
    if not has(live, p) then
      dead[#dead + 1] = p
    end
  end
  remove(dead)
  if #lines(jqout(".paths[].path")) ~= #all - #dead then
    die(STORE .. " holds a path with a newline in it; drop that entry")
  end
  for _, p in ipairs(dead) do
    note("t: dropped " .. p .. "\n")
  end
end

local function paths()
  prune()
  return lines(jqout(".paths[].path"))
end

local function matches(name)
  local out = {}
  for _, p in ipairs(paths()) do
    if p == name or p:sub(-(#name + 1)) == "/" .. name then
      out[#out + 1] = p
    end
  end
  return out
end

local function tagged(tag)
  return lines(jqout(".paths[] | select((.tags // []) | index($t)) | .path", "--arg", "t", tag))
end

local function untagged()
  prune()
  return lines(jqout(".paths[] | select(((.tags // []) | length) == 0) | .path"))
end

local function carrying(tags)
  prune()
  return lines(jqout(
    '($w | split("\n") | map(select(length > 0))) as $ws'
    .. ' | [.paths[] | select(($ws - (.tags // [])) | length == 0) | .path] | .[]',
    "--arg", "w", table.concat(tags, "\n")
  ))
end

local function pick(list)
  if #list == 0 then
    return nil, 1
  end
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write(table.concat(list, "\n"), "\n")
  f:close()
  local p = io.popen("fzf --reverse --height=40% < " .. q(tmp) .. " 2>/dev/null", "r")
  local out = p:read("*l")
  local _, _, code = p:close()
  os.remove(tmp)
  if out then
    return out, 0
  end
  return nil, code or 1
end

local function show(list, empty)
  if #list == 0 then
    note("t: " .. empty .. "\n")
    return
  end
  if #list == 1 then
    return cd(list[1])
  end
  local choice, code = pick(list)
  if choice then
    cd(choice)
  elseif code ~= 130 then
    note(table.concat(list, "\n") .. "\n")
  end
end

local function choose(list, empty)
  if #list == 0 then
    die(empty)
  end
  if #list == 1 then
    return cd(list[1])
  end
  local choice, code = pick(list)
  if choice then
    cd(choice)
  elseif code ~= 130 then
    die("pick one:\n" .. table.concat(list, "\n"))
  end
end

local function jump(name, tags)
  local hits = matches(name)
  if #hits == 1 then
    if #tags > 0 then
      save({ hits[1] }, tags)
    end
    cd(hits[1])
  elseif #hits > 1 then
    choose(hits)
  elseif #tags > 0 or name:find("[/~]") or name:find("^%.") then
    local target = abs(name)
    if not isdir(target) then
      die("no such directory: " .. name)
    end
    save({ target }, tags)
    cd(target)
  else
    die("no bookmark named " .. name)
  end
end

local function globbed(p)
  return p:find("[%*%?%[]") ~= nil
end

local function expand(pattern)
  return lines(run(
    "for d in " .. abs(pattern)
    .. "; do [ -d \"$d\" ] && printf '%s\\n' \"$d\"; done; exit 0"
  ))
end

local COMMANDS = {}

COMMANDS.list = function()
  show(paths(), "nothing saved")
end

COMMANDS.untagged = function()
  show(untagged(), "every saved path is tagged")
end

COMMANDS.add = function(pattern)
  local dirs = expand(pattern)
  if #dirs == 0 then
    die("no directory matched " .. pattern)
  end
  local have = paths()
  local fresh, kept = {}, 0
  for _, d in ipairs(dirs) do
    if has(have, d) then
      kept = kept + 1
    else
      fresh[#fresh + 1] = d
    end
  end
  if #fresh == 0 then
    die("nothing new for " .. pattern)
  end
  save(fresh, {})
  note(table.concat(fresh, "\n") .. "\n")
  note(string.format("added %d, already saved %d\n", #fresh, kept))
end

COMMANDS.rm = function(arg)
  local wild = globbed(arg)
  local hits = {}
  if wild then
    local have = paths()
    for _, d in ipairs(expand(arg)) do
      if has(have, d) then
        hits[#hits + 1] = d
      end
    end
  else
    hits = matches(arg)
  end
  if #hits == 0 then
    die("no bookmark named " .. arg)
  end
  if #hits > 1 and not wild then
    die("ambiguous, matches:\n" .. table.concat(hits, "\n"))
  end
  remove(hits)
  note(table.concat(hits, "\n") .. "\n")
  note("removed " .. #hits .. "\n")
end

COMMANDS.rt = function(tag)
  tag = tagname(tag)
  if #tagged(tag) == 0 then
    die("no path tagged " .. tag)
  end
  jqput(".paths |= map(if (.tags // []) | index($t) then .tags |= map(select(. != $t)) else . end)", "--arg", "t", tag)
  note("untagged " .. tag .. "\n")
end

COMMANDS.rta = function(tag)
  tag = tagname(tag)
  local hits = tagged(tag)
  if #hits == 0 then
    die("no path tagged " .. tag)
  end
  remove(hits)
  note(table.concat(hits, "\n") .. "\n")
  note(string.format("removed %d tagged %s\n", #hits, tag))
end

COMMANDS.init = function(shell)
  if not shell or not WRAPS[shell] then
    die("init needs one of: " .. table.concat(names(WRAPS), " "))
  end
  print(WRAPS[shell])
end

local function help()
  note([[
t <name>            jump to a saved path
t <path>            save a path, then jump to it
t +a +b <path>      save a path with tags
t +a +b             pick from everything carrying those tags
t list              pick from everything saved
t untagged          pick from the paths with no tag
t add <glob>        save every directory a glob names
t rm <name|glob>    remove a saved path
t rt <tag>          drop a tag, keep the paths
t rta <tag>         remove every path carrying a tag
t init <shell>      print the shell wrapper
]])
end

local function parse(argv)
  local tags = {}
  local i = 1
  while argv[i] and argv[i]:sub(1, 1) == TAG do
    if #argv[i] < 2 then
      die("a tag needs a name: " .. argv[i])
    end
    tags[#tags + 1] = argv[i]
    i = i + 1
  end
  return tags, { table.unpack(argv, i) }
end

local function ensure()
  local f = io.open(STORE, "r")
  if f then
    f:close()
    return
  end
  run("printf '%s' '{\"paths\":[]}' > " .. q(STORE))
  os.execute("chmod 600 " .. q(STORE))
end

local function main(argv)
  if argv[1] == "--help" or argv[1] == "-h" then
    help()
    return
  end
  local tags, rest = parse(argv)
  ensure()
  if #tags == 0 and COMMANDS[rest[1]] then
    if #rest > 2 then
      die("too many arguments")
    end
    return COMMANDS[rest[1]](table.unpack(rest, 2))
  end
  if #rest > 1 then
    die("expected one name or path, or tags followed by a path")
  end
  if #rest == 0 then
    if #tags == 0 then
      return help()
    end
    return choose(carrying(tags), "no bookmark carries those tags")
  end
  jump(rest[1], tags)
end

main(arg)
